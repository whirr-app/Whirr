import ABSApi
import AVFoundation
import MediaPlayer
import PlayerCore
import SyncEngine

@testable import Whirr

/// Test double for `AudioQueuePlayerControlling`: an in-memory stand-in for `AVQueuePlayer` that
/// records every command and lets tests simulate an item auto-advancing off the front of the
/// queue, as a real `AVQueuePlayer` does once an item plays to its end.
@MainActor
final class FakeQueuePlayer: AudioQueuePlayerControlling {
  /// Mirrors real `AVPlayer`, where `rate` is the play/pause state: a new player is paused
  /// (`rate == 0`), and assigning any non-zero `rate`, even just to change speed, starts playback.
  var rate: Float = 0
  var volume: Float = 1
  var onBufferingStateChanged: (@MainActor @Sendable (Bool) -> Void)?

  private var storedItems: [AudioPlayerItemHandle] = []
  private(set) var insertCalls: [(item: AudioPlayerItemHandle, after: AudioPlayerItemHandle?)] = []
  private(set) var removeAllCallCount = 0
  private(set) var playCallCount = 0
  private(set) var pauseCallCount = 0
  private(set) var addObserverCallCount = 0
  private(set) var removeObserverCallCount = 0
  /// Every interval the adapter has asked to observe at, in order. The count alone cannot show a
  /// cadence change, which re-installs the same observer at a different rate.
  private(set) var observedIntervals: [CMTime] = []
  private var observerBlock: (@MainActor @Sendable (CMTime) -> Void)?
  /// The boundary currently armed, if any: its times, block and token.
  private(set) var boundary: (times: [CMTime], block: @MainActor @Sendable (CMTime) -> Void, token: NSObject)?
  private(set) var addBoundaryCallCount = 0
  private(set) var removeBoundaryCallCount = 0

  func items() -> [AudioPlayerItemHandle] { storedItems }

  func insert(_ item: AudioPlayerItemHandle, after afterItem: AudioPlayerItemHandle?) {
    insertCalls.append((item, afterItem))
    if let afterItem, let index = storedItems.firstIndex(where: { $0 === afterItem }) {
      storedItems.insert(item, at: index + 1)
    } else {
      storedItems.append(item)
    }
  }

  func remove(_ item: AudioPlayerItemHandle) {
    storedItems.removeAll { $0 === item }
  }

  func removeAllItems() {
    removeAllCallCount += 1
    storedItems.removeAll()
  }

  /// Mirrors real `AVPlayer.play()`: play sets `rate` to the player's `defaultRate` (1.0 unless
  /// configured), silently discarding any faster or slower rate set earlier. The engine's `play()`
  /// must compensate for that reset, or speed reverts to 1× on every resume.
  func play() {
    playCallCount += 1
    rate = 1.0
  }

  /// Mirrors real `AVPlayer.pause()`, which is equivalent to setting `rate` to 0.
  func pause() {
    pauseCallCount += 1
    rate = 0
  }

  func addPeriodicTimeObserver(
    forInterval interval: CMTime, using block: @escaping @MainActor @Sendable (CMTime) -> Void
  ) -> Any {
    addObserverCallCount += 1
    observedIntervals.append(interval)
    observerBlock = block
    return NSObject()
  }

  func addBoundaryTimeObserver(
    forTimes times: [CMTime], using block: @escaping @MainActor @Sendable (CMTime) -> Void
  ) -> Any {
    addBoundaryCallCount += 1
    let token = NSObject()
    boundary = (times, block, token)
    return token
  }

  /// `AVPlayer` removes either kind of observer through this one call; a boundary token is told
  /// apart so the periodic counts keep meaning what they did.
  func removeTimeObserver(_ observer: Any) {
    if let boundary, (observer as AnyObject) === boundary.token {
      removeBoundaryCallCount += 1
      self.boundary = nil
      return
    }
    removeObserverCallCount += 1
  }

  /// Simulates playback crossing the armed boundary, with the player then at `time`.
  func simulateBoundaryCrossing(at time: CMTime) {
    boundary?.block(time)
  }

  /// Simulates a real `AVQueuePlayer` dropping the front item once it finishes, advancing to
  /// whatever was enqueued next.
  func simulateAutoAdvance() {
    guard !storedItems.isEmpty else { return }
    storedItems.removeFirst()
  }

  func simulatePeriodicTime(_ time: CMTime) {
    observerBlock?(time)
  }

  func simulateBuffering(_ isBuffering: Bool) {
    onBufferingStateChanged?(isBuffering)
  }
}
