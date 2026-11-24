import ABSApi
import AVFoundation
import MediaPlayer
import PlayerCore
import SyncEngine

@testable import Whirr

/// `AudioSessionWorkRunning` that holds each piece of session work until the test releases it, so
/// a test can put a pause or a stop inside the window while the handshake is still running.
@MainActor
final class ManualAudioSessionWork: AudioSessionWorkRunning {
  private var pending: [@MainActor () -> Void] = []

  var pendingCount: Int { pending.count }

  func run<Outcome: Sendable>(
    _ work: @escaping @Sendable () -> Outcome, then completion: @escaping @MainActor (Outcome) -> Void
  ) {
    pending.append { completion(work()) }
  }

  /// Runs the oldest held work and delivers its completion.
  func runNext() {
    guard !pending.isEmpty else { return }
    pending.removeFirst()()
  }
}
