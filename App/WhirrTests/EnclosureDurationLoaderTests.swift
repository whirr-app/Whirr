import Foundation
import Testing

@testable import Whirr

/// Exercises the real AVFoundation-backed loader against bundled media, so the seam
/// `RSSEpisodeDurationResolver` injects is proven against the framework rather than a fake.
@Suite("Enclosure duration loader")
struct EnclosureDurationLoaderTests {

  private enum FixtureError: Error {
    case missing(String)
  }

  private func fixtureURL(_ name: String) throws -> URL {
    let bundle = Bundle(for: BundleToken.self)
    if let url = bundle.url(forResource: name, withExtension: "m4a", subdirectory: "Fixtures") {
      return url
    }
    if let url = bundle.url(forResource: name, withExtension: "m4a") {
      return url
    }
    throw FixtureError.missing(name)
  }

  @Test("measures a real media file", .timeLimit(.minutes(1)))
  func measuresBundledMedia() async throws {
    let duration = try await AVAssetEnclosureDurationLoader()
      .loadDuration(for: try fixtureURL("playback-fixture-track1"))

    let seconds = try #require(duration)
    #expect(seconds.isFinite)
    #expect(seconds > 0)
  }

  @Test("reports unknown rather than failing for a body that is not media", .timeLimit(.minutes(1)))
  func nonMediaBodyIsUnknown() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("enclosure-\(UUID().uuidString).mp3")
    try Data("not audio".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try await AVAssetEnclosureDurationLoader().loadDuration(for: url) == nil)
  }

  @Test("reports unknown for an unreachable enclosure", .timeLimit(.minutes(1)))
  func missingFileIsUnknown() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("absent-\(UUID().uuidString).mp3")

    #expect(try await AVAssetEnclosureDurationLoader().loadDuration(for: url) == nil)
  }
}

private final class BundleToken {}
