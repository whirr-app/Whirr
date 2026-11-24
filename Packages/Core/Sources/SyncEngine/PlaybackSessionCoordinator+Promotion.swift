import Foundation

extension PlaybackSessionCoordinator {
  /// The local and streamed timelines are built from different observations. A small amount of
  /// duration drift is harmless, but a larger disagreement means swapping the playhead could move
  /// the listener to a different point in the book.
  static let promotionDurationTolerance: TimeInterval = 2

  /// Whether a stream's playhead can move to the same offset in its local file. Each source picks
  /// its own `referenceDuration` for the stream.
  public static func promotionTimelinesAgree(
    localDuration: Double, referenceDuration: Double, position: Double
  ) -> Bool {
    localDuration.isFinite && referenceDuration.isFinite
      && abs(localDuration - referenceDuration) <= promotionDurationTolerance
      && position.isFinite && position >= 0
      && position <= localDuration + promotionDurationTolerance
  }

  /// `streamedDuration` is unused: the account-owned gate compares the local files with the server's
  /// own session timeline, which is authoritative for ABS, not with what the player has observed.
  public func promoteStreamingSessionToLocalDownload(
    itemID: String, episodeID: String?, currentPosition: Double, streamedDuration _: Double?
  ) async -> PreparedPlayback? {
    (try? await serialized {
      await self.performLocalPromotion(
        itemID: itemID, episodeID: episodeID, currentPosition: currentPosition)
    }) ?? nil
  }

  private func performLocalPromotion(
    itemID: String, episodeID: String?, currentPosition: Double
  ) async -> PreparedPlayback? {
    guard isQuiescedForLogout == false,
      let activePlaybackItem,
      activePlaybackItem.itemID == itemID,
      activePlaybackItem.episodeID == episodeID
    else { return nil }

    guard
      let accountRecord = try? await accountDAO.fetchAsync(),
      let accountId = accountRecord.id,
      let activeSession = try? await sessionStore.fetchActiveSessionAsync(accountId: accountId),
      activeSession.closePending == false,
      activeSession.isOffline == false,
      activeSession.itemId == activePlaybackItem.itemRowId,
      activeSession.podcastEpisodeId == activePlaybackItem.episodeRowId,
      let sessionId = activeSession.id,
      let streamedPrepared = preparedBySessionID[sessionId],
      streamedPrepared.itemID == itemID,
      streamedPrepared.episodeID == episodeID,
      streamedPrepared.source == .streaming
    else { return nil }

    let localMaterial: LocalSourceMaterial
    do {
      // Runs twice: once as the promotion gate and once inside `performStart`. Duplicating
      // `performStart`'s session bookkeeping to skip the second integrity validation would be
      // riskier than one extra per-item sweep.
      guard
        case .local(let material) = try await resolveSource(
          accountId: accountId,
          itemID: itemID,
          itemRowId: activePlaybackItem.itemRowId,
          episodeRowId: activePlaybackItem.episodeRowId
        )
      else { return nil }
      localMaterial = material
    } catch {
      return nil
    }

    guard
      let streamedDuration = streamedPrepared.duration,
      Self.promotionTimelinesAgree(
        localDuration: localMaterial.duration, referenceDuration: streamedDuration,
        position: currentPosition)
    else { return nil }

    flushPendingProgressTick()
    let persisted = persistTick(
      itemID: itemID,
      episodeID: episodeID,
      currentTime: currentPosition,
      listenedDelta: 0,
      isFinished: false,
      isSeek: false)
    guard
      persisted.outcome == .persisted(.cachedOnline)
        || persisted.outcome == .persisted(.online)
    else { return nil }

    let epoch = phaseNotificationEpoch
    let cadenceBeforePromotion = cadencePhase
    guard let prepared = try? await performStart(itemID: itemID, episodeID: episodeID) else {
      return nil
    }
    guard prepared.source == .local else { return nil }

    // `performStart` resets cadence while it closes the streaming session. Restore the prior
    // phase, not a hardcoded `.playing` as the reopen paths do: promotion is equally legal while
    // paused, and `.playing` would keep the periodic deadline alive and stop the next
    // backgrounding closing the fresh session (`closesWhenBackgrounded`). A phase notification
    // that arrived during the promotion owns the result.
    if phaseNotificationEpoch == epoch {
      cadencePhase = cadenceBeforePromotion
      if cadenceBeforePromotion == .playing {
        await scheduleNextPeriodicDrain()
      }
    }
    return prepared
  }
}
