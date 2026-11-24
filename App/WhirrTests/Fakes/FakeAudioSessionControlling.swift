import ABSApi
import AVFoundation
import MediaPlayer
import PlayerCore
import SyncEngine
import TestSupport

@testable import Whirr

/// Test double for `AudioSessionControlling`. Never touches the real shared `AVAudioSession`.
/// Locked because production calls the protocol off the main actor, and one test does too.
nonisolated final class FakeAudioSessionControlling: AudioSessionControlling, @unchecked Sendable {
  struct Refusal: Error {}

  typealias CategoryCall = (
    category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions
  )
  typealias ActiveCall = (active: Bool, options: AVAudioSession.SetActiveOptions)

  private let lock = NSLock()
  private var categoryCalls: [CategoryCall] = []
  private var activeCalls: [ActiveCall] = []
  private var throwing = false
  private var mainThreadCalls = 0

  var setCategoryCalls: [CategoryCall] { lock.withLock { categoryCalls } }
  var setActiveCalls: [ActiveCall] { lock.withLock { activeCalls } }
  /// How many calls arrived on the main thread.
  var mainThreadCallCount: Int { lock.withLock { mainThreadCalls } }
  var shouldThrow: Bool {
    get { lock.withLock { throwing } }
    set { lock.withLock { throwing = newValue } }
  }

  func setCategory(
    _ category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions
  ) throws {
    try lock.withLock {
      if Thread.isMainThread { mainThreadCalls += 1 }
      if throwing { throw Refusal() }
      categoryCalls.append((category, mode, options))
    }
  }

  func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
    try lock.withLock {
      if Thread.isMainThread { mainThreadCalls += 1 }
      if throwing { throw Refusal() }
      activeCalls.append((active, options))
    }
  }
}
