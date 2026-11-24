import Foundation
import Observation
import PlayerCore
import WatchPlayback
import WatchProtocol

/// Recovery, the transport's callbacks, and the failures they record.
extension WatchDownloadManager: WatchDownloadURLSessionEvents {
  func didRecoverTasks(_ tasks: [URLSessionDownloadTask], generation: Int) async {
    var adoptedIDs: Set<UUID> = []
    for task in tasks {
      guard let id = WatchDownloadURLSessionAdapter.downloadID(from: task.taskDescription),
        let manifest = await store.manifest(id: id),
        manifest.accountStamp == accountStamp,
        manifest.state == .downloading || manifest.state == .queued
      else {
        task.cancel()
        continue
      }
      guard isCurrent(generation) else { return }
      task.taskDescription = WatchDownloadURLSessionAdapter.taskDescription(for: id, generation: generation)
      tasksByDownloadID[id] = task
      taskGenerations[id] = generation
      adoptedIDs.insert(id)
      _ = try? await store.attachTransfer(taskIdentifier: String(task.taskIdentifier), to: id)
    }
    guard isCurrent(generation) else { return }
    for manifest in await store.allManifests() where manifest.state == .downloading {
      guard adoptedIDs.contains(manifest.id) else {
        // Its finish callback is waiting for recovery to end and will commit the preserved file.
        if transport.hasPendingCallback(forDownloadID: manifest.id) { continue }
        await fail(manifest.id, .interrupted)
        continue
      }
    }
  }
  func finishRecovery() {
    recoveryPending = false
    let waiters = recoveryWaiters
    recoveryWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }
  /// A task that finished while the app was not running is not in the recovered map, and its
  /// token carries the previous launch's generation. Such an event is still ours when the durable
  /// row is downloading under exactly that system task.
  private func acceptsEarlyEvent(_ token: WatchDownloadCallbackToken) async -> Bool {
    guard active, let manifest = await store.manifest(id: token.id),
      manifest.accountStamp == accountStamp, manifest.state == .downloading,
      manifest.transferTaskIdentifier == String(token.taskIdentifier)
    else { return false }
    return true
  }
  /// Recovery marks a downloading row `.interrupted` when no live task or pending callback claims
  /// it, but a finish callback can be delivered after that check and still carry the complete
  /// file. Requeue the row so the file is committed rather than discarded.
  private func reclaimInterrupted(_ token: WatchDownloadCallbackToken) async -> Bool {
    guard active, tasksByDownloadID[token.id] == nil,
      let manifest = await store.manifest(id: token.id),
      manifest.accountStamp == accountStamp, manifest.state == .failed,
      manifest.failureReason == .interrupted
    else { return false }
    return (try? await store.retry(id: token.id)) != nil
  }
  private static func resumeData(from error: Error?) -> Data? {
    (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
  }
  /// Replaces a failed task with one continuing from its resume data. The data stays in memory;
  /// nothing persisted changes. Returns false when the caller should fail the download.
  private func continueFromResumeData(_ token: WatchDownloadCallbackToken, data: Data) async -> Bool {
    guard callbackMatches(token),
      let manifest = await store.manifest(id: token.id), manifest.state == .downloading
    else { return false }
    let task = transport.downloadTask(withResumeData: data)
    task.taskDescription = WatchDownloadURLSessionAdapter.taskDescription(
      for: token.id, generation: token.generation)
    do {
      _ = try await store.attachTransfer(taskIdentifier: String(task.taskIdentifier), to: token.id)
    } catch {
      task.cancel()
      return false
    }
    // The person may have paused, cancelled or deleted while the store call was suspended; their
    // action already settled the row, so there is nothing left to fail.
    guard callbackMatches(token) else {
      task.cancel()
      return true
    }
    tasksByDownloadID[token.id] = task
    taskGenerations[token.id] = token.generation
    task.resume()
    return true
  }
  func completeBackgroundEventsIfReady() {
    guard backgroundEventsFinished, transport.pendingCallbacks == 0 else { return }
    let handlers = backgroundCompletionHandlers
    backgroundCompletionHandlers.removeAll()
    for handler in handlers { handler() }
  }
  func didProgress(
    _ token: WatchDownloadCallbackToken,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) async {
    guard callbackMatches(token) else { return }
    do {
      let updated = try await store.recordTransferProgress(
        WatchDownloadTransferUpdate(
          receivedBytes: totalBytesWritten,
          expectedBytes: totalBytesExpectedToWrite < 0 ? nil : totalBytesExpectedToWrite), for: token.id)
      publishProgress(updated)
    } catch {
      switch error as? WatchDownloadStoreError {
      case .illegalTransition, .notFound: return
      default: break
      }
      guard callbackMatches(token), !transport.hasPendingCallback(token) else { return }
      tasksByDownloadID.removeValue(forKey: token.id)?.cancel()
      taskGenerations.removeValue(forKey: token.id)
      await fail(token.id, .validation)
      guard isCurrent(token.generation) else { return }
      lastError = .store(Self.storeError(from: error))
      await refresh()
    }
  }
  func didFinish(
    _ token: WatchDownloadCallbackToken,
    preservedURL: URL?, statusCode: Int?, responseBytes: Int64?
  ) async {
    let arrivedEarly = recoveryPending
    if arrivedEarly {
      await withCheckedContinuation { recoveryWaiters.append($0) }
    }
    var accepted = callbackMatches(token)
    if !accepted, arrivedEarly { accepted = await acceptsEarlyEvent(token) }
    if !accepted, preservedURL != nil { accepted = await reclaimInterrupted(token) }
    guard accepted else {
      // No row changes here, so a row left downloading by a lost finish is only visible in this log.
      WatchDiagnostics.record(.downloadFinishDropped)
      if let preservedURL { try? FileManager.default.removeItem(at: preservedURL) }
      completeBackgroundEventsIfReady()
      return
    }
    guard let preservedURL else {
      await fail(token.id, .storage)
      tasksByDownloadID.removeValue(forKey: token.id)
      taskGenerations.removeValue(forKey: token.id)
      lastError = .store(.storageFailure)
      await refresh()
      completeBackgroundEventsIfReady()
      return
    }
    tasksByDownloadID.removeValue(forKey: token.id)
    taskGenerations.removeValue(forKey: token.id)
    guard let statusCode, (200..<300).contains(statusCode) else {
      try? FileManager.default.removeItem(at: preservedURL)
      WatchDiagnostics.record(.downloadHTTPStatus, code: statusCode ?? 0)
      await fail(token.id, statusCode == 401 ? .unauthorized : .validation)
      if statusCode == 401, renewalProvider != nil, isCurrent(token.generation),
        renewedIDs.insert(token.id).inserted
      {
        do {
          _ = try await store.retry(id: token.id)
          await startDownload(id: token.id, renewAuthorization: true)
        } catch { lastError = .store(Self.storeError(from: error)) }
        return
      }
      lastError = .unacceptableHTTPStatus(statusCode ?? 0)
      await refresh()
      completeBackgroundEventsIfReady()
      return
    }
    do {
      _ = try await store.commitDownloadedTemporaryFile(
        preservedURL, for: token.id, responseBytes: responseBytes)
      WatchDiagnostics.record(.downloadCompleted)
      if isCurrent(token.generation) { lastError = nil }
      await refresh()
    } catch {
      try? FileManager.default.removeItem(at: preservedURL)
      await fail(token.id, .validation)
      lastError = .store(Self.storeError(from: error))
      await refresh()
    }
    completeBackgroundEventsIfReady()
  }
  func didFail(_ token: WatchDownloadCallbackToken, error: Error?) async {
    guard error != nil else { return }
    let arrivedEarly = recoveryPending
    if arrivedEarly {
      await withCheckedContinuation { recoveryWaiters.append($0) }
    }
    guard active else { return }
    var accepted = callbackMatches(token)
    if !accepted, arrivedEarly { accepted = await acceptsEarlyEvent(token) }
    guard accepted else {
      WatchDiagnostics.record(.downloadFailureDropped)
      return
    }
    guard transport.hasPendingCallback(token) == false else { return }
    guard await store.manifest(id: token.id) != nil else { return }
    if let data = Self.resumeData(from: error), resumeAttemptedIDs.insert(token.id).inserted,
      await continueFromResumeData(token, data: data)
    {
      return
    }
    if let error { WatchDiagnostics.record(.downloadTransportError, code: (error as NSError).code) }
    await fail(token.id, .transport)
    tasksByDownloadID.removeValue(forKey: token.id)
    taskGenerations.removeValue(forKey: token.id)
    lastError = .requestProvider
    await refresh()
  }
  func didFinishBackgroundEvents() {
    backgroundEventsFinished = true
    completeBackgroundEventsIfReady()
  }
  func didDrainCallbacks() { completeBackgroundEventsIfReady() }
  /// Fails the row and says why in the log, which the row's "Failed" does not.
  func fail(_ id: UUID, _ reason: WatchDownloadFailureReason) async {
    _ = try? await store.fail(id: id, reason: reason)
    WatchDiagnostics.record(Self.failureEvent(reason))
  }
  private static func failureEvent(_ reason: WatchDownloadFailureReason) -> WatchDiagnostics.Event {
    switch reason {
    case .interrupted: .downloadFailedInterrupted
    case .transport: .downloadFailedTransport
    case .unauthorized: .downloadFailedUnauthorized
    case .validation: .downloadFailedValidation
    case .storage: .downloadFailedStorage
    case .waitingForWiFi, .cancelled, .quota: .downloadFailedOther
    }
  }
  static func storeError(from error: Error) -> WatchDownloadStoreError {
    (error as? WatchDownloadStoreError) ?? .storageFailure
  }
}
