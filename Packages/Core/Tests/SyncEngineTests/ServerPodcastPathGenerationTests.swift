import Foundation
import Testing

@testable import ABSApi
@testable import SyncEngine

@Suite struct ServerPodcastPathGenerationTests {
  @Test func emptyWhitespaceAndDotTitlesUseTheDeterministicFallback() throws {
    for title in ["", "   \n\t", ".", "..", "...", " . . "] {
      let generated = try generatedPath(folder: "/srv/podcasts", title: title)

      #expect(decodedLastComponent(generated) == ServerPodcastPathGeneration.fallbackSegment)
      assertAcceptedByABSPathCheck(generated)
    }
  }

  @Test func unicodeCombiningMarksCjkRtlAndEmojiRemainValid() throws {
    let title = "Cafe\u{301} 🎧 漢字 שלום"
    let generated = try generatedPath(folder: "/srv/podcasts", title: title)
    let decoded = try #require(decodedLastComponent(generated))

    #expect(decoded.contains("Cafe\u{301}"))
    #expect(decoded.contains("🎧"))
    #expect(decoded.contains("漢字"))
    #expect(decoded.contains("שלום"))
    #expect(generated.utf8.count <= PodcastWriteBounds.maximumStringBytes)
    assertAcceptedByABSPathCheck(generated)
  }

  @Test func reservedWindowsNamesArePrefixedWithinTheSingleSegment() throws {
    for title in ["CON", "PRN", "AUX", "NUL", "COM1", "LPT9", "con.txt", "LPT1.txt"] {
      let generated = try generatedPath(folder: "/srv/podcasts", title: title)
      let component = try #require(decodedLastComponent(generated))

      #expect(component.hasPrefix("_"))
      #expect(component.contains("/") == false)
      assertAcceptedByABSPathCheck(generated)
    }
  }

  @Test func longTitlesAreBoundedWithoutSplittingUnicodeScalars() throws {
    let title = String(repeating: "🙂", count: 2_000)
    let generated = try generatedPath(folder: "/srv/podcasts", title: title)
    let component = try #require(decodedLastComponent(generated))

    #expect(generated.utf8.count <= PodcastWriteBounds.maximumStringBytes)
    #expect(component.utf8.count <= ServerPodcastPathGeneration.maximumSegmentBytes)
    #expect(component.unicodeScalars.count > 0)
    #expect(component.unicodeScalars.allSatisfy { $0 == "🙂" })
    #expect(component.data(using: .utf8) != nil)
    assertAcceptedByABSPathCheck(generated)
  }

  @Test func hostileTitleCharactersCannotCreateTraversalOrAbsolutePathRejections() throws {
    let generated = try generatedPath(
      folder: "/srv/podcasts", title: "../a/b\u{0000}?*:#< >|\\\"")
    let component = try #require(decodedLastComponent(generated))

    #expect(generated.hasPrefix("/srv/podcasts/"))
    #expect(component != ".")
    #expect(component != "..")
    #expect(component.contains("/") == false)
    #expect(generated.contains("?") == false)
    #expect(generated.contains("#") == false)
    #expect(generated.contains("\u{0000}") == false)
    assertAcceptedByABSPathCheck(generated)
  }

  @Test func leadingTrailingDotsAndWhitespaceAreRemovedAndWhitespaceCollapses() throws {
    let generated = try generatedPath(
      folder: "/srv/podcasts", title: "  ..  Native   Podcasts  ..  ")

    #expect(decodedLastComponent(generated) == "Native Podcasts")
    assertAcceptedByABSPathCheck(generated)
  }

  @Test func generatedChildRemainsContainedByTheNormalizedFolder() throws {
    let generated = try generatedPath(folder: "/srv/My Podcasts", title: "A Show")

    #expect(generated.hasPrefix("/srv/My Podcasts/"))
    #expect(generated != "/srv/My Podcasts")
    #expect(generated.hasPrefix("/srv/My Podcasts/"))
    assertAcceptedByABSPathCheck(generated)
  }

  @Test func unsafeFolderPathsAreRefusedLocally() {
    let unsafeFolders = [
      "relative/podcasts",
      "/srv/../escape",
      "/srv/%2E%2E/escape",
      "/srv/%ZZ",
      "/srv/podcasts?query",
      "/srv/podcasts#fragment",
    ]

    for folder in unsafeFolders {
      guard
        case .failure = ServerPodcastPathGeneration.generate(
          folderFullPath: folder, nativeFeedTitle: "Show")
      else {
        Issue.record("Unsafe folder path was accepted")
        continue
      }
    }
  }

  @Test func refusalDescriptionDoesNotExposePathOrTitle() {
    let sensitiveFolder = "/private/secret-library/\u{0000}"
    let sensitiveTitle = "secret native title"
    let result = ServerPodcastPathGeneration.generate(
      folderFullPath: sensitiveFolder, nativeFeedTitle: sensitiveTitle)

    guard case .failure(let error) = result else {
      Issue.record("Expected the malformed folder to be refused")
      return
    }
    #expect(error.description.contains(sensitiveFolder) == false)
    #expect(error.description.contains(sensitiveTitle) == false)
    #expect(error.description.contains("secret") == false)
  }

  private func generatedPath(folder: String, title: String) throws -> String {
    guard
      case .success(let value) = ServerPodcastPathGeneration.generate(
        folderFullPath: folder, nativeFeedTitle: title)
    else {
      Issue.record("Expected a bounded child path")
      throw PathTestError.failed
    }
    return value
  }

  private func decodedLastComponent(_ path: String) -> String? {
    guard let component = path.split(separator: "/", omittingEmptySubsequences: true).last else {
      return nil
    }
    return String(component).removingPercentEncoding
  }

  private func assertAcceptedByABSPathCheck(_ path: String) {
    #expect(isUsableAbsolutePath(path, maximumBytes: PodcastWriteBounds.maximumStringBytes))
  }
}

private enum PathTestError: Error {
  case failed
}
