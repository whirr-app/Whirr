import ABSApi
import AVFoundation
import MediaPlayer
import PlayerCore
import SyncEngine

@testable import Whirr

/// Test double for `AudioPlayerItemHandle`. No real `AVPlayerItem` or KVO: tests drive
/// readiness, failure and end-of-track by calling `simulate*` directly.
@MainActor
final class FakePlayerItemHandle: AudioPlayerItemHandle {
  let resource: PlaybackTrackResource
  var trackIndex: Int { resource.trackIndex }
  var url: URL { resource.url }
  let trim: PlayerTrimMap?
  /// The composition the engine built this item from, `nil` for a plain item.
  let preparedAsset: AVAsset?
  private(set) var isUnusable = false

  var isReady = false
  var duration: CMTime?
  var timePitchAlgorithm: AVAudioTimePitchAlgorithm = .spectral
  /// Starts at `0`, AVFoundation's "choose the window yourself" default, so a test can tell an
  /// item the adapter left alone from one it configured.
  var preferredForwardBufferDuration: TimeInterval = 0

  var onReady: (@MainActor @Sendable () -> Void)?
  var onFailed: (@MainActor @Sendable (Error, Int) -> Void)?
  var onFailedToPlayToEnd: (@MainActor @Sendable (Error, Int) -> Void)?
  var onDidPlayToEnd: (@MainActor @Sendable () -> Void)?
  var onDurationChanged: (@MainActor @Sendable (Double) -> Void)?

  /// A recorded seek, including the tolerances that decide whether it lands sample-accurately.
  struct SeekRequest: Equatable {
    let offset: Double
    let toleranceBefore: CMTime
    let toleranceAfter: CMTime
  }

  private(set) var seekRequests: [SeekRequest] = []
  /// Offsets only, for tests that care about the landing position and nothing else.
  var seekCalls: [Double] { seekRequests.map(\.offset) }

  init(resource: PlaybackTrackResource, preparedAsset: AVAsset? = nil, trim: PlayerTrimMap? = nil) {
    self.resource = resource
    self.preparedAsset = preparedAsset
    self.trim = trim
  }

  /// Whether a seek's completion is held rather than run inline. A real seek resolves after the
  /// fact, and the window before it resolves is what the adapter's positioning guard protects, so
  /// a test of that window must hold the completion open.
  var deferSeekCompletions = false
  private var pendingSeekCompletions: [@MainActor @Sendable (Bool) -> Void] = []

  func seek(
    to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
    completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    seekRequests.append(
      SeekRequest(offset: time.seconds, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter))
    guard deferSeekCompletions else {
      completion(true)
      return
    }
    pendingSeekCompletions.append(completion)
  }

  /// Resolves every held seek, in the order it was requested.
  func completePendingSeeks(finished: Bool = true) {
    let completions = pendingSeekCompletions
    pendingSeekCompletions = []
    for completion in completions { completion(finished) }
  }

  func simulateReady(duration: Double? = nil) {
    if let duration {
      self.duration = CMTime(seconds: duration, preferredTimescale: 600)
    }
    isReady = true
    onReady?()
  }

  /// Mirrors the real handle's `\.duration` KVO: sets the value and notifies, as a progressively
  /// loaded stream does when it revises a duration it had already reported.
  func simulateDurationChanged(_ seconds: Double) {
    duration = CMTime(seconds: seconds, preferredTimescale: 600)
    onDurationChanged?(seconds)
  }

  /// `responseStatusCode` mirrors what the real handle reads from the item's error log. `0` means
  /// the log recorded no HTTP status, which is the case for every existing caller.
  func simulateFailed(_ error: Error, responseStatusCode: Int = 0) {
    isUnusable = true
    onFailed?(error, responseStatusCode)
  }

  func simulateFailedToPlayToEnd(_ error: Error? = nil, responseStatusCode: Int = 0) {
    isUnusable = true
    onFailedToPlayToEnd?(
      error ?? AudioEngineAdapterError.unknownPlaybackFailure, responseStatusCode)
  }

  func simulateDidPlayToEnd() {
    onDidPlayToEnd?()
  }

  /// Every processor the engine asked this item to attach, in order, including repeats.
  private(set) var attachCalls: [VoiceBoostTapFactory] = []
  /// The processor whose attach landed, mirroring the real handle setting the item's audio mix.
  private(set) var attachedProcessor: VoiceBoostTapFactory?
  private(set) var cancelAttachCallCount = 0
  /// Holds an attach pending, as the real handle's track load does, until `completePendingAttach`.
  var holdsAttach = false
  private var pendingProcessor: VoiceBoostTapFactory?
  private var isAttachCancelled = false

  func attachAudioProcessor(_ processor: VoiceBoostTapFactory) {
    attachCalls.append(processor)
    guard attachedProcessor == nil, pendingProcessor == nil, !isAttachCancelled, !isUnusable else { return }
    if holdsAttach {
      pendingProcessor = processor
    } else {
      attachedProcessor = processor
    }
  }

  func cancelAudioProcessorAttach() {
    cancelAttachCallCount += 1
    isAttachCancelled = true
  }

  /// Lands a held attach, unless the item was cancelled or failed while it was pending.
  func completePendingAttach() {
    guard let processor = pendingProcessor else { return }
    pendingProcessor = nil
    guard !isAttachCancelled, !isUnusable else { return }
    attachedProcessor = processor
  }
}
