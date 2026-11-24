import Foundation
import Observation
import WatchPlayback
import WatchProtocol

@MainActor @Observable final class WatchAudioEngine: WatchSessionAudio {
  var position: Double = 0
  var duration: Double = 0
  var isPlaying = false
  var backwardSkipSeconds = 15
  var forwardSkipSeconds = 30
  func configureSkipIntervals(backward: Int, forward: Int) {
    backwardSkipSeconds = backward
    forwardSkipSeconds = forward
  }
  var onFailure: (@MainActor (Bool) -> Void)?
  var onReset: (@MainActor () -> Void)?
  var onEnded: (@MainActor () -> Void)?
  var onRemotePlay: (@MainActor () -> Void)?
  var onRemotePause: (@MainActor () -> Void)?
  var onRemoteSeek: (@MainActor (Double) -> Void)?
  var onRemoteSkip: (@MainActor (Double) -> Void)?
  var onDurationGrew: (@MainActor (Double) -> Void)?
  /// What the player did; a regression calls it as the engine would.
  var onObservation: (@MainActor (WatchStallPolicy.Observation) -> Void)?
  /// An audio-session interruption or route change; a regression calls it as the engine would.
  var onInterruption: (@MainActor (WatchInterruptionPolicy.Notification) -> Void)?
  private(set) var wantsPlayback = false
  /// Set to say a failed seek replaced the queue, as the engine does (A5).
  var needsReload = false
  func load(_ preparation: WatchAudioPreparation, position: Double) async throws {
    self.position = position
    duration = preparation.timeline.totalDuration
  }
  /// Set to make the next plays fail, as a refused audio session or route does.
  var playFailure: (any Error)?
  /// Set to hold each play until `releasePlays()`, so a regression can act while one is in flight.
  var holdPlays = false
  private(set) var heldPlays: [CheckedContinuation<Void, Never>] = []
  func releasePlays() {
    holdPlays = false
    let held = heldPlays
    heldPlays = []
    for play in held { play.resume() }
  }
  func play() async throws {
    if holdPlays { await withCheckedContinuation { heldPlays.append($0) } }
    if let playFailure { throw playFailure }
    isPlaying = true
    wantsPlayback = true
  }
  func pause() {
    isPlaying = false
    wantsPlayback = false
  }
  /// Set to make the next seeks fail, as a superseded or unfinished seek does.
  var seekFailure: (any Error)?
  /// Set to hold each seek until `releaseSeeks()`, so a regression can act while one is in flight.
  var holdSeeks = false
  private(set) var heldSeeks: [CheckedContinuation<Void, Never>] = []
  func releaseSeeks() {
    holdSeeks = false
    let held = heldSeeks
    heldSeeks = []
    for seek in held { seek.resume() }
  }
  func seek(to position: Double) async throws {
    if holdSeeks { await withCheckedContinuation { heldSeeks.append($0) } }
    if let seekFailure { throw seekFailure }
    self.position = position
  }
  private(set) var selectedRate: Double = 1
  func setRate(_ rate: Double) { selectedRate = rate }
  func stop() {
    isPlaying = false
    wantsPlayback = false
  }
}
@MainActor @Observable final class WatchCompanionStore {
  var snapshot: WatchCatalogueSnapshot?
  /// The phone reports playing `currentItem`; set directly by a regression.
  var phoneReportsPlaying = false
  var currentItem: WatchCatalogueItem?
  var phoneCanBeReached = true
  enum Outcome { case sent, phoneUnavailable, rejected }
  var outcome = Outcome.phoneUnavailable
  private(set) var sent: [(selection: WatchSelection, action: WatchCommandAction, value: Double?)] = []
  private(set) var cacheClears = 0
  func clearCache() { cacheClears += 1 }
  func send(selection: WatchSelection, action: WatchCommandAction, value: Double? = nil) async -> Outcome {
    sent.append((selection, action, value))
    return outcome
  }
}
@MainActor enum WatchPeerMessageSender {
  static var handler: ((Data, String) async -> Data?)?
  /// The wait each send asked for; a fire-and-forget request leaves the default.
  static var timeouts: [Duration] = []
  static func send(
    _ data: Data, key: String = WatchHandoffRequest.transportKey,
    replyLimit: Int = WatchHandoffLimits.maxWireBytes, timeout wait: Duration = .seconds(8)
  ) async -> Data? {
    timeouts.append(wait)
    return await handler?(data, key)
  }
}

/// A protected store under a fresh temporary root, so no host program writes to the Mac's
/// Application Support.
func hostProtectedStore() -> WatchProtectedFileStore {
  WatchProtectedFileStore(
    rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(
      "watch-host-protected-\(UUID().uuidString)", isDirectory: true))
}
