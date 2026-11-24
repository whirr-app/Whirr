import AVFoundation
import CoreSupport
import PlayerCore

/// One resolvable stream resource for a track in the loaded item. Only resources from a
/// successfully created playback session may play (ARCHITECTURE.md); `PlaybackTrack` carries no
/// URL, so the composer supplies resolved URLs here before any `PlayerIntent` triggers a `load`.
///
/// `nonisolated` so the target's MainActor default doesn't isolate it: it is built off the main
/// actor, then hops to `configure(tracks:)`.
nonisolated struct PlaybackTrackResource: Sendable, Equatable {
  let trackIndex: Int
  let url: URL
  /// The already-stamped headers the resource must be fetched with: a streamed track's Bearer
  /// header, empty for a local file URL. Supplied by the caller that owns credentialed access;
  /// this adapter never mints or inspects one.
  let headers: [String: String]
  /// The catalog/response MIME type for this exact resource. Local downloads need this supplied
  /// explicitly to AVFoundation because historical `audio/mpeg` files used a `.mpeg` suffix that
  /// iOS otherwise misclassifies as a video/program stream.
  let mimeType: String?

  init(trackIndex: Int, url: URL, headers: [String: String] = [:], mimeType: String? = nil) {
    self.trackIndex = trackIndex
    self.url = url
    self.headers = headers
    self.mimeType = mimeType
  }
}

/// `@MainActor` `AudioEngine` adapter over `AVQueuePlayer` (whose types are main-actor isolated).
/// Owns no session, cadence, sleep or conflict policy; those stay in `PlayerCore`/`SyncEngine`.
///
/// Enqueues the current track plus one lookahead so the queue advances the instant a track ends,
/// without waiting on the `trackFinished` -> `PlayerReducer` -> `load` round trip. That round trip
/// still happens, and `load` reuses the current item when it is already the requested track rather
/// than tearing down live audio.
@MainActor
final class AVQueuePlayerAudioEngine: AudioEngine {
  let events: AsyncStream<AudioEngineEvent>
  private let continuation: AsyncStream<AudioEngineEvent>.Continuation

  /// How often the periodic time observer fires. Foreground keeps 2 Hz so a scrubber drag feels
  /// attached; in the background each tick is a main-thread wakeup that keeps the CPU out of idle,
  /// and nothing needs the rate (progress persists on a 15 s batch, `/sync` has its own cadence,
  /// `listenedDelta` uses wall-clock checkpoints).
  ///
  /// The sleep timer advances on these ticks (`PlayerReducer.applySleepTimerTick`), so it can
  /// expire up to `backgroundPositionInterval` late; it counts listening time because ticks stop
  /// with playback.
  enum PositionCadence: Sendable {
    case foreground
    case background
  }

  nonisolated static let foregroundPositionInterval = CMTime(
    seconds: 0.5, preferredTimescale: 600)
  nonisolated static let backgroundPositionInterval = CMTime(seconds: 2, preferredTimescale: 600)

  /// How far ahead a streamed item buffers. AVFoundation's default window keeps re-issuing
  /// byte-range requests, so the radio never reaches low power; five minutes (a few MB of speech)
  /// turns that into infrequent bursts, at the cost of re-fetching after a seek.
  static let streamingForwardBufferDuration: TimeInterval = 300

  private let queuePlayer: AudioQueuePlayerControlling
  private let itemFactory: AudioPlayerItemFactory
  private let session: AudioSessionConfigurator
  /// Makes each item's Voice Boost tap and carries the switch every tap follows.
  private let voiceBoost: VoiceBoostTapFactory
  private var isVoiceBoostEnabled = false
  private let foregroundPositionInterval: CMTime
  private let backgroundPositionInterval: CMTime

  /// Populated by `configure(tracks:)`: the resolved URL and track ordering for the loaded item.
  /// Replaced wholesale on every call.
  private var resourcesByIndex: [Int: PlaybackTrackResource] = [:]
  private var orderedTrackIndices: [Int] = []

  /// Outcome of the explicit handshake for the current load generation. Queue playback may
  /// still activate implicitly after refusal, so this is neither an audibility signal nor a
  /// reason to automatically start another device. Platform command adapters must not call a
  /// refused handshake confirmed playback.
  nonisolated struct SessionActivationResult: Sendable, Equatable {
    let generation: Int
    let configurationSucceeded: Bool
    let activationSucceeded: Bool
  }

  private(set) var lastSessionActivation: SessionActivationResult?

  private var currentGeneration = 0
  private var currentItem: AudioPlayerItemHandle?
  private var lookaheadItem: AudioPlayerItemHandle?
  /// Compositions handed over by `configureTrimmed`, until `stop()`.
  private let preparedTrims = PreparedTrimAssets()
  /// Owns the periodic and boundary observers. Lazy because its context closures capture `self`,
  /// which is not available until `init` has finished.
  private lazy var positionObserver = EnginePositionObserver(
    queuePlayer: queuePlayer,
    foregroundPositionInterval: foregroundPositionInterval,
    backgroundPositionInterval: backgroundPositionInterval,
    context: EnginePositionObserver.Context(
      isPlaybackRequested: { [weak self] in self?.isPlaybackRequested ?? false },
      hasCurrentItem: { [weak self] in self?.currentItem != nil },
      pendingPositioningGeneration: { [weak self] in self?.pendingPositioningGeneration },
      currentGeneration: { [weak self] in self?.currentGeneration ?? 0 },
      trim: { [weak self] in self?.currentItem?.trim },
      emit: { [weak self] event in self?.emit(event) }
    ))
  /// The cadence the currently installed observer runs at.
  var positionCadence: PositionCadence { positionObserver.cadence }
  /// The transport intent most recently sent to AVPlayer. Periodic observers are also invoked
  /// when playback starts, stops, or jumps, and callbacks already enqueued at pause can otherwise
  /// keep advancing the UI after the queue has stopped.
  private var isPlaybackRequested = false
  /// The last buffering signal actually surfaced as an event, used to collapse the repeated
  /// identical `timeControlStatus` notifications a real player emits (`handleBufferingChanged`).
  /// `nil` until the first signal after a load, so that first real state always surfaces.
  private var lastBufferingState: Bool?
  /// The generation whose load-time seek is issued but unconfirmed. A fresh item's clock reads zero
  /// until it lands, so no position is worth reporting yet; `PlayerReducer` refuses such a tick
  /// too, but only this side knows when the wait ends.
  private var pendingPositioningGeneration: Int?
  /// The rate most recently requested via `load`/`setRate`. Reasserted after every `play()`,
  /// because `AVPlayer.play()` equals setting `rate` to `defaultRate` (1.0), discarding the rate
  /// in effect before a pause.
  private var currentRate = 1.0
  /// Counts play, pause and stop commands, so a play whose session handshake is still running can
  /// tell whether it has been superseded by the time the handshake returns.
  private var transportRequest = 0

  init(
    queuePlayer: AudioQueuePlayerControlling,
    itemFactory: AudioPlayerItemFactory,
    session: AudioSessionConfigurator,
    voiceBoost: VoiceBoostTapFactory = VoiceBoostTapFactory(),
    foregroundPositionInterval: CMTime = AVQueuePlayerAudioEngine.foregroundPositionInterval,
    backgroundPositionInterval: CMTime = AVQueuePlayerAudioEngine.backgroundPositionInterval
  ) {
    self.queuePlayer = queuePlayer
    self.itemFactory = itemFactory
    self.session = session
    self.voiceBoost = voiceBoost
    self.foregroundPositionInterval = foregroundPositionInterval
    self.backgroundPositionInterval = backgroundPositionInterval

    var continuation: AsyncStream<AudioEngineEvent>.Continuation!
    events = AsyncStream { continuation = $0 }
    self.continuation = continuation

    self.queuePlayer.onBufferingStateChanged = { [weak self] isBuffering in
      self?.handleBufferingChanged(isBuffering)
    }
  }

  /// Production convenience: real `AVQueuePlayer`/`AVPlayerItem`/`AVAudioSession` underneath.
  convenience init() {
    self.init(
      queuePlayer: RealAudioQueuePlayer(),
      itemFactory: AVFoundationPlayerItemFactory(),
      session: AudioSessionConfigurator(
        session: RealAudioSessionControlling(), work: BackgroundAudioSessionWork())
    )
  }

  /// Supplies the resolved stream URL for every track of the item about to be loaded. Not part of
  /// `AudioEngine` (`PlayerCore` never sees a URL), so the caller that owns credentialed access
  /// to `PreparedPlayback` calls this before the matching `load`/`PlayerIntent.load`.
  func configure(tracks: [PlaybackTrackResource]) {
    let newResourcesByIndex = Dictionary(uniqueKeysWithValues: tracks.map { ($0.trackIndex, $0) })
    // The lookahead is physically queued, so a changed resource must be removed from the queue;
    // merely clearing this reference would leave the stale item to play at the next boundary.
    if let lookaheadItem {
      let expectedResource = newResourcesByIndex[lookaheadItem.trackIndex]
      if expectedResource != lookaheadItem.resource || lookaheadItem.isUnusable {
        discardLookaheadItem()
      }
    }
    resourcesByIndex = newResourcesByIndex
    orderedTrackIndices = tracks.map(\.trackIndex).sorted()
  }

  /// Hands over the composition `CompositionTrimPreparer` built for `fileURL` and `map`. A later
  /// `load` given that map plays it; the latest map per file wins.
  func configureTrimmed(fileURL: URL, map: PlayerTrimMap, asset: AVAsset) {
    preparedTrims.store(fileURL: fileURL, map: map, asset: asset)
  }

  // MARK: - AudioEngine

  func load(
    track: PlaybackTrack, localOffset: Double, rate: Double, generation: Int, trim: PlayerTrimMap? = nil
  ) {
    positionObserver.removeBoundaryObserver()
    lastSessionActivation = nil
    currentRate = rate
    // A fresh item's buffering state is unknown; clear the dedup so the first signal surfaces.
    lastBufferingState = nil
    guard let resource = resourcesByIndex[track.index] else {
      currentGeneration = generation
      emit(
        .failed(
          generation: generation,
          AudioEngineFailure(isRecoverable: false, message: "No stream URL configured for track \(track.index)")))
      return
    }

    // Reuse matches the whole resource, not index or index+URL. Every book has a track 0, so index
    // alone reuses the previous book's item; a renewed authorization keeps the URL but changes
    // headers, so index+URL re-adopts the asset that just answered 401 and wastes the one automatic
    // renewal. A failed item is never reusable (AVFoundation can't reset one), and a different
    // `trim` map replaces the item. A map with no matching composition plays the plain item and is
    // declined below, so the reducer accounts for what is heard.
    let prepared = trim.flatMap { preparedTrims.entry(for: resource.url, map: $0) }
    if let front = queuePlayer.items().first,
      front.resource == resource, front.trim == prepared?.map, !front.isUnusable
    {
      reuseFrontItem(front, localOffset: localOffset, rate: rate, generation: generation)
    } else {
      #if DEBUG
        // Pairs with the next `WHIRRENG emit=ready` to show the audible gap of a map change.
        if let front = queuePlayer.items().first, front.resource == resource {
          DeviceTraceLog.emit("WHIRRTRIM swap trimmed=\(prepared?.map.totalTrimmed ?? 0)")
        }
      #endif
      replaceQueue(
        resource: resource, prepared: prepared, localOffset: localOffset, rate: rate,
        generation: generation)
    }
    if trim != nil, prepared == nil { emit(.trimDeclined(generation: generation)) }
  }

  func play() {
    isPlaybackRequested = true
    transportRequest += 1
    let request = transportRequest
    session.activateForPlayback { [weak self] outcome in
      self?.finishPlay(request: request, outcome: outcome)
    }
  }

  /// Which half of the session handshake a `WHIRRENG session` trace line refers to.
  nonisolated enum AudioSessionStage: String, Sendable {
    case configure
    case activate
    case deactivate
  }

  /// Playback proceeds even when the OS refuses the session: AVFoundation activates implicitly for
  /// a starting `AVPlayer`, and a refusal is usually a transient owner (a call) that
  /// `AudioInterruptionRouteAdapter` handles, so aborting would leave a dead play button. The
  /// refusal is still traced. The queue starts only once the handshake returns.
  private func finishPlay(request: Int, outcome: AudioSessionActivationOutcome) {
    if let error = outcome.configureError { recordSessionFailure(stage: .configure, error: error) }
    if let error = outcome.activateError { recordSessionFailure(stage: .activate, error: error) }
    // The handshake runs off the main actor, so a pause, a stop or a newer play can arrive before
    // it returns. Only the request that is still the latest transport command may start the queue.
    guard request == transportRequest else { return }
    lastSessionActivation = SessionActivationResult(
      generation: currentGeneration, configurationSucceeded: outcome.configureError == nil,
      activationSucceeded: outcome.activateError == nil)
    queuePlayer.play()
    queuePlayer.rate = Float(currentRate)
  }

  private func recordSessionFailure(stage: AudioSessionStage, error: Error) {
    #if DEBUG
      DeviceTraceLog.emit(Self.sessionFailureTraceMessage(stage: stage, error: error))
    #endif
  }

  /// Builds the `WHIRRENG session` trace from validated fields only. As with
  /// `AVFoundationPlayerItemHandle.failureTraceMessage`, errors contribute domain and code, never
  /// descriptions: DeviceTraceLog messages are public on device, and no unbounded foreign string
  /// may enter one (SECURITY.md).
  nonisolated static func sessionFailureTraceMessage(stage: AudioSessionStage, error: Error) -> String {
    let nsError = error as NSError
    let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
    return "WHIRRENG session stage=\(stage.rawValue) domain=\(nsError.domain) "
      + "code=\(nsError.code) underlyingDomain=\(underlying?.domain ?? "-") "
      + "underlyingCode=\(underlying?.code ?? 0)"
  }

  func pause() {
    isPlaybackRequested = false
    transportRequest += 1
    queuePlayer.pause()
  }

  /// The timescale every seek target is expressed in. 1/600s is the conventional media timescale
  /// and divides the common audio frame rates evenly.
  private static let seekTimescale: CMTimeScale = 600

  /// The `CMTime` for a seek to `offset`, rounded up to `seekTimescale`. Rounding to nearest turns
  /// a chapter start of 1234.567 into 1234.566667, and `PlaybackChapterMap` awards a boundary to
  /// the later chapter, so a chapter tap would briefly report the chapter just left. Rounding up
  /// costs at most 1/600 s; the call sites' zero tolerance holds the engine to it.
  static func seekTime(seconds offset: Double) -> CMTime {
    let ticks = (offset * Double(seekTimescale)).rounded(.up)
    guard ticks.isFinite, ticks >= 0, ticks <= Double(CMTimeValue.max) else {
      return CMTime(seconds: offset, preferredTimescale: seekTimescale)
    }
    return CMTime(value: CMTimeValue(ticks), timescale: seekTimescale)
  }

  /// `offset` in source time, as the time to seek `item` to: its composition runs in played time.
  private func playedOffset(_ offset: Double, in item: AudioPlayerItemHandle) -> Double {
    item.trim?.playedTime(forSource: offset) ?? offset
  }

  func seek(toLocalOffset offset: Double) {
    guard let currentItem else { return }
    let generation = currentGeneration
    currentItem.seek(
      to: Self.seekTime(seconds: playedOffset(offset, in: currentItem)), toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { [weak self] _ in
      self?.emitReadyIfAlreadyReady(item: currentItem, generation: generation)
    }
  }

  func setRate(_ rate: Double) {
    currentRate = rate
    // On a real AVPlayer, `rate` is the play/pause state: a non-zero rate while paused would
    // resume playback. While paused (`rate == 0`) only record the request; `play()` reasserts
    // `currentRate` on resume.
    guard queuePlayer.rate != 0 else { return }
    queuePlayer.rate = Float(rate)
  }

  func setVolume(_ volume: Double) {
    let clamped = volume.isFinite ? min(max(volume, 0), 1) : 1
    queuePlayer.volume = Float(clamped)
  }

  func stop() {
    lastSessionActivation = nil
    isPlaybackRequested = false
    transportRequest += 1
    lastBufferingState = nil
    pendingPositioningGeneration = nil
    tearDownCurrentItems()
    preparedTrims.removeAll()
    queuePlayer.pause()
    queuePlayer.removeAllItems()
    positionObserver.stopPositionObservation()
    positionObserver.removeBoundaryObserver()
    // A refused deactivation must not stop the teardown, but it is why another app's audio would
    // fail to resume, so it is traced.
    session.deactivate { [weak self] error in
      if let error { self?.recordSessionFailure(stage: .deactivate, error: error) }
    }
  }

  // MARK: - Load paths

  /// The requested track is already the queue's current item, either because `AVQueuePlayer`
  /// auto-advanced to it (the natural post-`trackFinished` path) or because it was enqueued as
  /// the lookahead. Reuses it rather than tearing down in-flight audio.
  private func reuseFrontItem(
    _ item: AudioPlayerItemHandle, localOffset: Double, rate: Double, generation: Int
  ) {
    let wasPlaying = queuePlayer.rate != 0
    if let currentItem, currentItem !== item {
      unwireCallbacks(currentItem)
    }
    if lookaheadItem === item {
      lookaheadItem = nil
    }
    currentItem = item
    currentGeneration = generation
    wireCallbacks(item, generation: generation)
    // `AVQueuePlayer`'s rate can reset across an item transition on some OS versions, so reassert
    // it, but only when already playing: a non-zero rate while paused starts playback (a paused
    // cross-track seek must stay paused). While paused, `currentRate` holds the request and
    // `play()` reasserts it on resume.
    if wasPlaying {
      queuePlayer.rate = Float(rate)
    }
    ensureLookahead(after: item.trackIndex)

    if localOffset > 0 {
      seekToLoadedOffset(item, localOffset: localOffset, generation: generation)
    } else {
      pendingPositioningGeneration = nil
      emitReadyIfAlreadyReady(item: item, generation: generation)
    }
  }

  /// The requested track is not already in the queue: a first load, a retry, or a cross-track
  /// seek away from the pre-buffered lookahead. Tears down whatever was queued and starts fresh.
  private func replaceQueue(
    resource: PlaybackTrackResource, prepared: PreparedTrimAssets.Entry?, localOffset: Double,
    rate: Double, generation: Int
  ) {
    let wasPlaying = queuePlayer.rate != 0
    tearDownCurrentItems()
    queuePlayer.removeAllItems()

    currentGeneration = generation
    let item = makeConfiguredItem(resource: resource, prepared: prepared)
    queuePlayer.insert(item, after: nil)
    currentItem = item
    wireCallbacks(item, generation: generation)
    // Only carry the rate onto the player when already playing: a non-zero rate while paused
    // starts playback on a real AVPlayer. While paused (including the initial load),
    // `currentRate` holds the request for `play()` to apply.
    if wasPlaying {
      queuePlayer.rate = Float(rate)
    }

    if localOffset > 0 {
      seekToLoadedOffset(item, localOffset: localOffset, generation: generation)
    } else {
      pendingPositioningGeneration = nil
    }

    ensureLookahead(after: resource.trackIndex)
    positionObserver.startPositionObservationIfNeeded()
  }

  /// Seeks a freshly loaded item to its start offset, holding positioning open for `generation`.
  /// The completion tells the adapter the item is at its loaded position, and `.ready` tells
  /// `PlayerReducer` the same, as on every other seek path.
  private func seekToLoadedOffset(
    _ item: AudioPlayerItemHandle, localOffset: Double, generation: Int
  ) {
    pendingPositioningGeneration = generation
    item.seek(
      to: Self.seekTime(seconds: playedOffset(localOffset, in: item)), toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { [weak self] _ in
      self?.finishPositioning(generation: generation)
      self?.emitReadyIfAlreadyReady(item: item, generation: generation)
    }
  }

  /// Enqueues the item for the track after `trackIndex` (per `orderedTrackIndices`), if one
  /// exists and isn't already enqueued. This is what makes the `AVQueuePlayer` boundary gapless.
  private func ensureLookahead(after trackIndex: Int) {
    guard let position = orderedTrackIndices.firstIndex(of: trackIndex) else { return }
    let nextPosition = position + 1
    guard nextPosition < orderedTrackIndices.count else { return }
    let nextIndex = orderedTrackIndices[nextPosition]
    guard let next = resourcesByIndex[nextIndex] else { return }

    if let lookaheadItem {
      if lookaheadItem.resource != next || lookaheadItem.isUnusable {
        discardLookaheadItem()
      } else {
        return
      }
    }

    let item = makeConfiguredItem(resource: next)
    queuePlayer.insert(item, after: currentItem)
    lookaheadItem = item
  }

  /// Where items are made: `.timeDomain`, the forward buffer, and Voice Boost's tap while it is
  /// on. An item adopted by `reuseFrontItem` keeps whatever it was given here.
  private func makeConfiguredItem(
    resource: PlaybackTrackResource, prepared: PreparedTrimAssets.Entry? = nil
  ) -> AudioPlayerItemHandle {
    let item =
      prepared.map {
        itemFactory.makeItem(resource: resource, preparedAsset: $0.asset, trim: $0.map)
      } ?? itemFactory.makeItem(resource: resource)
    item.timePitchAlgorithm = .timeDomain
    applyForwardBuffer(to: item)
    if isVoiceBoostEnabled {
      item.attachAudioProcessor(voiceBoost)
    }
    return item
  }

  /// Turns Voice Boost on or off for everything playing now and loaded later. Turning it on
  /// attaches to every queued item, read from the queue itself: after an auto-advance and before
  /// the next `load`, `currentItem` still names the finished item. Turning it off only lowers the
  /// switch; the taps stay attached, bit-exact in bypass, until their items are replaced.
  func setVoiceBoostEnabled(_ enabled: Bool) {
    isVoiceBoostEnabled = enabled
    if enabled {
      for item in queuePlayer.items() {
        item.attachAudioProcessor(voiceBoost)
      }
    }
    voiceBoost.isEnabled = enabled
  }

  /// Widens the buffer AVFoundation keeps ahead of the playhead for a streamed item
  /// (`streamingForwardBufferDuration`). A local file keeps AVFoundation's default: there is no
  /// radio to let idle, so a long window buys nothing and only costs a re-read after a seek.
  private func applyForwardBuffer(to item: AudioPlayerItemHandle) {
    guard !item.url.isFileURL else { return }
    item.preferredForwardBufferDuration = Self.streamingForwardBufferDuration
  }

  // MARK: - Item callbacks

  private func wireCallbacks(_ item: AudioPlayerItemHandle, generation: Int) {
    item.onReady = { [weak self] in
      self?.handleReady(item: item, generation: generation)
    }
    item.onFailed = { [weak self] error, responseStatusCode in
      self?.handleFailed(generation: generation, error: error, responseStatusCode: responseStatusCode)
    }
    item.onFailedToPlayToEnd = { [weak self] error, responseStatusCode in
      self?.handleFailed(generation: generation, error: error, responseStatusCode: responseStatusCode)
    }
    item.onDidPlayToEnd = { [weak self] in
      self?.handleDidPlayToEnd(generation: generation)
    }
    item.onDurationChanged = { [weak self] seconds in
      self?.handleDurationChanged(seconds, generation: generation)
    }
  }

  /// Clears an item's callbacks so a late async event from an item a later `load` has displaced
  /// never reaches `PlayerCore`. Every path that lets go of an item comes through here, so it
  /// also stops a Voice Boost attach that is still loading the item's track.
  private func unwireCallbacks(_ item: AudioPlayerItemHandle) {
    item.cancelAudioProcessorAttach()
    item.onReady = nil
    item.onFailed = nil
    item.onFailedToPlayToEnd = nil
    item.onDidPlayToEnd = nil
    item.onDurationChanged = nil
  }

  private func discardLookaheadItem() {
    guard let lookaheadItem else { return }
    unwireCallbacks(lookaheadItem)
    queuePlayer.remove(lookaheadItem)
    self.lookaheadItem = nil
  }

  private func tearDownCurrentItems() {
    if let currentItem {
      unwireCallbacks(currentItem)
    }
    if let lookaheadItem {
      unwireCallbacks(lookaheadItem)
    }
    currentItem = nil
    lookaheadItem = nil
  }

  /// Ends the positioning wait opened by a load, unless a newer load has opened its own. A
  /// superseded seek's completion still fires and must not unblock its successor's window.
  private func finishPositioning(generation: Int) {
    guard pendingPositioningGeneration == generation else { return }
    pendingPositioningGeneration = nil
  }

  private func handleReady(item: AudioPlayerItemHandle, generation: Int) {
    guard generation == currentGeneration else { return }
    emitObservedDuration(of: item, generation: generation)
    emit(.ready(generation: generation))
  }

  private func emitReadyIfAlreadyReady(item: AudioPlayerItemHandle, generation: Int) {
    guard generation == currentGeneration, item.isReady else { return }
    emit(.ready(generation: generation))
  }

  private func handleDurationChanged(_ seconds: Double, generation: Int) {
    guard generation == currentGeneration else { return }
    emit(
      .durationObserved(
        generation: generation, localDuration: currentItem?.trim?.sourceTime(forPlayed: seconds) ?? seconds))
  }

  /// An item whose duration resolved before its callback was wired (a reused front item, or one
  /// that reached `readyToPlay` in the same turn) would never report it, as KVO delivers only
  /// later changes.
  private func emitObservedDuration(of item: AudioPlayerItemHandle, generation: Int) {
    guard let duration = item.duration else { return }
    let seconds = CMTimeGetSeconds(duration)
    guard seconds.isFinite, seconds > 0 else { return }
    emit(
      .durationObserved(
        generation: generation, localDuration: item.trim?.sourceTime(forPlayed: seconds) ?? seconds))
  }

  /// Classification lives in `PlayerCore` (`AudioEngineFailure.init(assetLoadError:...)`) so it is
  /// testable on the host. This adapter only forwards what AVFoundation gave it.
  private func handleFailed(generation: Int, error: Error, responseStatusCode: Int) {
    guard generation == currentGeneration else { return }
    emit(
      .failed(
        generation: generation,
        AudioEngineFailure(assetLoadError: error, responseStatusCode: responseStatusCode)))
  }

  private func handleDidPlayToEnd(generation: Int) {
    guard generation == currentGeneration else { return }
    emit(.trackFinished(generation: generation))
  }

  private func handleBufferingChanged(_ isBuffering: Bool) {
    guard let currentItem else { return }
    // `timeControlStatus` has three states but the adapter only distinguishes "waiting for data"
    // from not. A paused real player churns between the two non-waiting states, delivering
    // isWaiting=false repeatedly, and a fresh `.ready` for each caused a runaway on device
    // (`WHIRRENG emit=ready req=0 rate=0.00`, streaming). Collapse identical signals to the
    // single transition that changed something.
    guard lastBufferingState != isBuffering else { return }
    lastBufferingState = isBuffering
    if isBuffering {
      emit(.buffering(generation: currentGeneration))
    } else if currentItem.isReady {
      emit(.ready(generation: currentGeneration))
    }
  }

  // MARK: - Position observation

  /// Switches the periodic observer between cadences (see `EnginePositionObserver`).
  func setPositionCadence(_ cadence: PositionCadence) {
    positionObserver.setPositionCadence(cadence)
  }

  func setBoundary(atLocalOffset offset: Double?) {
    positionObserver.setBoundary(atLocalOffset: offset)
  }

  private func emit(_ event: AudioEngineEvent) {
    #if DEBUG
      // Tags which engine event drives a runaway, which the reducer's WHIRRPERF trace can't say.
      // `positionUpdated` means the periodic observer is firing (gated by `isPlaybackRequested`);
      // `ready`/`buffering` means the `timeControlStatus` KVO is churning. `req`/`rate` show
      // whether the adapter still thinks playback is live. DEBUG-only; filter with
      // `eventMessage CONTAINS "WHIRRENG"`.
      let kind: String
      switch event {
      case .ready: kind = "ready"
      case .buffering: kind = "buffering"
      case .positionUpdated(_, let localOffset): kind = "pos:\(String(format: "%.2f", localOffset))"
      case .durationObserved(_, let localDuration):
        kind = "dur:\(String(format: "%.2f", localDuration))"
      case .trackFinished: kind = "trackFinished"
      case .failed: kind = "failed"
      case .trimDeclined: kind = "trimDeclined"
      }
      DeviceTraceLog.emit(
        "WHIRRENG emit=\(kind) req=\(isPlaybackRequested ? 1 : 0) "
          + "rate=\(String(format: "%.2f", Double(queuePlayer.rate)))")
    #endif
    continuation.yield(event)
  }
}
