import AVFoundation
import MediaPlayer
import Observation
import PlayerCore
import WatchPlayback

/// Watch hardware adapter. Only the current track and its immediate successor enter AVQueuePlayer.
@MainActor
@Observable
final class WatchAudioEngine: NSObject, WatchSessionAudio {
  private(set) var position: Double = 0
  private(set) var duration: Double = 0
  private(set) var playing = false
  private(set) var title = "Nothing playing"
  private(set) var failure: String?
  var onFailure: (@MainActor (Bool) -> Void)?
  /// Media services were reset under a loaded title: its files are intact, but it must load again.
  var onReset: (@MainActor () -> Void)?
  var onEnded: (@MainActor () -> Void)?
  var onRemotePlay: (@MainActor () -> Void)?
  var onRemotePause: (@MainActor () -> Void)?
  /// An absolute move, from the scrubber in Now Playing.
  var onRemoteSeek: (@MainActor (Double) -> Void)?
  /// A relative skip in seconds, from the skip commands; repeated skips add up.
  var onRemoteSkip: (@MainActor (Double) -> Void)?
  /// The audio ran past its declared duration and the timeline grew to this.
  var onDurationGrew: (@MainActor (Double) -> Void)?
  /// What the player did, for the stall policy.
  var onObservation: (@MainActor (WatchStallPolicy.Observation) -> Void)?
  /// An audio-session interruption or route change, for the interruption policy.
  var onInterruption: (@MainActor (WatchInterruptionPolicy.Notification) -> Void)?
  /// Replaced after a media-services reset, which leaves the old player dead.
  private var player = AVQueuePlayer()
  /// The item that was current last, so an emptied queue can tell the end of the title from the
  /// failure of its last item.
  private var lastCurrentItem: AVPlayerItem?
  /// Bumped whenever the queue is torn down, so a status change of an item that has left it is ignored.
  private var queueGeneration = 0
  private var preparation: WatchAudioPreparation?
  private var itemIndices: [ObjectIdentifier: Int] = [:]
  private var timer: Any?
  private var currentObservation: NSKeyValueObservation?
  private var statusObservation: NSKeyValueObservation?
  private var durationObservation: NSKeyValueObservation?
  private var timeControlObservation: NSKeyValueObservation?
  /// The item whose failure was reported: its `.failed` status and its failure to play to the end
  /// are one failure, not two.
  private weak var failedItem: AVPlayerItem?
  private var notifications: [NSObjectProtocol] = []
  private var remoteTargets: [(MPRemoteCommand, Any)] = []
  /// Bumped by a pause or stop: a play waiting for the audio session is superseded by either.
  private var playEpoch = 0
  /// Bumped by a seek, load or stop. A pause does not supersede a seek: the seek lands, paused.
  private var seekEpoch = 0
  private(set) var selectedRate: Double = 1
  /// Asked to play and not yet paused, so a buffering stream reads as loading rather than paused.
  private(set) var wantsPlayback = false
  /// The queue was replaced for a load or a seek that has not landed, so the player's own time is
  /// not the title's position: `position` keeps its last good value, and if the seek failed the
  /// title must be loaded again before it can play from there.
  private(set) var needsReload = false
  private var backwardSkipSeconds = 15
  private var forwardSkipSeconds = 30

  func configureSkipIntervals(backward: Int, forward: Int) {
    backwardSkipSeconds = backward
    forwardSkipSeconds = forward
    let center = MPRemoteCommandCenter.shared()
    center.skipBackwardCommand.preferredIntervals = [NSNumber(value: backward)]
    center.skipForwardCommand.preferredIntervals = [NSNumber(value: forward)]
  }

  var chapters: PlaybackChapterMap { preparation?.chapters ?? .init(chapters: []) }

  var currentChapter: (title: String, start: Double, end: Double)? {
    guard let map = preparation?.chapters, let chapter = map.currentChapter(at: position), chapter.end <= duration
    else { return nil }
    let index = map.chapters.firstIndex(of: chapter) ?? 0
    return ("Chapter \(index + 1)", chapter.start, chapter.end)
  }

  var isPlaying: Bool { player.timeControlStatus == .playing && player.rate > 0 }

  override init() {
    super.init()
    attachPlayerObservers()
    notifications.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance(),
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.mediaServicesWereReset() }
      })
    notifications.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
      ) { [weak self] note in
        guard let notification = Self.interruption(note.userInfo) else { return }
        Task { @MainActor [weak self] in self?.onInterruption?(notification) }
      })
    notifications.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: .main
      ) { [weak self] note in
        let change = Self.routeChange(note.userInfo)
        Task { @MainActor [weak self] in self?.onInterruption?(.routeChanged(change)) }
      })
    notifications.append(
      NotificationCenter.default.addObserver(
        forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
      ) { [weak self] note in
        let item = note.object as? AVPlayerItem
        Task { @MainActor [weak self] in self?.itemFailedToPlayToEnd(item) }
      })
    notifications.append(
      NotificationCenter.default.addObserver(
        forName: AVPlayerItem.playbackStalledNotification, object: nil, queue: .main
      ) { [weak self] note in
        let item = note.object as? AVPlayerItem
        Task { @MainActor [weak self] in
          guard let self, let item, self.player.currentItem === item else { return }
          self.onObservation?(.playbackStalled)
        }
      })
    configureRemoteCommands()
  }

  private func attachPlayerObservers() {
    player.automaticallyWaitsToMinimizeStalling = true
    timer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) {
      [weak self] _ in
      // The observer is delivered on the main queue.
      MainActor.assumeIsolated { self?.sample(publishing: false) }
    }
    currentObservation = player.observe(\.currentItem, options: [.new]) { [weak self] _, change in
      let observedItem = change.newValue ?? nil
      Task { @MainActor [weak self] in self?.currentItemChanged(expectedItem: observedItem) }
    }
    // Now Playing follows the player's own state, not only the one-second sample.
    timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.timeControlChanged() }
    }
  }

  /// The player object is dead after a reset: replace it, empty the queue and mark the title to be
  /// loaded again. The controller then takes the same path as any audio failure, so a title that
  /// was playing says so and the next play starts it afresh.
  private func mediaServicesWereReset() {
    if let timer { player.removeTimeObserver(timer) }
    timer = nil
    currentObservation = nil
    timeControlObservation = nil
    statusObservation = nil
    durationObservation = nil
    playEpoch &+= 1
    seekEpoch &+= 1
    player = AVQueuePlayer()
    attachPlayerObservers()
    emptyQueue()
    failedItem = nil
    // With nothing loaded there is nothing to report; the next load uses the new player.
    guard preparation != nil else { return }
    wantsPlayback = false
    playing = false
    needsReload = true
    updateNowPlaying()
    onReset?()
  }

  isolated deinit {
    if let timer { player.removeTimeObserver(timer) }
    for token in notifications { NotificationCenter.default.removeObserver(token) }
    for (command, token) in remoteTargets { command.removeTarget(token) }
  }

  func load(_ preparation: WatchAudioPreparation, position: Double) async throws {
    stop()
    self.preparation = preparation
    title = preparation.title ?? "Audiobookshelf"
    duration = preparation.timeline.totalDuration
    // A load that fails leaves the position it was asked for, not the start of the title.
    self.position = min(max(position, 0), duration)
    needsReload = true
    failure = nil
    try await seek(to: position)
  }

  func play() async throws {
    guard preparation != nil, player.currentItem != nil else { throw WatchAudioEngineError.unplayable }
    let token = playEpoch
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
    } catch {
      throw WatchAudioEngineError.noOutput
    }
    let activated = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      session.activate(options: []) { success, _ in continuation.resume(returning: success) }
    }
    guard token == playEpoch else { throw CancellationError() }
    guard activated else { throw WatchAudioEngineError.noOutput }
    wantsPlayback = true
    player.playImmediately(atRate: Float(selectedRate))
    sample()
  }

  func pause() {
    playEpoch &+= 1
    wantsPlayback = false
    player.pause()
    sample()
  }

  func seek(to seconds: Double) async throws {
    guard seconds.isFinite, let preparation else { throw WatchAudioEngineError.unplayable }
    seekEpoch &+= 1
    let token = seekEpoch
    let mapping = preparation.timeline.trackAndLocalOffset(atGlobalOffset: seconds)
    let currentIndex = player.currentItem.flatMap { itemIndices[ObjectIdentifier($0)] }
    var rebuilt = false
    if currentIndex != mapping.track.index {
      // The target track is checked before the queue is torn down.
      guard let offset = preparation.tracks.firstIndex(where: { $0.index == mapping.track.index }) else {
        throw WatchAudioEngineError.unplayable
      }
      player.pause()
      emptyQueue()
      rebuilt = true
      needsReload = true
      for track in preparation.tracks.dropFirst(offset).prefix(2) {
        let item = makeItem(track)
        player.insert(item, after: nil)
      }
    }
    do {
      guard let item = player.currentItem else { throw WatchAudioEngineError.unplayable }
      let playable = try await item.asset.load(.isPlayable)
      // A newer seek, load or stop bumped the epoch: this seek was superseded, not failed.
      guard token == seekEpoch else { throw CancellationError() }
      guard playable else { throw WatchAudioEngineError.unplayable }
      let finished = await player.seek(
        to: CMTime(seconds: mapping.localOffset, preferredTimescale: 600), toleranceBefore: .zero,
        toleranceAfter: .zero)
      guard token == seekEpoch else { throw CancellationError() }
      // Nothing of ours superseded it, so the player gave up on the target.
      guard finished else { throw WatchAudioEngineError.seekUnfinished }
    } catch {
      // A failed seek that already replaced the queue leaves nothing to play, so it must not
      // read as loading. A superseded seek leaves that to whatever superseded it.
      if rebuilt, !(error is CancellationError) {
        // No half-built queue: the title is loaded again before it can play.
        emptyQueue()
        needsReload = true
        wantsPlayback = false
        sample()
      }
      throw error
    }
    position = min(max(seconds, 0), duration)
    needsReload = false
    if wantsPlayback { player.playImmediately(atRate: Float(selectedRate)) }
    currentItemChanged()
    updateNowPlaying()
  }

  func setRate(_ rate: Double) {
    guard rate.isFinite, (0.25...4).contains(rate) else { return }
    selectedRate = rate
    // Setting a rate starts the player; a seek that has not landed applies the rate when it does.
    if wantsPlayback, !needsReload { player.rate = Float(rate) }
    sample()
  }

  func stop() {
    playEpoch &+= 1
    seekEpoch &+= 1
    wantsPlayback = false
    player.pause()
    statusObservation = nil
    durationObservation = nil
    emptyQueue()
    preparation = nil
    needsReload = false
    position = 0
    duration = 0
    playing = false
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  /// Grows the loaded timeline when the engine reports audio running past its declared duration
  /// (ARCHITECTURE.md §8 D42). Happens with an ABS podcast episode whose manifest duration predates
  /// an injected advert. The Watch has its own adapter rather than `PlayerReducer`, so it applies
  /// the shared rule itself. Growing `duration` frees every surface that clamps against it: the
  /// two skip commands, the scrubber's range, and Now Playing.
  private func applyObservedExtent(_ localExtent: Double) {
    guard let preparation, let grown = preparation.timeline.grown(toObservedLocalExtent: localExtent)
    else { return }
    self.preparation = preparation.replacingTimeline(grown)
    duration = grown.totalDuration
    updateNowPlaying()
    onDurationGrew?(duration)
  }

  private func emptyQueue() {
    queueGeneration &+= 1
    player.removeAllItems()
    itemIndices.removeAll()
    lastCurrentItem = nil
  }

  private func makeItem(_ track: WatchAudioTrack) -> AVPlayerItem {
    let asset = AVURLAsset(
      url: track.url, options: track.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": track.headers])
    let item = AVPlayerItem(asset: asset)
    itemIndices[ObjectIdentifier(item)] = track.index
    return item
  }

  private func currentItemChanged(expectedItem: AVPlayerItem? = nil) {
    if let expectedItem, player.currentItem !== expectedItem { return }
    statusObservation = nil
    durationObservation = nil
    guard let item = player.currentItem, let preparation,
      let index = itemIndices[ObjectIdentifier(item)]
    else {
      if wantsPlayback {
        // A failed item can leave the queue empty: that is a failure, not the end of the title.
        if let last = lastCurrentItem, last.status == .failed {
          reportFailure(of: last)
          return
        }
        wantsPlayback = false
        playing = false
        position = duration
        onEnded?()
      }
      return
    }
    lastCurrentItem = item
    let liveIDs = Set(player.items().map(ObjectIdentifier.init))
    itemIndices = itemIndices.filter { liveIDs.contains($0.key) }
    if player.items().count < 2,
      let offset = preparation.tracks.firstIndex(where: { $0.index == index }), offset + 1 < preparation.tracks.count
    {
      player.insert(makeItem(preparation.tracks[offset + 1]), after: item)
    }
    // Separate from `\.status`: a progressively loaded stream reaches `readyToPlay` with an
    // indefinite duration and resolves it later, so the ready transition alone would miss it.
    durationObservation = item.observe(\.duration, options: [.initial, .new]) { [weak self] observed, _ in
      let duration = observed.duration
      guard duration.isValid, duration.isIndefinite == false else { return }
      let seconds = CMTimeGetSeconds(duration)
      Task { @MainActor [weak self] in
        guard let self, self.player.currentItem === observed else { return }
        self.applyObservedExtent(seconds)
      }
    }
    let generation = queueGeneration
    statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
      guard observed.status == .failed else { return }
      Task { @MainActor [weak self] in
        // The queue may already have moved past a failed item; that must not hide the failure.
        guard let self, self.queueGeneration == generation else { return }
        self.reportFailure(of: observed)
      }
    }
    sample()
  }

  private func timeControlChanged() {
    sample()
    let observation: WatchStallPolicy.Observation =
      switch player.timeControlStatus {
      case .playing: .playing
      case .waitingToPlayAtSpecifiedRate: .waiting
      case .paused: .paused
      @unknown default: .waiting
      }
    onObservation?(observation)
  }

  private static func isUnauthorized(_ item: AVPlayerItem) -> Bool {
    item.errorLog()?.events.contains { [401, 403].contains($0.errorStatusCode) } == true
  }

  private func reportFailure(of item: AVPlayerItem) {
    guard failedItem !== item else { return }
    failedItem = item
    let unauthorized = Self.isUnauthorized(item)
    pause()
    failure = unauthorized ? "Sign in again to continue" : "Audio unavailable. Try again."
    onFailure?(unauthorized)
  }

  /// A failure with a known cause is reported as one: a refused stream can renew and a download
  /// says it is the download. Only an unexplained stream failure is the stall policy's to judge.
  /// The item is not marked failed on that path, so a `.failed` status that follows is still heard.
  private func itemFailedToPlayToEnd(_ item: AVPlayerItem?) {
    guard let item, player.currentItem === item || lastCurrentItem === item, failedItem !== item else { return }
    let isFile = (item.asset as? AVURLAsset)?.url.isFileURL == true
    if isFile || item.status == .failed || Self.isUnauthorized(item) {
      reportFailure(of: item)
      return
    }
    onObservation?(.failedToPlayToEnd)
  }

  private nonisolated static func interruption(_ info: [AnyHashable: Any]?) -> WatchInterruptionPolicy.Notification? {
    guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return nil }
    switch type {
    case .began: return .interruptionBegan
    case .ended:
      let options = (info?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
      return .interruptionEnded(shouldResume: options?.contains(.shouldResume) == true)
    @unknown default: return nil
    }
  }

  private nonisolated static func routeChange(_ info: [AnyHashable: Any]?) -> WatchInterruptionPolicy.RouteChange {
    let reason = (info?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
    return switch reason {
    case .oldDeviceUnavailable: .oldDeviceUnavailable
    case .newDeviceAvailable: .newDeviceAvailable
    case .categoryChange: .categoryChange
    default: .other
    }
  }

  /// Reads the player's position and state. The once-a-second sample passes `publishing: false`:
  /// the system advances Now Playing's elapsed time from the rate itself, so it is republished
  /// only when the state changes, and an unchanged `playing` is not written, so nothing observing
  /// it redraws.
  private func sample(publishing: Bool = true) {
    if let item = player.currentItem, let index = itemIndices[ObjectIdentifier(item)] {
      let local = item.currentTime().seconds
      // Runs before the timeline can clamp the offset away and before `preparation` is read: an
      // offset past the declared duration means the audio is longer than the manifest claimed.
      applyObservedExtent(local)
      if !needsReload, let preparation, local.isFinite,
        let global = preparation.timeline.globalOffset(forTrackIndex: index, localOffset: local)
      {
        position = global
      }
    }
    let nowPlaying = isPlaying
    let changed = playing != nowPlaying
    if changed { playing = nowPlaying }
    if publishing || changed { updateNowPlaying() }
  }

  private func updateNowPlaying() {
    guard preparation != nil else { return }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyPlaybackDuration: duration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? selectedRate : 0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: selectedRate,
    ]
  }

  private func configureRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()
    func register(_ command: MPRemoteCommand, action: @escaping @MainActor () -> Void) {
      let target = command.addTarget { _ in
        Task { @MainActor in action() }
        return .success
      }
      remoteTargets.append((command, target))
    }
    register(center.playCommand) { [weak self] in self?.onRemotePlay?() }
    register(center.pauseCommand) { [weak self] in self?.onRemotePause?() }
    register(center.togglePlayPauseCommand) { [weak self] in
      guard let self else { return }
      if self.wantsPlayback { self.onRemotePause?() } else { self.onRemotePlay?() }
    }
    configureSkipIntervals(backward: backwardSkipSeconds, forward: forwardSkipSeconds)
    register(center.skipBackwardCommand) { [weak self] in
      guard let self else { return }
      self.onRemoteSkip?(-Double(self.backwardSkipSeconds))
    }
    register(center.skipForwardCommand) { [weak self] in
      guard let self else { return }
      self.onRemoteSkip?(Double(self.forwardSkipSeconds))
    }
    let target = center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      let position = event.positionTime
      Task { @MainActor [weak self] in self?.onRemoteSeek?(position) }
      return .success
    }
    remoteTargets.append((center.changePlaybackPositionCommand, target))
  }
}
