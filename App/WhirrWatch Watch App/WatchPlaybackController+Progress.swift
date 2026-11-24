import ABSApi
import Foundation
import Observation
import PlayerCore
import WatchPlayback
import WatchProtocol

/// Progress rows, listening time and the report that tells the phone the Watch is playing.
extension WatchPlaybackController {
  /// An upload never waits for the phone; the scheduler coalesces repeated requests.
  func requestUpload() {
    // A download starting holds the library against a start, not against an upload.
    let uploads = (model.busyHolder.map({ $0 == .downloading }) ?? true) && !loggingOut
    // A native-feed listen goes to the phone, never to ABS (ADR 0019); the ABS rows written before
    // it still upload, but only when some wait.
    if (loadedSelection ?? currentSelection).flatMap({ WatchNativeSelection($0) }) != nil
      || lastClosedNative != nil
    {
      let finished = lastClosedNativeFinished ? lastClosedNative : nil
      lastClosedNative = nil
      lastClosedNativeFinished = false
      let openRow = nativeSessionID
      Task { [weak self, weak model] in
        await self?.reportNativeProgress(removingFinished: finished, openRow: openRow)
        if uploads { await model?.offlineSync.reconcileIfPending() }
      }
      return
    }
    guard uploads else { return }
    // Bind the model for the whole run: its controllers hold it unowned.
    Task { [weak model] in
      guard let model else { return }
      await model.offlineSync.reconcileOfflineProgress()
    }
  }
  /// When `selection` was last listened to or moved here, which Now Playing weighs against
  /// the phone's last listen.
  func lastListened(_ selection: WatchSelection) -> Date? {
    _ = listenedRevision
    return listening.lastListened(selection)
  }
  func noteListening(_ selection: WatchSelection) {
    listening.noteListening(selection, at: .now)
    listenedRevision &+= 1
  }
  /// A listener's seek counts as a listen of the title here.
  func recordSeek(to target: Double) async {
    if let currentSelection { noteListening(currentSelection) }
    guard let localProgress else { return }
    do {
      if try await localProgress.seek(to: target) == .upload { requestUpload() }
    } catch {
      WatchDiagnostics.record(.progressPersistenceFailed)
    }
  }
  /// The phone lets a report lapse, as the Watch cannot retract one once out of range, so a
  /// title that keeps playing says so again before the last report expires.
  private func refreshPlayingReport() {
    guard case .playing = machine.phase,
      WatchPlayingReport.refreshDue(lastPublished: playingReportedAt, now: .now)
    else { return }
    publishPlayingReport(playing: true)
  }
  /// The phone reads this before it starts, to know whether to ask the Watch to pause.
  func publishPlayingReport(playing: Bool) {
    if !playing { playingReportedAt = nil }
    guard let stamp = authenticatedStamp else { return }
    let selection = currentSelection.flatMap { try? WatchABSSelection(selection: $0) }
    // A received copy is named on its own field: the wire never claims Watch playability for an RSS
    // row, and the phone reads this to avoid a concurrent start (ADR 0019).
    let native = currentSelection.flatMap { WatchNativeSelection($0) }
    guard
      let report = try? WatchPlayingReport(
        accountStamp: stamp, selection: selection,
        playing: playing && (selection != nil || native != nil), observedAt: .now,
        nativeSelection: native),
      let data = try? WatchWireCodec.encode(report)
    else { return }
    guard model.applicationContext.publishPlayingReport(data) else { return }
    if report.playing { playingReportedAt = report.observedAt }
  }
  /// Refreshes server progress, giving up after a short wait so an offline Watch still plays.
  func refreshSharedProgress() async {
    let catalogue = model.catalogue
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await catalogue.refreshContinueListening() }
      group.addTask { try? await Task.sleep(for: Self.sharedProgressWait) }
      await group.next()
      group.cancelAll()
    }
  }
  /// Records the last tick and closes the open row. `ending` also unloads the local title's
  /// progress. Returns whether a closed row now waits for upload.
  func closeLocalProgress(ending: Bool, finished: Bool) async -> Bool {
    let closing = loadedSelection ?? currentSelection
    // A closed native row is reported to the phone, never uploaded as an ABS row (ADR 0019).
    lastClosedNative = closing.flatMap { WatchNativeSelection($0) }
    lastClosedNativeFinished = finished
    let listened = takeListenedDelta()
    let lifecycle = localProgress
    if ending { localProgress = nil }
    guard let lifecycle else {
      offlineSessionID = nil
      nativeSessionID = nil
      return false
    }
    do {
      let effect =
        ending
        ? try await lifecycle.stop(at: audio.position, listened: listened, finished: finished)
        : try await lifecycle.pause(at: audio.position, listened: listened)
      setOpenRow(ending ? nil : await lifecycle.openRowID, for: closing)
      return effect == .upload
    } catch {
      WatchDiagnostics.record(.progressPersistenceFailed)
      setOpenRow(ending ? nil : await lifecycle.openRowID, for: closing)
      return false
    }
  }
  /// The open progress row of the loaded title, in whichever store owns it.
  var openRowID: UUID? { nativeSessionID ?? offlineSessionID }
  /// A received copy's row is never handed to the ABS upload as the row it excludes.
  func setOpenRow(_ id: UUID?, for selection: WatchSelection?) {
    let native = selection.flatMap { WatchNativeSelection($0) }
    if native != nil {
      nativeSessionID = id
    } else {
      offlineSessionID = id
    }
  }
  private func takeListenedDelta() -> Double {
    let delta = heldListening + listening.take(at: ProcessInfo.processInfo.systemUptime, playing: audio.isPlaying)
    heldListening = 0
    return delta
  }
  /// Every two seconds while playing: a tick, the bookmark, and a checkpoint when one is due.
  func startTicker() {
    listening.restart(at: ProcessInfo.processInfo.systemUptime, playing: audio.isPlaying)
    offlineTimer?.cancel()
    let token = sessionEpoch
    offlineTimer = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2))
        guard let self, !Task.isCancelled, token == self.sessionEpoch else { return }
        self.refreshPlayingReport()
        let due = self.model.offlineSync.checkpointDue(playing: self.audio.isPlaying)
        self.send(.tick(checkpointDue: due))
      }
    }
  }
  /// A long listen is closed into an uploadable row every ten minutes.
  func checkpoint() async {
    guard openRowID != nil, let localProgress else { return }
    let selection = loadedSelection ?? currentSelection
    do {
      let effect = try await localProgress.checkpoint(at: audio.position, listened: takeListenedDelta())
      setOpenRow(await localProgress.openRowID, for: selection)
      if effect == .upload { requestUpload() }
    } catch {
      // The row may have closed without another opening; the next tick must not write to it.
      setOpenRow(await localProgress.openRowID, for: selection)
      WatchDiagnostics.record(.progressPersistenceFailed)
    }
  }
  func recordOfflineTick() async {
    guard let localProgress else { return }
    // A failed checkpoint or reopen leaves no row; the listening stays in the clock until one opens.
    if openRowID == nil { await reopenRow() }
    do {
      guard openRowID != nil else { throw WatchLibraryError.storageFailure }
      try await localProgress.record(position: audio.position, listened: takeListenedDelta())
    } catch {
      // A row that cannot be written would lose the listen, so the title pauses quietly.
      WatchDiagnostics.record(.progressPersistenceFailed)
      send(.pause(.listener))
    }
  }
  func saveBookmark(position override: Double? = nil) {
    let position = override ?? audio.position
    guard let selection = loadedSelection ?? currentSelection, position.isFinite,
      let stamp = authenticatedStamp,
      let bookmark = try? WatchResumeBookmark(accountStamp: stamp, selection: selection, position: position),
      let data = try? JSONEncoder().encode(bookmark)
    else { return }
    retainedSelection = selection
    retainedPosition = position
    // The newest position replaces any bookmark, read or not; before first unlock the write
    // fails and the next save retries.
    try? model.protectedStore.save(data, key: Self.bookmarkKey)
  }
  static let bookmarkKey = "watch.resume.bookmark"
  /// The saved bookmark, or nil when there is none or it cannot be read yet.
  func savedBookmark() -> WatchResumeBookmark? {
    model.protectedStore.read(key: Self.bookmarkKey) {
      try JSONDecoder().decode(WatchResumeBookmark.self, from: $0)
    }.value
  }
  func clearBookmark() {
    try? model.protectedStore.clear(key: Self.bookmarkKey)
  }
}
