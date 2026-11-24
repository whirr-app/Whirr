import ABSApi
import Foundation
import Observation
import PlayerCore
import WatchPlayback
import WatchProtocol

/// Choosing and loading a start: the resume position, the audio, and the row it opens.
extension WatchPlaybackController {
  /// Chooses the resume position (or the handed-over one), loads a complete download or a stream,
  /// and opens the title's progress row.
  func prepare(_ selection: WatchSelection, handoffPosition: Double?) async throws {
    if case .nativeFeed = selection {
      try await prepareNative(selection, handoffPosition: handoffPosition)
      return
    }
    lastClosedNative = nil
    lastClosedNativeFinished = false
    await Self.settled(reconciliationTask)
    try Task.checkCancellation()
    if handoffPosition == nil { await refreshSharedProgress() }
    try Task.checkCancellation()
    guard let coordinator else { throw WatchLibraryError.notAuthenticated }
    let retainedRows = await progressStore?.allSessions() ?? []
    let shared = WatchResumeCandidates.row(for: selection, in: serverProgress)
    let start = WatchResumeCandidates.start(
      for: selection, handoff: handoffPosition, rows: retainedRows, bookmark: bookmark,
      serverRows: serverProgress, now: .now)
    let local = downloads.filter { $0.selection == selection && $0.isPlayable }.sorted { $0.fileIndex < $1.fileIndex }
    let all = downloads.filter { $0.selection == selection }
    let duration: Double
    if let group = local.first?.downloadGroupID, !local.isEmpty, local.count == all.count,
      let downloadStore, await downloadStore.isGroupComplete(groupID: group)
    {
      let timeline = try PlaybackTimeline(
        tracks: local.map { PlaybackTrack(index: $0.fileIndex, startOffset: $0.startOffset, duration: $0.duration) })
      var tracks: [WatchAudioTrack] = []
      for manifest in local {
        tracks.append(
          WatchAudioTrack(
            index: manifest.fileIndex, url: try await downloadStore.completedFileURL(for: manifest.id), headers: [:]))
      }
      try await coordinator.prepareOffline(
        WatchAudioPreparation(
          title: model.catalogue.title(for: selection), timeline: timeline, tracks: tracks,
          chapters: .init(chapters: local.flatMap(\.chapters))),
        position: start, rate: audio.selectedRate)
      streaming = false
      duration = timeline.totalDuration
    } else {
      // The Watch never opens a server session; every stream keeps progress locally.
      let preparation = try await coordinator.prepareIndependent(
        selection: selection, position: start, rate: audio.selectedRate)
      streaming = true
      duration = preparation.timeline.totalDuration
    }
    loadedSelection = selection
    guard let progressStore else { return }
    let lifecycle = WatchLocalProgressLifecycle(
      store: progressStore, selection: selection, duration: duration,
      sharedPosition: shared?.currentTime, sharedObservedAt: shared?.lastUpdate)
    localProgress = lifecycle
    try await lifecycle.play(at: start)
    offlineSessionID = await lifecycle.openRowID
  }
  /// Loads a received copy. Its entry, duration and start position come from the store and the
  /// native journal (`WatchNativePlayback.swift`); nothing here reads server progress, a resume
  /// candidate or the phone.
  func prepareNative(_ selection: WatchSelection, handoffPosition: Double?) async throws {
    let native = try await nativePreparation(selection, handoffPosition: handoffPosition)
    guard let coordinator else { throw WatchLibraryError.notAuthenticated }
    try await coordinator.prepareOffline(
      native.preparation, position: native.start, rate: audio.selectedRate)
    streaming = false
    loadedSelection = selection
    lastClosedNative = nil
    lastClosedNativeFinished = false
    localProgress = native.lifecycle
    // The journal opens the row, so `offlineSessionID` stays nil for a received copy.
    try await native.lifecycle.play(at: native.start)
    nativeSessionID = await native.lifecycle.openRowID
  }
  /// Waits for an upload run so the rows it acknowledges are settled before a start reads them,
  /// but no longer than the start itself: a pause or a newer start cancels the wait, not the run.
  static func settled(_ task: Task<Void, Never>?) async {
    guard let task else { return }
    let finished = AsyncStream<Void> { continuation in
      Task {
        await task.value
        continuation.finish()
      }
    }
    for await _ in finished {}
  }
  /// A paused title may have been played further on another device since the Watch last played
  /// it. The server is the source of truth, so newer listening there moves the Watch to it.
  /// The move is not a Watch listen: it adopts listening done elsewhere.
  func catchUpToSharedProgress(_ selection: WatchSelection, _ id: Attempt) async throws {
    let local = WatchResumePosition.Candidate(position: audio.position, listenedAt: listening.lastListened(selection))
    await refreshSharedProgress()
    try Task.checkCancellation()
    guard machine.isCurrent(id),
      let shared = WatchResumeCandidates.shared(for: selection, in: serverProgress, now: .now),
      WatchResumePosition.sharedSupersedes(local: local, shared: shared)
    else { return }
    // A title finished elsewhere replays from the beginning, as a fresh start of it would.
    try await coordinator?.seek(to: shared.finished ? 0 : shared.position)
  }
  /// A paused title holds no row; playing again opens one at the current position.
  func reopenRow() async {
    guard openRowID == nil, let localProgress else { return }
    let selection = loadedSelection ?? currentSelection
    do {
      try await localProgress.play(at: audio.position)
      setOpenRow(await localProgress.openRowID, for: selection)
    } catch {
      WatchDiagnostics.record(.progressPersistenceFailed)
    }
  }
  /// The retained bookmark, dated by the last listen to its title in this process.
  var bookmark: WatchResumeCandidates.Bookmark? {
    retainedSelection.map {
      .init(selection: $0, position: retainedPosition, listenedAt: listening.lastListened($0))
    }
  }
}
