import AVFoundation
import Foundation
import PlayerCore
import WatchPlayback
import WatchProtocol

/// What a received copy needs to load: its one-track preparation, the position it starts at, and the
/// journal row lifecycle that records the listen. Built from the store's entry alone, because a
/// native-feed episode has no server progress and no resume candidate.
struct NativePlaybackPreparation {
  let preparation: WatchAudioPreparation
  let start: Double
  let lifecycle: WatchLocalProgressLifecycle
}

/// Playback of a native-RSS episode from the copy the iPhone sent (ADR 0019). The copy's entry, its
/// journal and its file are the only inputs: no server read, no shared progress, and no request to
/// the phone, which is why a start here never waits for one.
extension WatchPlaybackController {
  /// Plans the load of `selection`'s copy. It throws when the store, journal or ready file is gone,
  /// so the machine reports a failed start rather than playing something else.
  func nativePreparation(
    _ selection: WatchSelection, handoffPosition: Double?
  ) async throws -> NativePlaybackPreparation {
    guard let native = WatchNativeSelection(selection),
      let store = sessionContext?.receivedEpisodes,
      let journal = sessionContext?.nativeJournal
    else { throw WatchLibraryError.storageFailure }
    guard let entry = await store.entry(for: native) else {
      throw WatchReceivedEpisodeStoreError.notFound
    }
    let fileURL = try await store.playableFileURL(for: native)
    let duration = try await duration(of: entry, at: fileURL)
    let start: Double
    if let handoffPosition {
      start = handoffPosition
    } else {
      // A handoff never names a native feed, so this is the position the copy and the Watch's own
      // last listen agree on.
      start = WatchNativeResumePosition.resolve(
        local: await journal.latest(for: native), phonePosition: entry.phonePosition,
        phoneLastListenedAt: entry.phoneLastListenedAt, duration: duration)
    }
    let timeline = try PlaybackTimeline(
      tracks: [PlaybackTrack(index: 0, startOffset: 0, duration: duration)])
    return NativePlaybackPreparation(
      preparation: WatchAudioPreparation(
        title: entry.title, timeline: timeline,
        tracks: [WatchAudioTrack(index: 0, url: fileURL, headers: [:])],
        chapters: .init(chapters: entry.playbackChapters)),
      start: start,
      lifecycle: WatchLocalProgressLifecycle(
        store: journal, selection: selection, duration: duration, sharedPosition: nil,
        sharedObservedAt: nil))
  }

  /// Answers the phone's pause request. The Watch pauses the named episode through the
  /// same peer pause a start hands over, so its row closes before the reply names the position, and
  /// then reports the listen. Another title, or a paused Watch, answers that it was not playing it.
  func answerNativePause(_ data: Data) async -> Data? {
    guard let request = try? WatchWireCodec.decode(WatchNativePauseRequest.self, from: data) else {
      return nil
    }
    let selection = request.selection
    guard await pauseForNativeRequest(selection) else {
      return try? WatchWireCodec.encode(
        WatchNativePauseReply(selection: selection, paused: false))
    }
    // The peer pause closes the row, and closing it reports the listen to the phone, as the
    // handoff pause does for an Audiobookshelf title.
    return try? WatchWireCodec.encode(
      WatchNativePauseReply(
        selection: selection, paused: true, position: audio.position,
        lastListenedAt: lastListened(selection.selection)))
  }

  /// Whether `selection` is a native-feed episode with a ready copy, read from the store itself: a
  /// relaunch restores the account before the ingress chain refreshes the ready set, so a start
  /// right after it would otherwise find none and tell the listener to send it again.
  func nativeCopyIsReady(_ selection: WatchSelection) async -> Bool {
    guard case .nativeFeed = selection else { return false }
    await episodeSync.refreshReadyCopies()
    return episodeSync.hasReadyCopy(selection)
  }

  /// Reports the closed native rows to the phone, and drops the copy of an episode that finished:
  /// the playback that used it has ended, and the phone records the finish. A finish the
  /// phone could not be told about keeps its journal row, which survives the copy. The phone's
  /// setting can keep the played copy on the Watch; an older phone sends nothing, and nil means on.
  func reportNativeProgress(removingFinished finished: WatchNativeSelection?, openRow: UUID?) async {
    // The row still being written stays out: it would report a position the next tick supersedes.
    await episodeSync.reportNativeProgress(excludingOpenRows: Set([openRow].compactMap { $0 }))
    guard let finished else { return }
    // A finished episode is never the one to resume, whether or not the setting keeps its copy.
    forgetNativeBookmark(finished)
    guard episodeSync.removesPlayedCopies else { return }
    await episodeSync.removeCopy(finished)
  }

  /// Stops whatever plays here before the phone starts `selection`, and returns the Watch's position
  /// when that is the native episode playing here. A native episode has no peer handoff, and a
  /// start the Watch commands asks the Watch nothing back, so the start command carries the position, and
  /// without it the phone would start from its own older row.
  func stopForPhoneStart(of selection: WatchSelection) async -> Double? {
    let handed =
      currentSelection == selection && WatchNativeSelection(selection) != nil ? audio.position : nil
    await stopPlayback(finished: false)
    guard let handed, handed.isFinite, handed >= 0 else { return nil }
    return handed
  }

  /// Removes a copy the listener asked to delete. A playback using it stops first, so its row and
  /// bookmark close before the file goes; a stop saves a bookmark at its own position, which is why
  /// the bookmark is forgotten after it.
  func removeNativeCopy(_ selection: WatchNativeSelection) async {
    if currentSelection == selection.selection {
      await stopPlayback(finished: false)
    }
    await episodeSync.removeCopy(selection)
    forgetNativeBookmark(selection)
  }

  /// A dropped copy cannot play, so its playback stops unfinished and its bookmark goes: the next
  /// resume would otherwise point at a file that is gone. The phone resends it if still wanted.
  func copiesDropped(_ dropped: [WatchNativeSelection]) {
    guard !dropped.isEmpty else { return }
    let playing = currentSelection.flatMap { WatchNativeSelection($0) }.map { dropped.contains($0) } ?? false
    let bookmarked = retainedSelection.flatMap { WatchNativeSelection($0) }.map { dropped.contains($0) } ?? false
    guard playing || bookmarked else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      // A stop saves a bookmark at its own position, so the bookmark is cleared after it.
      if playing { await self.stopPlayback(finished: false) }
      forgetNativeBookmark(dropped)
    }
  }

  /// The bookmark is only this episode's to forget when it names one of `selections`.
  private func forgetNativeBookmark(_ selections: [WatchNativeSelection]) {
    guard let retained = retainedSelection.flatMap({ WatchNativeSelection($0) }),
      selections.contains(retained)
    else { return }
    clearBookmark()
    retainedSelection = nil
    retainedPosition = 0
  }

  private func forgetNativeBookmark(_ selection: WatchNativeSelection) {
    forgetNativeBookmark([selection])
  }

  /// The entry's duration, or the file's own when the phone sent none. A copy of unknown length
  /// fails the start: its timeline could neither be scrubbed nor finished.
  private func duration(of entry: WatchReceivedEpisode, at fileURL: URL) async throws -> Double {
    if let duration = entry.duration, duration.isFinite, duration > 0 { return duration }
    let measured = try await AVURLAsset(url: fileURL).load(.duration).seconds
    guard measured.isFinite, measured > 0, measured <= WatchHandoffLimits.maxPositionSeconds else {
      throw WatchReceivedEpisodeStoreError.notPlayable
    }
    return measured
  }
}
