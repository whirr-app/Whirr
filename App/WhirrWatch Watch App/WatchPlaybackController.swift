import ABSApi
import Foundation
import Observation
import PlayerCore
import WatchPlayback
import WatchProtocol

/// Interprets `WatchPlaybackMachine`. A request changes the phase at once; its effects run as one
/// job on a serial lane, so a teardown never interleaves with the start or seek it supersedes. An
/// asynchronous effect reports back as a completion event, whose effects run inline in the same
/// job. A request that leaves the running job's attempt stale cancels that job; the request's own
/// job, queued after it, releases whatever the stale attempt loaded.
@MainActor
@Observable
final class WatchPlaybackController {
  typealias Event = WatchPlaybackMachine.Event
  typealias Effect = WatchPlaybackMachine.Effect
  typealias Attempt = WatchPlaybackMachine.Attempt

  unowned let model: WatchLibraryModel
  private var context: WatchSessionContext? { model.session.context }
  /// The machine's title: shown as loaded from the moment a start is asked for.
  private(set) var currentSelection: WatchSelection? = nil { didSet { model.publishPlayback() } }
  /// A start or playback is under way, audible or not, as the machine has it: a start that is
  /// still loading has not reached the engine yet.
  private(set) var wantsPlayback = false
  let audio = WatchAudioEngine()
  @ObservationIgnored var machine = WatchPlaybackMachine()
  @ObservationIgnored private var lane: Task<Void, Never>?
  @ObservationIgnored private var jobs: [Int: Task<Void, Never>] = [:]
  @ObservationIgnored private var lastJob = 0
  @ObservationIgnored private var runningJob: Int?
  @ObservationIgnored private var runningAttempt: Attempt?
  /// When a wanted stream has stopped for good, and the check that waits for its bound.
  @ObservationIgnored private var stallPolicy = WatchStallPolicy()
  @ObservationIgnored private var stallCheck: Task<Void, Never>?
  /// What interruptions and route changes do.
  @ObservationIgnored var interruptionPolicy = WatchInterruptionPolicy()
  /// Admits the phone's pause requests: account, window and replay checks.
  var handoffResponder = WatchHandoffResponder()
  /// The open progress row of a locally played title; `nil` while paused, so a paused title
  /// does not block upload. A native-feed row lives in `nativeSessionID` instead.
  var offlineSessionID: UUID?
  /// A received copy's journal row. It never reaches the ABS upload's open-row exclusion, because
  /// that exclusion is read from `offlineSessionID` only.
  @ObservationIgnored var nativeSessionID: UUID?
  /// The native row a pause or stop closed, and whether its title finished: the upload request that
  /// follows reports it to the phone instead of reading an ABS server.
  @ObservationIgnored var lastClosedNative: WatchNativeSelection?
  @ObservationIgnored var lastClosedNativeFinished = false
  /// The title whose audio and progress are loaded, playing or paused.
  var loadedSelection: WatchSelection?
  var localPlaybackLoaded: Bool { loadedSelection != nil }
  var localProgress: WatchLocalProgressLifecycle?
  /// Whether the loaded title streams from the server; a download's files cannot be renewed.
  var streaming = false
  var retainedPosition: Double = 0
  var retainedSelection: WatchSelection?
  /// Listening time, and when each title was last listened to or moved by the user here. A bookmark
  /// restored at launch has no date, so newer shared progress takes precedence over it.
  /// Unobserved: it ticks while playing. `listenedRevision` marks the changes Now Playing reads.
  @ObservationIgnored var listening = WatchListeningClock()
  var listenedRevision = 0
  /// Listening taken when the audio was silenced, before the row that receives it is written.
  var heldListening: Double = 0
  /// When the phone was last told the Watch is playing; `nil` while it is not.
  @ObservationIgnored var playingReportedAt: Date?
  /// How long a start or resume waits for fresh server progress before using what it has.
  static let sharedProgressWait: Duration = .seconds(3)
  /// How long a start of the phone's own title waits for the phone to pause and say where.
  static let handoffWait: Duration = .seconds(3)
  private var account: WatchAccountRecord? { context?.account ?? model.account }
  var authenticatedStamp: WatchAccountStamp? {
    context?.authenticatedStamp ?? (try? account?.authenticatedStamp())
  }
  private var message: String? {
    get { model.message }
    set { model.setMessage(newValue) }
  }
  var companion: WatchCompanionStore { model.companion }
  var sessionEpoch: Int { model.session.epoch }
  var loggingOut: Bool { model.session.loggingOut }
  var coordinator: WatchPlaybackSessionCoordinator? { context?.coordinator }
  var downloadStore: WatchDownloadStore? { context?.downloadStore }
  var progressStore: WatchOfflineProgressStore? { context?.progressStore }
  var reconciliationTask: Task<Void, Never>? { model.session.lifecycle.reconciliation }
  var offlineTimer: Task<Void, Never>? {
    get { model.session.lifecycle.offlineTimer }
    set { model.session.lifecycle.offlineTimer = newValue }
  }
  var serverProgress: [MediaProgress] { model.catalogue.serverProgress }
  var downloads: [WatchDownloadManifest] { model.downloadsController.downloads }
  /// The signed-in account's service graph: a received copy's store, journal and coordinator are
  /// not the ABS controllers' (ADR 0019).
  var sessionContext: WatchSessionContext? { context }
  /// Received copies and their progress, owned by the episode sync rather than the ABS stores.
  var episodeSync: WatchEpisodeSync { model.episodes }

  /// Whether a start can begin now, and if not, why.
  private var readiness: WatchPlaybackReadiness {
    if loggingOut { return .busy(.signingOut) }
    if let holder = model.busyHolder { return .busy(holder) }
    if context == nil { return model.session.initialized ? .signedOut : .launching }
    return .ready
  }

  private func observePlaybackPreferences() {
    let snapshot = withObservationTracking {
      companion.snapshot
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.observePlaybackPreferences() }
    }
    audio.configureSkipIntervals(
      backward: WatchDisplayFormatting.skipInterval(snapshot: snapshot, forward: false),
      forward: WatchDisplayFormatting.skipInterval(snapshot: snapshot, forward: true))
  }

  init(model: WatchLibraryModel) {
    self.model = model
    observePlaybackPreferences()
    audio.onRemotePlay = { [weak self] in Task { await self?.remotePlay() } }
    audio.onRemotePause = { [weak self] in self?.send(.pause(.listener)) }
    audio.onRemoteSeek = { [weak self] position in self?.send(.seek(to: position)) }
    audio.onRemoteSkip = { [weak self] delta in self?.skip(by: delta) }
    audio.onEnded = { [weak self] in self?.send(.audioEnded) }
    audio.onDurationGrew = { [weak self] duration in self?.send(.durationGrew(duration)) }
    audio.onFailure = { [weak self] unauthorized in self?.handleAudioFailure(unauthorized: unauthorized) }
    audio.onReset = { [weak self] in self?.send(.audioReset) }
    audio.onObservation = { [weak self] observation in self?.observe(observation) }
    audio.onInterruption = { [weak self] notification in self?.interrupted(notification) }
    // A copy the phone dropped can no longer play: stop it and forget where it was.
    model.episodes.onCopiesDropped = { [weak self] dropped in self?.copiesDropped(dropped) }
  }

  // MARK: Requests

  /// Returns whether the title is loaded and was asked to play. A stream can still be buffering,
  /// so callers must not wait for audible audio before showing the player.
  @discardableResult
  func play(_ selection: WatchSelection) async -> Bool {
    interruptionPolicy.listenerActed()
    // The Watch is the only evidence a native-feed title can play here (ADR 0019); without a copy
    // the machine tells the listener to send it from the iPhone.
    let hasLocalCopy = await nativeCopyIsReady(selection)
    await send(.play(selection, readiness, hasLocalCopy: hasLocalCopy))?.value
    return machine.phase == .playing(selection)
  }

  func resume() async {
    // A play during launch waits for the restore rather than seeing no bookmark.
    interruptionPolicy.listenerActed()
    if context == nil { await model.session.initialize() }
    // A native bookmark resumes only while its copy is ready: a copy still being sent, or dropped
    // since, leaves the machine saying to send the episode from the iPhone.
    var bookmarkHasLocalCopy = false
    if let retainedSelection { bookmarkHasLocalCopy = await nativeCopyIsReady(retainedSelection) }
    await send(
      .resume(readiness, bookmark: retainedSelection, bookmarkHasLocalCopy: bookmarkHasLocalCopy)
    )?.value
  }

  /// A system play. With nothing loaded while the phone reports playing, the phone already has
  /// the listener, so the Watch does not take it over.
  private func remotePlay() async {
    if machine.phase == .idle, companion.phoneReportsPlaying { return }
    await resume()
  }

  func pause() async {
    interruptionPolicy.listenerActed()
    await send(.pause(.listener))?.value
  }

  func seek(to position: Double) async {
    await send(.seek(to: position))?.value
  }

  /// Repeated skips add to the last requested target, not to the sampled position.
  func skip(by delta: Double) {
    send(.skip(by: delta, position: audio.position, duration: audio.duration))
  }

  func setRate(_ rate: Double) async { try? await coordinator?.setRate(rate) }

  func stopPlayback(finished: Bool = false) async {
    interruptionPolicy.listenerActed()
    cancelPeerHandoff()
    await send(.stop(finished: finished))?.value
  }

  /// The Watch pauses, asks the phone to start where it was, and unloads only once the phone
  /// accepts. Otherwise the title stays paused here with a message.
  func continueOnPhone() async {
    interruptionPolicy.listenerActed()
    await send(.continueOnPhone)?.value
  }

  private func handleAudioFailure(unauthorized: Bool) {
    guard !loggingOut else { return }
    send(.audioFailed(unauthorized: unauthorized, streaming: streaming))
  }

  /// The phone asked the Watch to pause a native-RSS episode. Answers whether the Watch
  /// was playing it; when it was, the pause runs through the machine as the peer pause a start
  /// hands over, so the row closes before the reply names the position.
  func pauseForNativeRequest(_ selection: WatchNativeSelection) async -> Bool {
    guard machine.phase.isStartingOrPlaying, machine.phase.selection == selection.selection else {
      return false
    }
    interruptionPolicy.listenerActed()
    await send(.pause(.peer))?.value
    return true
  }

  /// Feeds the stall policy and keeps one check waiting for its bound.
  private func observe(_ observation: WatchStallPolicy.Observation) {
    let now = ProcessInfo.processInfo.systemUptime
    act(on: stallPolicy.observe(observation, wanted: audio.wantsPlayback, at: now))
  }

  private func act(on verdict: WatchStallPolicy.Verdict) {
    stallCheck?.cancel()
    stallCheck = nil
    switch verdict {
    case .none: break
    case .stalled:
      send(.stalled)
      // The player may already sit paused and report nothing further, so the next request must
      // not inherit this episode as already reported.
      stallPolicy.reset()
    case .checkAt(let deadline):
      let wait = max(0, deadline - ProcessInfo.processInfo.systemUptime)
      stallCheck = Task { [weak self] in
        try? await Task.sleep(for: .seconds(wait))
        guard let self, !Task.isCancelled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        self.act(on: self.stallPolicy.check(wanted: self.audio.wantsPlayback, at: now))
      }
    }
  }

  /// An interruption pauses what plays; its end resumes only what it paused.
  private func interrupted(_ notification: WatchInterruptionPolicy.Notification) {
    switch interruptionPolicy.handle(notification, playing: audio.wantsPlayback) {
    case .none: break
    case .pause: send(.pause(.listener))
    case .resume: send(.resumeAfterInterruption)
    }
  }

  // MARK: Lane

  /// Hands `event` to the machine and queues its effects as one job. Returns the job, if any.
  @discardableResult
  func send(_ event: Event) -> Task<Void, Never>? {
    let effects = machine.handle(event)
    publishPhase()
    if let runningAttempt, !machine.isCurrent(runningAttempt), let runningJob {
      jobs[runningJob]?.cancel()
    }
    guard !effects.isEmpty else { return nil }
    // Silence first, before anything queued ahead of this request has finished.
    if effects.first == .pauseAudio { silence() }
    lastJob &+= 1
    let number = lastJob
    let previous = lane
    let job = Task { [weak self] in
      await previous?.value
      guard let self else { return }
      self.runningJob = number
      await self.perform(effects)
      self.runningJob = nil
      self.jobs[number] = nil
    }
    jobs[number] = job
    lane = job
    return job
  }

  private func publishPhase() {
    let selection = machine.phase.selection
    if currentSelection != selection { currentSelection = selection }
    let wants = machine.phase.isStartingOrPlaying
    if wantsPlayback != wants { wantsPlayback = wants }
  }

  private func perform(_ effects: [Effect]) async {
    for effect in effects { await perform(effect) }
  }

  /// Feeds an asynchronous effect's outcome back and runs what it asks for in the same job.
  func complete(_ event: Event) async {
    let effects = machine.handle(event)
    publishPhase()
    await perform(effects)
  }

  /// Runs `work` for `attempt`, so a request that makes the attempt stale cancels it.
  func attempt(_ attempt: Attempt, _ work: () async -> Void) async {
    runningAttempt = attempt
    defer { runningAttempt = nil }
    await work()
  }

  private func perform(_ effect: Effect) async {
    switch effect {
    case .pauseAudio: silence()
    case .saveBookmark(let atStart): saveBookmark(position: atStart ? 0 : nil)
    case .closeRow(let ending, let finished, let uploadAfter):
      await runCloseRow(ending: ending, finished: finished, uploadAfter: uploadAfter)
    case .stopTicker: runStopTicker()
    case .stopAudio: await unload()
    case .publishPlaying(let playing): publishPlayingReport(playing: playing)
    case .requestUpload: requestUpload()
    case .show(let notice): show(notice)
    case .clearMessage: message = nil
    case .askPeer(let selection, let id): await runAskPeer(selection: selection, id: id)
    case .tellPeer(let selection): tellPhoneToPause(selection)
    case .prepare(let selection, let handoffPosition, let id):
      await runPrepare(selection: selection, handoffPosition: handoffPosition, id: id)
    case .catchUp(let selection, let id): await runCatchUp(selection: selection, id: id)
    case .renew(let selection, let id): await runRenew(selection: selection, id: id)
    case .reopenRow(let id): await runReopenRow(id: id)
    case .playAudio(let id): await runPlayAudio(id: id)
    case .startListening:
      if let currentSelection { noteListening(currentSelection) }
    case .startTicker: startTicker()
    case .seekAudio(let target, let id): await runSeek(target: target, id: id)
    case .recordSeek(let target): await recordSeek(to: target)
    case .recordTick: await recordOfflineTick()
    case .checkpoint: await checkpoint()
    case .sendToPhone(let selection, let id): await runSendToPhone(selection: selection, id: id)
    case .growRow(let duration): await runGrowRow(duration: duration)
    }
  }

  // MARK: Effects

  /// A seek that failed for `attempt`. One that had already replaced the queue left nothing that
  /// plays from the title's position, which the machine hears as failed audio: the title
  /// pauses, and the next play loads it again. A superseded seek leaves that to its successor.
  func failedMoving(_ attempt: Attempt, _ error: any Error) async {
    let failure = WatchPlaybackFailure(error)
    await complete(.failed(attempt, failure))
    if failure != .cancelled, audio.needsReload {
      await complete(.audioFailed(unauthorized: false, streaming: streaming))
    }
  }

  /// Silences the audio. The listening up to now is held for the row that is written next.
  private func silence() {
    heldListening += listening.take(at: ProcessInfo.processInfo.systemUptime, playing: audio.isPlaying)
    if audio.isPlaying, let currentSelection { noteListening(currentSelection) }
    // A player the system already paused reports nothing more, so its wait must not be read as a
    // stall by the next play.
    stallCheck?.cancel()
    stallCheck = nil
    stallPolicy.reset()
    audio.pause()
  }

  private func show(_ notice: WatchPlaybackNotice) {
    switch notice {
    case .startFailed, .streamFailed, .downloadFailed, .streamLost: WatchDiagnostics.record(.playbackFailed)
    default: break
    }
    message = notice.text
  }

  /// Unloads the audio, superseding any preparation the coordinator still has in flight.
  private func unload() async {
    if let coordinator { await coordinator.cancel() } else { audio.stop() }
    loadedSelection = nil
    streaming = false
    nativeSessionID = nil
  }

}
