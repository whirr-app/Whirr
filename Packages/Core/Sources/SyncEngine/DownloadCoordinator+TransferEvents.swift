import ABSApi
import Foundation
import Persistence

/// Transfer-event application: each adapter event becomes durable row state, then exactly one
/// trailing schedule so the freed slot is refilled once the event has fully landed.
extension DownloadCoordinator {
  func trace(_ downloadId: Int64, _ event: DownloadDeviceTrace.TransferEvent) {
    emitDeviceTraceRecord(.transfer(DownloadDeviceTrace.Transfer(downloadId: downloadId, event: event)))
  }

  func rssTrace(_ downloadId: Int64, _ event: DownloadDeviceTrace.TransferEvent) {
    emitDeviceTraceRecord(.rssTransfer(DownloadDeviceTrace.Transfer(downloadId: downloadId, event: event)))
  }

  // MARK: - Transfer events

  func handleTransferEvent(_ event: BackgroundTransferEvent) async {
    guard subscriptionsTornDown == false else { return }
    switch event {
    case .progress(let identity, let receivedBytes, let expectedBytes):
      await applyProgress(
        identity, receivedBytes: receivedBytes, expectedBytes: expectedBytes)
    case .finished(let identity, let temporaryFileURL, let response):
      await applyFinished(identity, temporaryFileURL: temporaryFileURL, response: response)
    case .failed(let identity, let errorDomain, let errorCode):
      await applyFailed(identity, errorDomain: errorDomain, errorCode: errorCode)
    case .authChallenge(let identity):
      switch identity {
      case .abs(let downloadId): await handleAuthChallenge(downloadId: downloadId)
      case .rss(let downloadId): await handleRSSAuthChallenge(downloadId: downloadId)
      }
    }
  }

  private func applyProgress(
    _ identity: TransferIdentity, receivedBytes: Int64, expectedBytes: Int64?
  ) async {
    switch identity {
    case .abs(let downloadId):
      _ = try? await downloadStore.updateProgressAsync(downloadId: downloadId, receivedBytes: receivedBytes)
      if case .trace(let percent) = progressTraceThrottle.decision(
        downloadId: downloadId, receivedBytes: receivedBytes, expectedBytes: expectedBytes)
      {
        emitDeviceTraceRecord(
          .progress(
            DownloadDeviceTrace.Progress(downloadId: downloadId, receivedBytes: receivedBytes, percent: percent)))
      }
    case .rss(let downloadId):
      // Forwarded because an RSS row may have no size (`<enclosure length>` is optional); the
      // store treats it as a backfill.
      _ = try? await rssDownloadStore?.updateProgressAsync(
        downloadId: downloadId, actualBytes: receivedBytes, expectedBytes: expectedBytes)
    }
  }

  private func applyFinished(
    _ identity: TransferIdentity, temporaryFileURL: URL, response: BackgroundTransferResponse
  ) async {
    var shouldScheduleAfterFinish = true
    _ = try? await onChain { [self] in
      await self.reattachInterruptedFinish(identity)
    }
    switch identity {
    case .abs(let downloadId):
      await completeABSFinish(
        downloadId, temporaryFileURL: temporaryFileURL, response: response)
    case .rss(let downloadId):
      rssLiveTaskOwnedDownloadIds.remove(downloadId)
      rssSuspendedTaskDownloadIds.remove(downloadId)
      guard let rssFileStore else {
        await backgroundTransferring.acknowledgeFinish(identity: identity)
        return
      }
      shouldScheduleAfterFinish = await completeRSSFinish(
        downloadId, temporaryFileURL: temporaryFileURL, response: response, fileStore: rssFileStore)
    }
    // A non-2xx answer has failed the row as `.validation`; the retry policy decides from the
    // status whether a briefly unavailable server earns an automatic retry.
    if (200...299).contains(response.httpStatusCode) == false {
      await armAutomaticRetry(identity, failure: .httpStatus(response.httpStatusCode))
    }
    await backgroundTransferring.acknowledgeFinish(identity: identity)
    if shouldScheduleAfterFinish { await schedule() }
  }

  private func completeABSFinish(
    _ downloadId: Int64, temporaryFileURL: URL, response: BackgroundTransferResponse
  ) async {
    authRetriedDownloadIds.remove(downloadId)
    liveTaskOwnedDownloadIds.remove(downloadId)
    suspendedTaskDownloadIds.remove(downloadId)
    progressTraceThrottle.forget(downloadId: downloadId)
    let mapped = DownloadTransferResponse(
      httpStatusCode: response.httpStatusCode, mimeType: response.mimeType, contentLength: response.contentLength,
      contentRange: response.contentRange)
    do {
      _ = try downloadFileStore.completeTransfer(
        downloadId: downloadId, temporaryFileURL: temporaryFileURL, response: mapped)
      trace(downloadId, .finish(.stored))
    } catch let failure as DownloadCompletionFailure where failure.category == .lowDisk {
      // The row stays retryable; one reactive write failure pauses the shared queue before
      // another source can start.
      trace(downloadId, .finish(.lowDisk))
      queuePauseReason = .lowDisk
    } catch let failure as DownloadCompletionFailure {
      trace(downloadId, .finish(.rejected(failure.category, failure.validationReason)))
    } catch {
      // The store failed before it could fail the row itself. The transfer is over, so a row
      // left `.downloading` would hold a slot until relaunch. Only that state is failed: a
      // duplicate finish must not fail a row that already completed.
      if (try? await downloadStore.fetchAsync(downloadId: downloadId))?.state == .downloading {
        _ = try? await downloadStore.transitionAsync(
          downloadId: downloadId, to: .failed, errorCategory: .storage)
      }
      trace(downloadId, .finish(.rejected(.unknown)))
    }
  }

  /// Returns whether the trailing schedule should run: only a low-disk write failure suppresses
  /// it, because that pause must not be undone by a pass that would start another transfer.
  private func completeRSSFinish(
    _ downloadId: Int64, temporaryFileURL: URL, response: BackgroundTransferResponse,
    fileStore: RSSFileStore
  ) async -> Bool {
    do {
      _ = try fileStore.completeTransfer(
        downloadId: downloadId, temporaryFileURL: temporaryFileURL,
        response: DownloadTransferResponse(
          httpStatusCode: response.httpStatusCode, mimeType: response.mimeType,
          contentLength: response.contentLength, contentRange: response.contentRange))
      rssTrace(downloadId, .finish(.stored))
    } catch let failure as DownloadCompletionFailure where failure.category == .lowDisk {
      rssTrace(downloadId, .finish(.lowDisk))
      queuePauseReason = .lowDisk
      return false
    } catch let error as RSSFileStoreError {
      // The store has already failed the row with the matching category. Only the closed
      // reason crosses into the trace; the row id is the sole identifier, never the feed.
      if let rejection = error.rejection {
        rssTrace(downloadId, .finish(.rssRejected(error.errorCategory, rejection)))
      } else {
        rssTrace(downloadId, .finish(.rejected(.unknown)))
      }
    } catch {
      // Anything else escaped the store before it could fail the row (a database or
      // filesystem error around the validated file), so fail it as a storage problem.
      _ = try? await rssDownloadStore?.transitionAsync(downloadId: downloadId, to: .failed, errorCode: .storage)
      rssTrace(downloadId, .finish(.rejected(.storage)))
    }
    return true
  }

  private func applyFailed(
    _ identity: TransferIdentity, errorDomain: String?, errorCode: Int?
  ) async {
    switch identity {
    case .abs(let downloadId):
      authRetriedDownloadIds.remove(downloadId)
      liveTaskOwnedDownloadIds.remove(downloadId)
      suspendedTaskDownloadIds.remove(downloadId)
      progressTraceThrottle.forget(downloadId: downloadId)
      trace(downloadId, .finish(.failed(errorDomain: errorDomain, errorCode: errorCode)))
      if (try? await downloadStore.transitionAsync(downloadId: downloadId, to: .failed, errorCategory: .transport))
        != nil
      {
        eventFailedDownloadIds.insert(downloadId)
        await armAutomaticRetry(identity, failure: .transfer(domain: errorDomain, code: errorCode))
      }
    case .rss(let downloadId):
      rssLiveTaskOwnedDownloadIds.remove(downloadId)
      rssSuspendedTaskDownloadIds.remove(downloadId)
      rssTrace(downloadId, .finish(.failed(errorDomain: errorDomain, errorCode: errorCode)))
      if (try? await rssDownloadStore?.transitionAsync(downloadId: downloadId, to: .failed, errorCode: .transport))
        != nil
      {
        rssEventFailedDownloadIds.insert(downloadId)
        await armAutomaticRetry(identity, failure: .transfer(domain: errorDomain, code: errorCode))
      }
    }
    await schedule()
  }

  /// A finish buffered across a relaunch can be handled before launch reconcile, when the fresh
  /// store has already rewritten its row `.downloading -> .interrupted` and `complete` would refuse
  /// it. Runs on the chain, so reconcile cannot requeue the row between this and the completion.
  private func reattachInterruptedFinish(_ identity: TransferIdentity) async {
    switch identity {
    case .abs(let downloadId):
      guard (try? await downloadStore.fetchAsync(downloadId: downloadId))?.state == .interrupted
      else { return }
      if (try? await downloadStore.transitionAsync(downloadId: downloadId, to: .pending)) != nil {
        eventFailedDownloadIds.remove(downloadId)
        _ = try? await downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)
      }
    case .rss(let downloadId):
      guard let rssDownloadStore,
        (try? await rssDownloadStore.fetchAsync(downloadId: downloadId))?.state == .interrupted
      else { return }
      if (try? await rssDownloadStore.transitionAsync(downloadId: downloadId, to: .pending)) != nil {
        rssEventFailedDownloadIds.remove(downloadId)
        _ = try? await rssDownloadStore.transitionAsync(downloadId: downloadId, to: .downloading)
      }
    }
  }

  // MARK: - Auth challenges

  /// One renewed request, then durable `pausedAuth` on repeated failure. The row stays
  /// `.downloading` through a successful renewal: there is no legal `.pausedAuth` -> `.downloading`
  /// edge, so a transient pause would strand it.
  private func handleAuthChallenge(downloadId: Int64) async {
    guard let row = try? await downloadStore.fetchAsync(downloadId: downloadId), row.state == .downloading
    else { return }
    guard let accountRecord = try? await accountDAO.fetchAsync(), let account = try? tokenAccount(for: accountRecord)
    else { return }

    guard authRetriedDownloadIds.contains(downloadId) == false else {
      // Second consecutive challenge: durable pausedAuth, awaiting user action. Never loop on
      // refresh.
      authRetriedDownloadIds.remove(downloadId)
      _ = try? await downloadStore.transitionAsync(downloadId: downloadId, to: .pausedAuth)
      trace(downloadId, .finish(.authPaused))
      await recordDownloadDiagnostic(accountId: accountRecord.id ?? 0, statusClass: .clientError)
      await schedule()
      return
    }

    authRetriedDownloadIds.insert(downloadId)
    guard let itemRecord = try? await itemDAO.fetchOneAsync(id: row.itemId) else {
      _ = try? await downloadStore.transitionAsync(downloadId: downloadId, to: .pausedAuth)
      trace(downloadId, .finish(.authPaused))
      return
    }

    let renewed: AuthorizedTransferRequest
    do {
      renewed = try await makeAuthorizedTransferRequest(
        for: row, itemID: itemRecord.serverItemId, account: account, renewing: true)
    } catch let error as APIError where error == .unauthorized {
      // Only the server actually rejecting the credential earns `.pausedAuth`, which is durable
      // and cleared solely by the user signing in again. A dropped connection must never cause it.
      authRetriedDownloadIds.remove(downloadId)
      _ = try? await downloadStore.transitionAsync(downloadId: downloadId, to: .pausedAuth)
      trace(downloadId, .finish(.authPaused))
      await schedule()
      return
    } catch {
      // Anything else (transport, rate limiting, a 5xx, an undecodable 2xx, a 403) says nothing
      // about the credential, so the row stays retryable and the queue keeps moving.
      authRetriedDownloadIds.remove(downloadId)
      _ = try? await downloadStore.transitionAsync(
        downloadId: downloadId, to: .failed, errorCategory: .transport)
      trace(downloadId, .finish(.failed(errorDomain: "renewal", errorCode: nil)))
      await armAutomaticRetry(.abs(rowID: downloadId), failure: .renewal)
      await schedule()
      return
    }

    await enqueueAuthorizedTransfer(renewed, for: row, downloadId: downloadId)
  }

  /// RSS credentials belong to the feed origin, not the ABS account, so a 401 becomes a durable
  /// RSS auth hold immediately. Never asks `ABSClient` to refresh and is not covered by
  /// `handleSuccessfulReauthentication()`.
  private func handleRSSAuthChallenge(downloadId: Int64) async {
    guard let rssDownloadStore,
      let row = try? await rssDownloadStore.fetchAsync(downloadId: downloadId),
      row.state == .downloading
    else { return }
    rssLiveTaskOwnedDownloadIds.remove(downloadId)
    _ = try? await rssDownloadStore.transitionAsync(
      downloadId: downloadId, to: .pausedAuth, holdReason: .feedCredentials,
      errorCode: .auth)
    rssTrace(downloadId, .finish(.authPaused))
    // Release the global slot now so an unrelated ABS or RSS row can make progress.
    await schedule()
  }
}
