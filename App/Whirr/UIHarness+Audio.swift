#if DEBUG || PERF_INVESTIGATION
  import ABSApi
  import AppModel
  import DesignSystem
  import Foundation
  import MediaPlayer
  import Persistence
  import PlayerCore
  import ReaderCore
  import SwiftUI
  import SyncEngine
  import UIKit
  import os

  /// The harness's playback hardware must not register on the process-wide remote-command centre:
  /// the app's own `PlaybackHardware.shared` already owns those handlers, and a second registration
  /// would make a lock-screen command ambiguous. Nothing in the harness is commanded remotely.
  @MainActor
  final class HarnessRemoteCommandCenter: RemoteCommandRegistering {
    func setPlayHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {}
    func setPauseHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {}
    func setTogglePlayPauseHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {}
    func setStopHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {}
    func setSkipForwardHandler(
      intervalSeconds: TimeInterval, handler: @escaping () -> MPRemoteCommandHandlerStatus
    ) {}
    func setSkipBackwardHandler(
      intervalSeconds: TimeInterval, handler: @escaping () -> MPRemoteCommandHandlerStatus
    ) {}
    func setNextTrackHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {}
    func setPreviousTrackHandler(_ handler: @escaping () -> MPRemoteCommandHandlerStatus) {}
    func setChangePlaybackPositionHandler(
      _ handler: @escaping (TimeInterval) -> MPRemoteCommandHandlerStatus
    ) {}
    func setChangePlaybackRateHandler(
      _ handler: @escaping (Double) -> MPRemoteCommandHandlerStatus
    ) {}
    func setSkipIntervals(forwardSeconds: TimeInterval, backwardSeconds: TimeInterval) {}
    func setSupportedPlaybackRates(_ rates: [Double]) {}
    func removeAllTargets() {}
  }

  /// Preferences the harness's own hardware reads, in a suite of their own so nothing here reads or
  /// writes the app's Voice Boost preference.
  nonisolated enum HarnessPreferences {
    static let suiteName = "whirr.harness.playback"

    @MainActor static let defaults: UserDefaults = {
      let defaults = UserDefaults(suiteName: suiteName) ?? .standard
      defaults.removePersistentDomain(forName: suiteName)
      return defaults
    }()
  }

  /// Simulated audio hardware matching `AVQueuePlayerAudioEngine`'s events, so on-device transport
  /// bugs reproduce in the simulator: seek completion emits `.ready` (never a position), ticks flow
  /// only while "playing" and report the pre-seek clock during a seek, and with
  /// `WHIRR_UI_HARNESS_LATENCY=<seconds>` play/seek pass through `.buffering` first.
  @MainActor
  final class HarnessAudioEngine: AudioEngine {
    let events: AsyncStream<AudioEngineEvent>
    private let continuation: AsyncStream<AudioEngineEvent>.Continuation

    private var generation = 0
    private var localOffset: Double = 0
    private var rate: Double = 1
    private(set) var volume: Double = 1
    private var trackDuration: Double = 0
    private var tickTask: Task<Void, Never>?
    private var bufferTask: Task<Void, Never>?
    /// Ticking, or buffering on the way to it. As with a real `AVPlayer`, `play()` while playing
    /// is a no-op that must not flap `timeControlStatus` (the reducer re-asserts intent on every
    /// ready-resolution).
    private var isEnginePlaying = false
    /// A seek is in flight: ticks keep reporting the pre-seek position, as the real player does.
    private var isSeeking = false

    /// Simulated stream latency: how long play/seek "buffer" before the engine reports ready.
    private let latency: Double =
      ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_LATENCY"].flatMap(Double.init) ?? 0

    init() {
      var continuation: AsyncStream<AudioEngineEvent>.Continuation!
      events = AsyncStream { continuation = $0 }
      self.continuation = continuation
    }

    /// `WHIRR_UI_HARNESS_ENGINE=fail` makes every load fail the way a stream URL the server rejects
    /// does. It is the one player state whose layout can only be inspected while it is on screen.
    private let failsEveryLoad = ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_ENGINE"] == "fail"

    func load(
      track: PlaybackTrack, localOffset: Double, rate: Double, generation: Int, trim: PlayerTrimMap? = nil
    ) {
      stopTicking()
      bufferTask?.cancel()
      isEnginePlaying = false
      self.generation = generation
      self.localOffset = localOffset
      self.rate = rate
      trackDuration = track.duration ?? UIHarnessFixtures.duration
      // The harness clock ticks the whole file, so a map is declined as a real engine without it
      // would decline it.
      if trim != nil { continuation.yield(.trimDeclined(generation: generation)) }
      guard failsEveryLoad == false else {
        continuation.yield(
          .failed(
            generation: generation,
            AudioEngineFailure(
              isRecoverable: true, message: "The requested URL was not found on this server.")))
        return
      }
      continuation.yield(.ready(generation: generation))
    }

    func play() {
      guard isEnginePlaying == false else { return }
      isEnginePlaying = true
      afterBuffering {
        if self.isEnginePlaying { self.startTicking() }
      }
    }

    /// Leaves any in-flight `bufferTask` running: a real player's pause doesn't cancel an
    /// in-flight seek, and its completion still arrives (the body above and `seek` check
    /// `isEnginePlaying` before resuming ticks).
    func pause() {
      isEnginePlaying = false
      stopTicking()
    }

    func seek(toLocalOffset offset: Double) {
      let target = min(max(0, offset), trackDuration)
      // A real player's clock does not jump to the target when the seek is requested. It stalls
      // at the position being seeked away from and keeps reporting it on the same periodic cadence
      // until the seek lands, so ticks arriving during the seek window carry the listener's old
      // position, not their new one. Setting `localOffset` here would make every tick already
      // correct, so the reducer's stale-tick defect could not be reproduced in the simulator.
      isSeeking = true
      afterBuffering {
        self.isSeeking = false
        self.localOffset = target
        // The real adapter's seek completion path: `.ready`, carrying no position.
        self.continuation.yield(.ready(generation: self.generation))
        if self.isEnginePlaying { self.startTicking() }
      }
    }

    func setRate(_ rate: Double) {
      self.rate = rate
    }

    func setVolume(_ volume: Double) {
      self.volume = volume
    }

    /// The harness never loads skip ranges, so nothing arms a boundary; its own ticks stand in.
    func setBoundary(atLocalOffset offset: Double?) {}

    func stop() {
      isEnginePlaying = false
      bufferTask?.cancel()
      stopTicking()
    }

    /// With nonzero latency, emits `.buffering` immediately and runs `body` after the simulated
    /// stall (the `timeControlStatus` flap `RealAudioQueuePlayer` observes); with zero latency,
    /// runs `body` synchronously.
    private func afterBuffering(_ body: @escaping @MainActor () -> Void) {
      bufferTask?.cancel()
      guard latency > 0 else {
        body()
        return
      }
      continuation.yield(.buffering(generation: generation))
      bufferTask = Task { [latency] in
        try? await Task.sleep(for: .seconds(latency))
        guard Task.isCancelled == false else { return }
        body()
      }
    }

    private func startTicking() {
      stopTicking()
      continuation.yield(.ready(generation: generation))
      // Report the position playback is (re)starting from before the first 1s tick advances it.
      // Otherwise the first tick after a load reports localOffset+rate, skipping the loaded
      // position, visible as a ~1s jump when a track finishes and the next one loads at offset 0
      // (a real 0.5s time observer reports the new track's clock continuously from its start).
      continuation.yield(.positionUpdated(generation: generation, localOffset: localOffset))
      tickTask = Task { [weak self] in
        while Task.isCancelled == false {
          try? await Task.sleep(for: .seconds(1))
          guard let self, Task.isCancelled == false else { return }
          // A seek in flight freezes the clock at the pre-seek position (the stale-tick fidelity).
          guard isSeeking == false else {
            harnessNote(.playbackPeriodicPosition)
            continuation.yield(.positionUpdated(generation: generation, localOffset: localOffset))
            continue
          }
          let advanced = localOffset + rate
          if advanced >= trackDuration {
            // Reached this track's end: a real `AVPlayerItem` fires `onDidPlayToEnd`, then
            // `.trackFinished`, and the reducer auto-advances to the next track (or ends the item);
            // the follow-on `load` restarts ticking on the new track. Stop here so a finished track
            // doesn't keep ticking past its own end.
            localOffset = trackDuration
            continuation.yield(.trackFinished(generation: generation))
            return
          }
          localOffset = advanced
          harnessNote(.playbackPeriodicPosition)
          continuation.yield(.positionUpdated(generation: generation, localOffset: localOffset))
        }
      }
    }

    private func stopTicking() {
      tickTask?.cancel()
      tickTask = nil
    }
  }

  struct HarnessPlaybackSyncing: PlaybackSyncing {
    /// One downloaded file, the only shape ad skip applies to, for the Reduce Ads offer screen.
    var preparesLocalEpisode = false

    func startSession(itemID: String, episodeID: String?) async throws -> PreparedPlayback {
      if preparesLocalEpisode {
        return PreparedPlayback(
          itemID: itemID, episodeID: episodeID, startPosition: 45, duration: 3_600,
          tracks: [
            PreparedPlaybackTrack(
              index: 0, startOffset: 0, duration: 3_600,
              url: URL(fileURLWithPath: "/harness/episode.mp3"), mimeType: "audio/mpeg", title: nil)
          ],
          chapters: [], source: .local)
      }
      let chapterLength = UIHarnessFixtures.duration / 11
      return PreparedPlayback(
        itemID: itemID,
        episodeID: episodeID,
        startPosition: 45,
        duration: UIHarnessFixtures.duration,
        // Multi-track (one file per ~2.75 chapters), not aligned to the 3360s chapter
        // grid: track boundaries at 9240/18480/27720 fall mid-chapter, so cross-track seeks, the
        // reducer's generation bump on a cross-track load, and `.trackFinished` auto-advance across
        // a file boundary all get exercised, covering the whole `AVQueuePlayer` path. Chapters
        // still span the book on their own grid.
        tracks: (0..<UIHarnessFixtures.trackCount).map { index in
          PreparedPlaybackTrack(
            index: index, startOffset: Double(index) * UIHarnessFixtures.trackLength,
            duration: UIHarnessFixtures.trackLength,
            url: URL(string: "http://127.0.0.1:9/harness-\(index).m4b")!, mimeType: "audio/mp4", title: nil)
        },
        chapters: (0..<11).map { index in
          PreparedPlaybackChapter(
            id: index, start: Double(index) * chapterLength, end: Double(index + 1) * chapterLength,
            title: "Chapter \(index + 1)")
        }
      )
    }

    func promoteStreamingSessionToLocalDownload(
      itemID: String, episodeID: String?, currentPosition: Double, streamedDuration: Double?
    ) async -> PreparedPlayback? { nil }

    func stopSession() async throws {}
    /// The harness serves local fixture URLs that carry no credential, so nothing to renew.
    func renewStreamAuthorization() async throws -> PlaybackStreamAuthorization? { nil }
    func notifyPlaybackPhase(_ phase: PlaybackCadencePhase) async {}
    func willStartPlayback(itemID: String) {}
    func notifyImmediateSyncTrigger(_ trigger: PlaybackImmediateSyncTrigger) async {}
    func handleAppBackgrounded() async {}
    func recoverOpenSessions() async {}
    func quiesceForLogout() async {}
    func recordProgressTick(
      itemID: String, episodeID: String?, currentTime: Double, listenedDelta: Double,
      isFinished: Bool, isSeek: Bool, sleepTimerExpired: Bool = false
    ) async {}
  }
#endif
