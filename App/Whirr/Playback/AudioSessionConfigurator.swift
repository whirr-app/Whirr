import AVFoundation

/// Wraps the small slice of `AVAudioSession` behavior playback configuration needs, so
/// `AudioSessionConfigurationTests` can inject a fake instead of mutating the real, process-wide
/// shared session from a unit test. Nonisolated and `Sendable` because these calls block on the
/// system audio server and so run away from the main actor (`AudioSessionWorkRunning`).
nonisolated protocol AudioSessionControlling: Sendable {
  func setCategory(
    _ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions
  ) throws
  func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

/// Real `AudioSessionControlling`, wrapping `AVAudioSession.sharedInstance()`. `@unchecked` because
/// the shared session is safe to call from any thread but is not declared `Sendable`.
nonisolated final class RealAudioSessionControlling: AudioSessionControlling, @unchecked Sendable {
  private let session: AVAudioSession

  init(session: AVAudioSession = .sharedInstance()) {
    self.session = session
  }

  func setCategory(
    _ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions
  ) throws {
    try session.setCategory(category, mode: mode, options: options)
  }

  func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
    try session.setActive(active, options: options)
  }
}

/// Where the session's blocking calls run. Implementations run work in the order it was handed
/// over, one piece at a time, and deliver each completion on the main actor in that same order,
/// so a deactivation requested after an activation always takes effect after it.
nonisolated protocol AudioSessionWorkRunning: Sendable {
  @MainActor
  func run<Outcome: Sendable>(
    _ work: @escaping @Sendable () -> Outcome, then completion: @escaping @MainActor (Outcome) -> Void)
}

/// Production runner. Activating a session the OS has deactivated (the first play after the app
/// sat paused in the background) blocks its caller for a noticeable fraction of a second while the
/// audio route spins up. On the main thread that stall swallows the opening frames of whatever the
/// same tap animates, so the work goes to a serial queue instead.
nonisolated final class BackgroundAudioSessionWork: AudioSessionWorkRunning {
  private let queue = DispatchQueue(label: "app.whirr.audio-session", qos: .userInitiated)

  @MainActor
  func run<Outcome: Sendable>(
    _ work: @escaping @Sendable () -> Outcome, then completion: @escaping @MainActor (Outcome) -> Void
  ) {
    queue.async {
      let outcome = work()
      DispatchQueue.main.async {
        MainActor.assumeIsolated { completion(outcome) }
      }
    }
  }
}

/// Runs the work and its completion before returning. For tests that want the handshake to stay
/// synchronous; never for production, where it puts the blocking calls back on the main thread.
nonisolated struct InlineAudioSessionWork: AudioSessionWorkRunning {
  @MainActor
  func run<Outcome: Sendable>(
    _ work: @escaping @Sendable () -> Outcome, then completion: @escaping @MainActor (Outcome) -> Void
  ) {
    completion(work())
  }
}

/// What the two halves of the playback handshake returned; `nil` means that half succeeded.
nonisolated struct AudioSessionActivationOutcome: Sendable {
  let configureError: (any Error)?
  let activateError: (any Error)?
}

/// Configures and (de)activates the shared audio session for spoken-word playback
/// (ARCHITECTURE.md §4: "`.playback` category + `.spokenAudio` mode ... for speech at variable
/// rate"). Narrow by design: no interruption/route-change observation, and since the
/// category is `.playback`, never `.playAndRecord` or `.record`, this never triggers a
/// microphone/recording permission prompt.
@MainActor
final class AudioSessionConfigurator {
  private let session: AudioSessionControlling
  private let work: AudioSessionWorkRunning

  init(session: AudioSessionControlling, work: AudioSessionWorkRunning = InlineAudioSessionWork()) {
    self.session = session
    self.work = work
  }

  /// Sets the documented audiobook/podcast category+mode, then activates. Setting the category is
  /// idempotent, so it is repeated before every activation. A refused category does not stop the
  /// activation attempt; the outcome reports each half separately.
  func activateForPlayback(then completion: @escaping @MainActor (AudioSessionActivationOutcome) -> Void) {
    let session = session
    work.run(
      {
        var configureError: (any Error)?
        var activateError: (any Error)?
        do {
          try session.setCategory(.playback, mode: .spokenAudio, options: [])
        } catch {
          configureError = error
        }
        do {
          try session.setActive(true, options: [])
        } catch {
          activateError = error
        }
        return AudioSessionActivationOutcome(configureError: configureError, activateError: activateError)
      }, then: completion)
  }

  /// `.notifyOthersOnDeactivation` lets whatever audio this session interrupted resume, matching
  /// standard AVAudioSession guidance for a session that is actually done, not merely paused.
  func deactivate(then completion: @escaping @MainActor ((any Error)?) -> Void) {
    let session = session
    work.run(
      { () -> (any Error)? in
        do {
          try session.setActive(false, options: .notifyOthersOnDeactivation)
          return nil
        } catch {
          return error
        }
      }, then: completion)
  }
}
