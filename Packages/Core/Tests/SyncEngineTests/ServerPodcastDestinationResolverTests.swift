import ABSApi
import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

@Suite struct ServerPodcastDestinationResolverTests {
  @Test func bookLibrariesAreExcludedBeforeItemTraversal() async throws {
    let bookLibrary = library(id: "books", name: "Books", mediaType: "book")
    let catalog = CatalogStub(libraries: [bookLibrary])
    let resolver = ServerPodcastDestinationResolver(client: catalog)

    let resolution = try await resolver.resolve(feedURL: feedURL, account: account)

    #expect(resolution == .noAccessiblePodcastLibraries)
    #expect(await catalog.recordedCalls().isEmpty)
  }

  @Test func zeroOneAndSeveralPodcastLibrariesProduceBoundedChoices() async throws {
    let libraries = [
      library(id: "podcasts-zero", name: "Empty Podcasts", folders: []),
      library(
        id: "podcasts-one",
        name: "One Folder",
        folders: [folder(id: "folder-one", path: "/srv/one")]),
      library(
        id: "podcasts-many",
        name: "Several Folders",
        folders: [
          folder(id: "folder-two", path: "/srv/two"),
          folder(id: "folder-three", path: "/srv/three"),
        ]),
    ]
    let catalog = CatalogStub(libraries: libraries)
    let resolver = ServerPodcastDestinationResolver(client: catalog)

    let resolution = try await resolver.resolve(feedURL: feedURL, account: account)

    guard case .chooseLibraryAndFolder(let choices) = resolution else {
      Issue.record("Expected library and folder choices")
      return
    }
    #expect(choices.map(\.libraryID) == ["podcasts-zero", "podcasts-one", "podcasts-many"])
    #expect(choices.map(\.displayName) == ["Empty Podcasts", "One Folder", "Several Folders"])
    #expect(choices[0].folders.isEmpty)
    #expect(choices[1].folders == [ServerPodcastFolderChoice(folderID: "folder-one", displayName: "one")])
    #expect(
      choices[2].folders.map(\.folderID) == ["folder-two", "folder-three"])
    #expect(choices[2].folders.map(\.displayName) == ["two", "three"])
  }

  @Test func foldersSharingALeafNameAreToldApartWithoutTheirAbsoluteDirectory() async throws {
    let podcasts = library(
      id: "podcasts",
      name: "Podcasts",
      folders: [
        folder(id: "folder-a", path: "/media/nas-a/Podcasts"),
        folder(id: "folder-b", path: "/media/nas-b/Podcasts"),
        folder(id: "folder-c", path: "/media/nas-c/Archive"),
        folder(id: "folder-d", path: "/mnt/twin/Podcasts"),
        folder(id: "folder-e", path: "/srv/twin/Podcasts"),
      ])
    let catalog = CatalogStub(libraries: [podcasts])
    let resolver = ServerPodcastDestinationResolver(client: catalog)

    let resolution = try await resolver.resolve(feedURL: feedURL, account: account)

    guard case .chooseLibraryAndFolder(let choices) = resolution else {
      Issue.record("Expected library and folder choices")
      return
    }
    let names = choices[0].folders.map(\.displayName)
    #expect(
      names == [
        "nas-a/Podcasts", "nas-b/Podcasts", "Archive", "twin/Podcasts (1)", "twin/Podcasts (2)",
      ])
    #expect(Set(names).count == names.count)
    #expect(names.allSatisfy { $0.hasPrefix("/") == false })
    #expect(names.allSatisfy { $0.contains("/media") == false && $0.contains("/mnt") == false })
    #expect(choices[0].folders.map(\.folderID) == ["folder-a", "folder-b", "folder-c", "folder-d", "folder-e"])
  }

  @Test func aLeafThatReadsLikeANumberedLabelCannotCollideWithOne() async throws {
    let podcasts = library(
      id: "podcasts",
      name: "Podcasts",
      folders: [
        folder(id: "folder-a", path: "/mnt/twin/Podcasts"),
        folder(id: "folder-b", path: "/srv/twin/Podcasts"),
        folder(id: "folder-c", path: "/srv/other/twin%2FPodcasts%20(1)"),
      ])
    let catalog = CatalogStub(libraries: [podcasts])
    let resolver = ServerPodcastDestinationResolver(client: catalog)

    let resolution = try await resolver.resolve(feedURL: feedURL, account: account)

    guard case .chooseLibraryAndFolder(let choices) = resolution else {
      Issue.record("Expected library and folder choices")
      return
    }
    let names = choices[0].folders.map(\.displayName)
    #expect(Set(names).count == names.count, "\(names)")
    #expect(names[0] == "twin/Podcasts (1)")
    #expect(names[1] == "twin/Podcasts (2)")
    #expect(names[2] == "twin/Podcasts (1) (1)")
    #expect(choices[0].folders.map(\.folderID) == ["folder-a", "folder-b", "folder-c"])
  }

  @Test func oneExactNormalizedFeedMatchIsReused() async throws {
    let podcasts = library(id: "podcasts", name: "Podcasts", folders: [folder(id: "folder", path: "/srv")])
    let item = item(
      id: "server-show",
      libraryID: "podcasts",
      title: "Native Show",
      feedURL: "HTTPS://EXAMPLE.COM:443/Feed/")
    let catalog = CatalogStub(
      libraries: [podcasts],
      pages: ["podcasts": [0: page(items: [item], total: 1, limit: 100, page: 0)]])
    let resolver = ServerPodcastDestinationResolver(client: catalog)

    let resolution = try await resolver.resolve(
      feedURL: "https://example.com/Feed",
      account: account)

    guard case .reuse(let match) = resolution else {
      Issue.record("Expected one exact feed match to be reused")
      return
    }
    #expect(
      match
        == ServerPodcastMatch(
          serverItemID: "server-show",
          libraryID: "podcasts",
          feedFingerprint: PodcastFeedIdentity.fingerprint("https://example.com/Feed")!,
          displayName: "Native Show"))
  }

  @Test func multipleExactMatchesRequireAnExplicitExistingChoice() async throws {
    let podcasts = library(id: "podcasts", name: "Podcasts", folders: [folder(id: "folder", path: "/srv")])
    let first = item(id: "server-one", libraryID: "podcasts", title: "Show", feedURL: feedURL)
    let second = item(id: "server-two", libraryID: "podcasts", title: "Show", feedURL: feedURL)
    let catalog = CatalogStub(
      libraries: [podcasts],
      pages: [
        "podcasts": [
          0: page(items: [first], total: 2, limit: 1, page: 0),
          1: page(items: [second], total: 2, limit: 1, page: 1),
        ]
      ])
    let resolver = ServerPodcastDestinationResolver(client: catalog, pageLimit: 1)

    let resolution = try await resolver.resolve(feedURL: feedURL, account: account)

    guard case .chooseExisting(let candidates) = resolution else {
      Issue.record("Expected an explicit choice between multiple matches")
      return
    }
    #expect(candidates.map(\.serverItemID) == ["server-one", "server-two"])
    #expect(await catalog.recordedCalls().map(\.page) == [0, 1])
  }

  @Test func existingCandidatesCarryTitles() async throws {
    let podcasts = library(id: "podcasts", name: "Podcasts", folders: [folder(id: "folder", path: "/srv")])
    let first = item(id: "server-one", libraryID: "podcasts", title: "First Show", feedURL: feedURL)
    let second = item(id: "server-two", libraryID: "podcasts", title: "Second Show", feedURL: feedURL)
    let catalog = CatalogStub(
      libraries: [podcasts], pages: ["podcasts": [0: page(items: [first, second], total: 2, limit: 100, page: 0)]])
    let resolver = ServerPodcastDestinationResolver(client: catalog)

    let result = try await resolver.resolveNativeEpisodeServerSaveDestination(
      feedURL: URL(string: feedURL)!,
      nativeFeedTitle: "Native Show",
      account: account,
      choice: nil)

    guard case .needsChoice(.existing(let candidates)) = result else {
      Issue.record("Expected existing candidates")
      return
    }
    #expect(candidates.map(\.displayName) == ["First Show", "Second Show"])
  }

  @Test func missingTitleFallsBackToPlaceholder() async throws {
    let podcasts = library(id: "podcasts", name: "Podcasts", folders: [folder(id: "folder", path: "/srv")])
    let missing = item(id: "server-one", libraryID: "podcasts", title: nil, feedURL: feedURL)
    let whitespace = item(id: "server-two", libraryID: "podcasts", title: " \t\n ", feedURL: feedURL)
    let catalog = CatalogStub(
      libraries: [podcasts],
      pages: ["podcasts": [0: page(items: [missing, whitespace], total: 2, limit: 100, page: 0)]])
    let resolver = ServerPodcastDestinationResolver(client: catalog)

    let result = try await resolver.resolveNativeEpisodeServerSaveDestination(
      feedURL: URL(string: feedURL)!,
      nativeFeedTitle: "Native Show",
      account: account,
      choice: nil)

    guard case .needsChoice(.existing(let candidates)) = result else {
      Issue.record("Expected existing candidates")
      return
    }
    #expect(candidates.map(\.displayName) == ["Untitled podcast", "Untitled podcast"])
  }

  @Test func libraryAndFolderChoicesCarryNames() async throws {
    let podcasts = library(
      id: "podcasts",
      name: " My Podcasts ",
      folders: [
        folder(id: "folder-one", path: "/srv/News%20Shows"),
        folder(id: "folder-two", path: "/srv/Comedy%2FShows"),
      ])
    let catalog = CatalogStub(libraries: [podcasts])
    let resolver = ServerPodcastDestinationResolver(client: catalog)

    let result = try await resolver.resolveNativeEpisodeServerSaveDestination(
      feedURL: URL(string: feedURL)!,
      nativeFeedTitle: "Native Show",
      account: account,
      choice: nil)

    guard case .needsChoice(.libraryAndFolder(let libraries)) = result else {
      Issue.record("Expected library and folder choices")
      return
    }
    #expect(libraries[0].displayName == "My Podcasts")
    #expect(libraries[0].folders.map(\.displayName) == ["News Shows", "Comedy/Shows"])
  }

  @Test func hostileDisplayNamesAreBoundedAndSingleLine() async throws {
    let hostileValues = [
      "line one\nline two",
      "control\u{0000}\u{0007}text",
      "safe\u{202E}name",
      String(repeating: "x", count: 10_000),
      "",
      " \t\n ",
    ]
    let podcasts = library(id: "podcasts", name: "Podcasts", folders: [folder(id: "folder", path: "/srv")])
    let items = hostileValues.enumerated().map { index, title in
      item(id: "server-\(index)", libraryID: "podcasts", title: title, feedURL: feedURL)
    }
    let catalog = CatalogStub(
      libraries: [podcasts], pages: ["podcasts": [0: page(items: items, total: items.count, limit: 100, page: 0)]])
    let resolver = ServerPodcastDestinationResolver(client: catalog)

    let result = try await resolver.resolve(feedURL: feedURL, account: account)
    guard case .chooseExisting(let candidates) = result else {
      Issue.record("Expected one candidate for each hostile title")
      return
    }
    #expect(candidates.count == hostileValues.count)
    for candidate in candidates {
      #expect(candidate.displayName.isEmpty == false)
      #expect(candidate.displayName.count <= 256)
      #expect(candidate.displayName.contains(where: { $0.isNewline }) == false)
      #expect(
        candidate.displayName.unicodeScalars.allSatisfy {
          CharacterSet.controlCharacters.contains($0) == false
            && bidirectionalControls.contains($0) == false
        })
    }
    // A newline separates rather than fuses the words it stood between.
    #expect(candidates[0].displayName == "line one line two")
  }

  /// The sanitizer removes bidirectional overrides, which can make one picker row impersonate
  /// another. It must not reach further into Unicode's format category: these scalars carry
  /// ordinary meaning in ordinary titles.
  @Test func legitimateFormatCharactersSurviveSanitization() async throws {
    let podcasts = library(
      id: "podcasts", name: "Podcasts", folders: [folder(id: "folder", path: "/srv")])
    let titles = [
      "\u{200C}": "Persian ZWNJ",
      "\u{200D}": "emoji ZWJ",
      "\u{FE0F}": "emoji variation selector",
    ]
    let items = titles.keys.enumerated().map { index, scalar in
      item(id: "server-\(index)", libraryID: "podcasts", title: "a\(scalar)b", feedURL: feedURL)
    }
    let catalog = CatalogStub(
      libraries: [podcasts],
      pages: ["podcasts": [0: page(items: items, total: items.count, limit: 100, page: 0)]])
    let resolver = ServerPodcastDestinationResolver(client: catalog)

    let result = try await resolver.resolve(feedURL: feedURL, account: account)
    guard case .chooseExisting(let candidates) = result else {
      Issue.record("Expected one candidate for each title")
      return
    }
    for (scalar, description) in titles {
      #expect(
        candidates.contains { $0.displayName == "a\(scalar)b" },
        "\(description) should survive sanitization")
    }
  }

  private var bidirectionalControls: Set<Unicode.Scalar> {
    [
      "\u{200E}", "\u{200F}", "\u{061C}",
      "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
      "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
    ]
  }

  @Test func displayNamesNeverAppearInDescriptions() {
    let match = ServerPodcastMatch(
      serverItemID: "SENTINEL-ID",
      libraryID: "SENTINEL-ID",
      feedFingerprint: "SENTINEL-FINGERPRINT",
      displayName: "SENTINEL-NAME")
    let folder = NativeEpisodeServerSaveFolderChoice(
      folderID: "SENTINEL-ID", displayName: "SENTINEL-NAME")
    let library = NativeEpisodeServerSaveLibraryChoice(
      libraryID: "SENTINEL-ID", displayName: "SENTINEL-NAME", folders: [folder])
    let existingPrompt = NativeEpisodeServerSaveChoicePrompt.existing(
      candidates: [
        NativeEpisodeServerSaveExistingChoice(
          serverItemID: "SENTINEL-ID", displayName: "SENTINEL-NAME")
      ])
    let libraryPrompt = NativeEpisodeServerSaveChoicePrompt.libraryAndFolder(libraries: [library])

    for value in [
      match.description, match.debugDescription, String(reflecting: match),
      folder.description, folder.debugDescription, String(reflecting: folder),
      library.description, library.debugDescription, String(reflecting: library),
      existingPrompt.description, existingPrompt.debugDescription, String(reflecting: existingPrompt),
      libraryPrompt.description, libraryPrompt.debugDescription, String(reflecting: libraryPrompt),
    ] {
      #expect(value.contains("SENTINEL-NAME") == false)
      #expect(value.contains("SENTINEL-ID") == false)
    }
  }

  @Test func destinationSelectionIgnoresDisplayNames() async throws {
    let podcasts = library(id: "podcasts", name: "Podcasts", folders: [folder(id: "folder", path: "/srv")])
    let first = item(id: "server-one", libraryID: "podcasts", title: "Same Name", feedURL: feedURL)
    let second = item(id: "server-two", libraryID: "podcasts", title: "Same Name", feedURL: feedURL)
    let catalog = CatalogStub(
      libraries: [podcasts], pages: ["podcasts": [0: page(items: [first, second], total: 2, limit: 100, page: 0)]])
    let resolver = ServerPodcastDestinationResolver(client: catalog)

    let selected = try await resolver.resolveNativeEpisodeServerSaveDestination(
      feedURL: URL(string: feedURL)!,
      nativeFeedTitle: "Native Show",
      account: account,
      choice: .existing(serverItemID: "server-two"))
    #expect(selected == .reuse(serverItemID: "server-two"))

    do {
      _ = try await resolver.resolveNativeEpisodeServerSaveDestination(
        feedURL: URL(string: feedURL)!,
        nativeFeedTitle: "Native Show",
        account: account,
        choice: .existing(serverItemID: "missing-id"))
      Issue.record("Expected an absent catalogue id to be rejected")
    } catch ServerPodcastDestinationResolverError.invalidChoice {
      // Expected.
    }
  }

  @Test func destinationBoundaryEnumeratesOnlyOpaqueSelectionsAndNames() {
    let choices: [ServerPodcastSaveChoice] = [
      .existing(serverItemID: "server-item-id"),
      .libraryAndFolder(libraryID: "library-id", folderID: "folder-id"),
    ]
    for choice in choices {
      switch choice {
      case .existing(let serverItemID):
        #expect(serverItemID == "server-item-id")
      case .libraryAndFolder(let libraryID, let folderID):
        #expect(libraryID == "library-id")
        #expect(folderID == "folder-id")
      }
    }

    let prompts: [NativeEpisodeServerSaveChoicePrompt] = [
      .existing(candidates: [
        NativeEpisodeServerSaveExistingChoice(
          serverItemID: "server-item-id", displayName: "Podcast display name")
      ]),
      .libraryAndFolder(libraries: [
        NativeEpisodeServerSaveLibraryChoice(
          libraryID: "library-id",
          displayName: "Library display name",
          folders: [
            NativeEpisodeServerSaveFolderChoice(
              folderID: "folder-id", displayName: "Folder display name")
          ])
      ]),
    ]
    for prompt in prompts {
      switch prompt {
      case .existing(let candidates):
        #expect(candidates.allSatisfy { $0.serverItemID == "server-item-id" })
        #expect(candidates.allSatisfy { $0.displayName == "Podcast display name" })
      case .libraryAndFolder(let libraries):
        #expect(libraries.allSatisfy { $0.libraryID == "library-id" })
        #expect(libraries.allSatisfy { $0.displayName == "Library display name" })
        #expect(libraries.flatMap(\.folders).allSatisfy { $0.folderID == "folder-id" })
        #expect(libraries.flatMap(\.folders).allSatisfy { $0.displayName == "Folder display name" })
      }
    }
  }

  @Test func destinationSelectionIgnoresHostileDisplayNamesOnCreate() async throws {
    let hostileDisplayNames = [
      "../escape", "file://escape", "/absolute/path", "https://evil.invalid",
    ]
    let expectedPath: String
    guard
      case .success(let generatedPath) = ServerPodcastPathGeneration.generate(
        folderFullPath: "/srv/podcasts", nativeFeedTitle: "RSS/../Show")
    else {
      Issue.record("Expected the native title to produce a bounded child path")
      return
    }
    expectedPath = generatedPath

    for hostileDisplayName in hostileDisplayNames {
      let podcasts = library(
        id: "podcasts",
        name: hostileDisplayName,
        folders: [folder(id: "folder", path: "/srv/podcasts")])
      let catalog = CatalogStub(libraries: [podcasts])
      let resolver = ServerPodcastDestinationResolver(client: catalog)

      let result = try await resolver.resolveNativeEpisodeServerSaveDestination(
        feedURL: URL(string: feedURL)!,
        nativeFeedTitle: "RSS/../Show",
        account: account,
        choice: .libraryAndFolder(libraryID: "podcasts", folderID: "folder"))

      guard case .create(let destination) = result else {
        Issue.record("Expected a create destination")
        continue
      }
      #expect(destination.childPath == expectedPath)
      #expect(destination.childPath.contains(hostileDisplayName) == false)
      #expect(destination.folderID == "folder")
    }
  }

  @Test func normalizationPreservesPathAndQueryIdentity() {
    #expect(
      PodcastFeedIdentity.normalized("HTTP://EXAMPLE.COM:80/Feed/")
        == "http://example.com/Feed")
    #expect(
      PodcastFeedIdentity.normalized("https://Example.com:443/Feed/?Key=MiXeD")
        == "https://example.com/Feed?Key=MiXeD")
    #expect(
      PodcastFeedIdentity.normalized("https://example.com/Feed")
        != PodcastFeedIdentity.normalized("https://example.com/feed"))
    #expect(
      PodcastFeedIdentity.normalized("https://example.com/Feed")
        != PodcastFeedIdentity.normalized("https://example.com/Other"))
    #expect(
      PodcastFeedIdentity.normalized("https://example.com/Feed")
        != PodcastFeedIdentity.normalized("https://example.com/Feed?x=1"))
    #expect(
      PodcastFeedIdentity.normalized("http://example.com/Feed")
        != PodcastFeedIdentity.normalized("https://example.com/Feed"))
  }

  @Test func differingPathQueryAndTitleAreNotIdentityMatches() async throws {
    let podcasts = library(id: "podcasts", name: "Podcasts", folders: [folder(id: "folder", path: "/srv")])
    let items = [
      item(
        id: "different-path",
        libraryID: "podcasts",
        title: "Native Show",
        feedURL: "https://example.com/other"),
      item(
        id: "different-query",
        libraryID: "podcasts",
        title: "Native Show",
        feedURL: "https://example.com/feed?version=2"),
      item(
        id: "missing-feed",
        libraryID: "podcasts",
        title: "Native Show",
        feedURL: nil),
      item(
        id: "invalid-feed",
        libraryID: "podcasts",
        title: "Native Show",
        feedURL: "ftp://example.com/feed"),
    ]
    let catalog = CatalogStub(
      libraries: [podcasts],
      pages: ["podcasts": [0: page(items: items, total: 4, limit: 100, page: 0)]])
    let resolver = ServerPodcastDestinationResolver(client: catalog)

    let resolution = try await resolver.resolve(feedURL: feedURL, account: account)

    guard case .chooseLibraryAndFolder(let choices) = resolution else {
      Issue.record("A title collision with a different feed must not be reused")
      return
    }
    #expect(choices.count == 1)
    #expect(choices[0].libraryID == "podcasts")
  }

  @Test func inconsistentTotalsStopAtThePageCeiling() async throws {
    let podcasts = library(id: "podcasts", name: "Podcasts", folders: [folder(id: "folder", path: "/srv")])
    let catalog = CatalogStub(
      libraries: [podcasts],
      pages: [
        "podcasts": [
          0: page(items: [], total: 10_000, limit: 1, page: 0),
          1: page(items: [], total: 10_000, limit: 1, page: 1),
        ]
      ])
    let resolver = ServerPodcastDestinationResolver(client: catalog, pageLimit: 1, pageCeiling: 2)

    do {
      _ = try await resolver.resolve(feedURL: feedURL, account: account)
      Issue.record("Expected the inconsistent catalogue to hit the page ceiling")
    } catch ServerPodcastDestinationResolverError.pageCeilingReached {
      #expect(await catalog.recordedCalls().map(\.page) == [0, 1])
    } catch {
      Issue.record("Inconsistent pagination produced an unexpected error")
    }
  }

  @Test func multiPageTraversalUsesPageMetadataAndReachesTheMatch() async throws {
    let podcasts = library(id: "podcasts", name: "Podcasts", folders: [folder(id: "folder", path: "/srv")])
    let match = item(id: "server-show", libraryID: "podcasts", title: "Show", feedURL: feedURL)
    let catalog = CatalogStub(
      libraries: [podcasts],
      pages: [
        "podcasts": [
          0: page(items: [], total: 3, limit: 1, page: 0),
          1: page(items: [], total: 3, limit: 1, page: 1),
          2: page(items: [match], total: 3, limit: 1, page: 2),
        ]
      ])
    let resolver = ServerPodcastDestinationResolver(client: catalog, pageLimit: 1)

    let resolution = try await resolver.resolve(feedURL: feedURL, account: account)

    guard case .reuse(let resolvedMatch) = resolution else {
      Issue.record("Expected the match on the final page to be found")
      return
    }
    #expect(resolvedMatch.serverItemID == "server-show")
    #expect(await catalog.recordedCalls().map(\.page) == [0, 1, 2])
  }

  @Test func cancellationBetweenPagesStopsTraversal() async throws {
    let podcasts = library(id: "podcasts", name: "Podcasts", folders: [folder(id: "folder", path: "/srv")])
    let gate = CatalogFetchGate()
    let catalog = CatalogStub(
      libraries: [podcasts],
      pages: ["podcasts": [0: page(items: [], total: 2, limit: 1, page: 0)]],
      gate: gate)
    let resolver = ServerPodcastDestinationResolver(client: catalog, pageLimit: 1)
    let task = Task {
      try await resolver.resolve(feedURL: feedURL, account: account)
    }

    _ = await awaitCondition("the resolver requests the first catalogue page") {
      await catalog.recordedCalls().contains { $0.page == 0 }
    }
    task.cancel()
    await gate.release()

    do {
      _ = try await task.value
      Issue.record("Cancelled traversal unexpectedly completed")
    } catch is CancellationError {
      #expect(await catalog.recordedCalls().map(\.page) == [0])
    } catch {
      Issue.record("Cancellation produced an unexpected error")
    }
  }

  private let feedURL = "https://example.com/feed"

  private let account = try! TokenAccount(
    serverURL: URL(string: "https://example.test")!, userID: "user-fixture")

  private func library(
    id: String,
    name: String,
    mediaType: String? = "podcast",
    folders: [LibraryFolder] = []
  ) -> Library {
    Library(
      id: id,
      name: name,
      mediaType: mediaType,
      onlyShowLaterBooksInContinueSeries: false,
      folders: folders)
  }

  private func folder(id: String, path: String) -> LibraryFolder {
    LibraryFolder(id: id, fullPath: path, libraryID: "podcasts")
  }

  private func item(
    id: String,
    libraryID: String,
    title: String?,
    feedURL: String?
  ) -> LibraryItemSummary {
    LibraryItemSummary(
      id: id,
      libraryID: libraryID,
      mediaType: "podcast",
      title: title,
      authorName: nil,
      seriesName: nil,
      feedURLState: feedURL.map(PodcastFeedURLState.value) ?? .absent)
  }

  private func page(
    items: [LibraryItemSummary],
    total: Int,
    limit: Int,
    page: Int
  ) -> LibraryItemsPage {
    LibraryItemsPage(items: items, total: total, limit: limit, page: page)
  }
}

private struct CatalogCall: Sendable, Equatable {
  let libraryID: String
  let page: Int
  let limit: Int
}

private actor CatalogFetchGate {
  // The fetch runs to completion regardless of cancellation, so a cancelled one stays parked.
  private nonisolated let gate = TestGate<Void>(
    label: "CatalogFetchGate wait", ignoresCancellation: true)

  init() {
    gate.hold()
  }

  func wait() async {
    await gate.pass()
  }

  func release() {
    gate.release()
  }
}

private actor CatalogStub: ServerPodcastCatalogReading {
  private let libraries: [Library]
  private let pages: [String: [Int: LibraryItemsPage]]
  private let gate: CatalogFetchGate?
  private(set) var calls = [CatalogCall]()

  init(
    libraries: [Library],
    pages: [String: [Int: LibraryItemsPage]] = [:],
    gate: CatalogFetchGate? = nil
  ) {
    self.libraries = libraries
    self.pages = pages
    self.gate = gate
  }

  func listPodcastCatalogLibraries(account: TokenAccount) async throws -> [Library] {
    libraries
  }

  func listPodcastCatalogItems(
    account: TokenAccount,
    libraryID: String,
    page: Int,
    limit: Int
  ) async throws -> LibraryItemsPage {
    calls.append(CatalogCall(libraryID: libraryID, page: page, limit: limit))
    if let gate {
      await gate.wait()
    }
    return pages[libraryID]?[page]
      ?? LibraryItemsPage(items: [], total: 0, limit: limit, page: page)
  }

  func recordedCalls() -> [CatalogCall] { calls }
}
