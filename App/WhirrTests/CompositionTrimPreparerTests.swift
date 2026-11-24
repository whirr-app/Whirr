import AVFoundation
import AppModel
import PlayerCore
import Testing

@testable import Whirr

/// Exercises the real AVFoundation composition build against bundled media.
@Suite("Composition trim preparer")
struct CompositionTrimPreparerTests {

  private final class Registrations: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(URL, PlayerTrimMap, AVAsset)] = []

    func add(_ url: URL, _ map: PlayerTrimMap, _ asset: AVAsset) {
      lock.withLock { stored.append((url, map, asset)) }
    }

    var all: [(URL, PlayerTrimMap, AVAsset)] { lock.withLock { stored } }
  }

  private func fixtureURL(_ name: String) throws -> URL {
    let bundle = Bundle(for: BundleToken.self)
    if let url = bundle.url(forResource: name, withExtension: "m4a", subdirectory: "Fixtures") {
      return url
    }
    return try #require(bundle.url(forResource: name, withExtension: "m4a"))
  }

  private func makePreparer(_ registrations: Registrations) -> CompositionTrimPreparer {
    CompositionTrimPreparer { url, map, asset in registrations.add(url, map, asset) }
  }

  @Test("registers a composition shorter than the file by the total trimmed", .timeLimit(.minutes(1)))
  func compositionDurationIsSourceMinusTrimmed() async throws {
    let url = try fixtureURL("playback-fixture-track1")
    let sourceDuration = try await AVURLAsset(url: url).load(.duration).seconds
    let map = PlayerTrimMap(cuts: [
      PlayerTrimMap.Cut(start: sourceDuration * 0.2, end: sourceDuration * 0.3),
      PlayerTrimMap.Cut(start: sourceDuration * 0.5, end: sourceDuration * 0.55),
    ])
    let registrations = Registrations()

    let prepared = await makePreparer(registrations).prepare(map: map, forFileURL: url, timing: .estimated)

    #expect(prepared)
    let registered = try #require(registrations.all.first)
    #expect(registrations.all.count == 1)
    #expect(registered.0 == url)
    #expect(registered.1 == map)
    let duration = try await registered.2.load(.duration).seconds
    #expect(abs(duration - (sourceDuration - map.totalTrimmed)) <= 1.0 / 44_100 + 1e-9)
  }

  @Test("asks for precise timing only for a file whose estimate drifts")
  func sourceOptionsRequestPreciseTimingOnlyWhenAsked() {
    let mp3 = URL(fileURLWithPath: "/downloads/episode.mp3")
    let mpeg = URL(fileURLWithPath: "/downloads/episode.mpeg")

    let estimated = CompositionTrimPreparer.sourceOptions(forFileURL: mp3, timing: .estimated)
    let precise = CompositionTrimPreparer.sourceOptions(forFileURL: mp3, timing: .precise)
    let legacy = CompositionTrimPreparer.sourceOptions(forFileURL: mpeg, timing: .precise)

    #expect(estimated[AVURLAssetPreferPreciseDurationAndTimingKey] == nil)
    #expect(precise[AVURLAssetPreferPreciseDurationAndTimingKey] as? Bool == true)
    #expect(legacy[AVURLAssetPreferPreciseDurationAndTimingKey] as? Bool == true)
    #expect(legacy[AVURLAssetOverrideMIMETypeKey] as? String == "audio/mpeg")
  }

  @Test("a precise composition is shorter than the file by the total trimmed", .timeLimit(.minutes(1)))
  func preciseCompositionDurationIsSourceMinusTrimmed() async throws {
    let url = try fixtureURL("playback-fixture-track1")
    let sourceDuration = try await AVURLAsset(url: url).load(.duration).seconds
    let map = PlayerTrimMap(cuts: [PlayerTrimMap.Cut(start: sourceDuration * 0.4, end: sourceDuration * 0.5)])
    let registrations = Registrations()

    let prepared = await makePreparer(registrations).prepare(map: map, forFileURL: url, timing: .precise)

    #expect(prepared)
    let registered = try #require(registrations.all.first)
    let duration = try await registered.2.load(.duration).seconds
    #expect(abs(duration - (sourceDuration - map.totalTrimmed)) <= 1.0 / 44_100 + 1e-9)
  }

  @Test("an unreadable URL fails without registering", .timeLimit(.minutes(1)))
  func unreadableURLReturnsFalse() async {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("missing-\(UUID().uuidString).m4a")
    let registrations = Registrations()
    let map = PlayerTrimMap(cuts: [PlayerTrimMap.Cut(start: 1, end: 2)])

    let prepared = await makePreparer(registrations).prepare(map: map, forFileURL: url, timing: .estimated)

    #expect(!prepared)
    #expect(registrations.all.isEmpty)
  }

  private final class BundleToken {}
}
