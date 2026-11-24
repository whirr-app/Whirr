import AVFoundation
import PlayerCore
import Testing

@testable import Whirr

/// Small simulator integration test. Plays real, bundled, generated audio fixtures through
/// `AVQueuePlayerAudioEngine` backed by the real `AVQueuePlayer`/`AVPlayerItem` wrappers, across a
/// track boundary and a seek. Kept minimal: real-device boundary gaps are measured on hardware, not
/// here. This only proves the adapter's real-AVFoundation wiring runs end to end.
@MainActor
@Suite("Playback fixture integration (simulator)")
struct PlaybackFixtureIntegrationTests {

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

  @Test("plays a bundled fixture across a track boundary, then seeks", .timeLimit(.minutes(1)))
  func playsAcrossBoundaryThenSeeks() async throws {
    let track1 = try fixtureURL("playback-fixture-track1")
    let track2 = try fixtureURL("playback-fixture-track2")

    // Muted rather than zero volume: the engine writes `volume` itself, and a muted player still
    // plays in real time, so item-end and boundary events fire as they would audibly.
    let player = AVQueuePlayer()
    player.isMuted = true
    let engine = AVQueuePlayerAudioEngine(
      queuePlayer: RealAudioQueuePlayer(player: player),
      itemFactory: AVFoundationPlayerItemFactory(),
      session: AudioSessionConfigurator(session: FakeAudioSessionControlling()))
    engine.configure(tracks: [
      PlaybackTrackResource(trackIndex: 0, url: track1),
      PlaybackTrackResource(trackIndex: 1, url: track2),
    ])

    var iterator = engine.events.makeAsyncIterator()
    engine.load(track: PlaybackTrack(index: 0, duration: 1), localOffset: 0, rate: 1.0, generation: 1)

    var sawInitialReady = false
    var sawBoundary = false
    var sawNextTrackReady = false

    while !(sawInitialReady && sawBoundary && sawNextTrackReady), let event = await iterator.next() {
      switch event {
      case .ready(let generation) where generation == 1 && !sawInitialReady:
        sawInitialReady = true
        engine.play()
      case .trackFinished(let generation) where generation == 1:
        sawBoundary = true
        engine.load(track: PlaybackTrack(index: 1, duration: 1), localOffset: 0, rate: 1.0, generation: 2)
      case .ready(let generation) where generation == 2:
        sawNextTrackReady = true
      case .failed(_, let failure):
        Issue.record("engine reported a failure: \(failure.message)")
        return
      default:
        break
      }
    }

    #expect(sawInitialReady)
    #expect(sawBoundary, "AVQueuePlayer auto-advanced across the track boundary")
    #expect(sawNextTrackReady)

    engine.seek(toLocalOffset: 0.1)
    engine.stop()
  }

  private final class BundleToken {}
}
