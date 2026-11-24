// Concatenated with the production manager and transport to exercise their private callback boundary.
private final class DownloadProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0
  private var hook: (@Sendable () -> Void)?
  func increment() { lock.withLock { value += 1 } }
  var count: Int { lock.withLock { value } }
  func observe(_ hook: @escaping @Sendable () -> Void) { lock.withLock { self.hook = hook } }
  func now() -> Date {
    lock.withLock { hook }?()
    return Date()
  }
}
private final class RegressionDownloadTask: URLSessionDownloadTask, @unchecked Sendable {
  var didCancel = false
  var responseStatus = 200
  /// The request URL the task reports; also the response URL unless a case sets `responseURL`.
  var url = URL(string: "https://example.invalid/api/items/book/file")!
  var responseURL: URL?
  override var response: URLResponse? {
    HTTPURLResponse(
      url: responseURL ?? url, statusCode: responseStatus,
      httpVersion: nil, headerFields: ["Content-Length": "4"])
  }
  override var originalRequest: URLRequest? { URLRequest(url: url) }
  override var currentRequest: URLRequest? { URLRequest(url: url) }
  override var taskIdentifier: Int { 7 }
  override func cancel() { didCancel = true }
}
extension WatchDownloadURLSessionAdapter {
  fileprivate var regressionCallbackState: WatchDownloadCallbackState { callbackState }

  fileprivate func finishForRegression(
    _ token: WatchDownloadCallbackToken, preservedURL: URL?, statusCode: Int?, responseBytes: Int64?
  ) async {
    await handleFinished(
      token, receiver: events, preservedURL: preservedURL, statusCode: statusCode, responseBytes: responseBytes)
  }
}
extension WatchDownloadManager {
  static func runDownloadRegressions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try WatchAccountStamp(accountIdentityHash: "a", serverIdentityHash: "s")
    let probe = DownloadProbe()
    let store = try WatchDownloadStore(rootURL: root, accountStamp: stamp, storageQuotaBytes: 100, now: { probe.now() })
    let renewals = DownloadProbe()
    let manager = WatchDownloadManager(
      store: store, accountStamp: stamp,
      requestProvider: { _ in URLRequest(url: URL(string: "https://example.invalid/api/items/book/file")!) },
      renewalProvider: { _ in
        renewals.increment()
        throw URLError(.userAuthenticationRequired)
      },
      rootURL: root, isWiFiAvailable: { true })
    manager.active = true
    let publications = DownloadProbe()
    var publishedDownloads: [WatchDownloadManifest] = []
    manager.onDownloadsChange = {
      publications.increment()
      publishedDownloads = $0
    }
    let id = UUID()
    _ = try await store.enqueue(
      selection: .audiobookshelf(itemID: "book", episodeID: nil), fileID: "file",
      expectedBytes: 4, expectedMIMEType: "audio/mpeg", id: id)
    _ = try await store.beginTransfer(id: id, isWiFiAvailable: true)
    let task = RegressionDownloadTask()
    manager.tasksByDownloadID[id] = task
    manager.taskGenerations[id] = 0
    let token = WatchDownloadCallbackToken(id: id, taskIdentifier: 7, generation: 0)
    _ = try await store.pause(id: id)
    await manager.didProgress(token, totalBytesWritten: 1, totalBytesExpectedToWrite: 4)
    let paused = await store.manifest(id: id)
    precondition(paused?.state == .paused, "late progress changed a paused download to failure")
    precondition(!task.didCancel)
    _ = try await store.resume(id: id)
    _ = try await store.beginTransfer(id: id, isWiFiAvailable: true)
    await manager.didProgress(token, totalBytesWritten: 5, totalBytesExpectedToWrite: 4)
    precondition(task.didCancel, "oversized response was left downloading")
    let failed = await store.manifest(id: id)
    precondition(failed?.failureReason == .validation, "oversized response was not durably failed")
    _ = try await store.retry(id: id)
    _ = try await store.beginTransfer(id: id, isWiFiAvailable: true)
    manager.tasksByDownloadID[id] = RegressionDownloadTask()
    manager.taskGenerations[id] = 0
    let file = root.appendingPathComponent("test.part")
    try Data([1, 2, 3, 4]).write(to: file)
    let state = manager.transport.regressionCallbackState
    manager.transport.regressionCallbackState.began(token)
    probe.observe { precondition(state.pending == 1, "background event finished before durable commit") }
    await manager.transport.finishForRegression(token, preservedURL: file, statusCode: 200, responseBytes: 4)
    precondition(state.pending == 0)
    let completed = await store.manifest(id: id)
    precondition(completed?.state == .completed)
    precondition(
      publishedDownloads == manager.downloads && publishedDownloads.first?.state == .completed,
      "download callback did not publish the committed manifests")
    probe.observe {}
    // A refused redirect reaches the manager as a finish with no status: the file is removed and
    // the row fails validation, which is also where a non-2xx response lands.
    let refusedID = UUID()
    _ = try await store.enqueue(
      selection: .audiobookshelf(itemID: "refused", episodeID: nil), fileID: "file",
      expectedBytes: 4, expectedMIMEType: "audio/mpeg", id: refusedID)
    _ = try await store.beginTransfer(id: refusedID, isWiFiAvailable: true)
    // Reuses the detached task from the completed case; the manager only needs its identifier here.
    manager.tasksByDownloadID[refusedID] = task
    manager.taskGenerations[refusedID] = 0
    let refusedToken = WatchDownloadCallbackToken(id: refusedID, taskIdentifier: 7, generation: 0)
    let refusedFile = root.appendingPathComponent("refused.part")
    try Data([1, 2, 3, 4]).write(to: refusedFile)
    state.began(refusedToken)
    await manager.transport.finishForRegression(
      refusedToken, preservedURL: refusedFile, statusCode: nil, responseBytes: 4)
    let refused = await store.manifest(id: refusedID)
    precondition(refused?.state == .failed && refused?.failureReason == .validation)
    precondition(manager.lastError == .unacceptableHTTPStatus(0))
    precondition(!FileManager.default.fileExists(atPath: refusedFile.path), "refused redirect kept its file")
    let retryID = UUID()
    _ = try await store.enqueue(
      selection: .audiobookshelf(itemID: "retry", episodeID: nil), fileID: "file",
      expectedBytes: 4, expectedMIMEType: "audio/mpeg", id: retryID)
    _ = try await store.beginTransfer(id: retryID, isWiFiAvailable: true)
    let retryToken = WatchDownloadCallbackToken(id: retryID, taskIdentifier: 7, generation: 0)
    for attempt in 0..<2 {
      if attempt > 0 {
        _ = try await store.retry(id: retryID)
        _ = try await store.beginTransfer(id: retryID, isWiFiAvailable: true)
      }
      manager.tasksByDownloadID[retryID] = RegressionDownloadTask()
      manager.taskGenerations[retryID] = 0
      let response = root.appendingPathComponent("unauthorized.part")
      try Data([1]).write(to: response)
      state.began(retryToken)
      await manager.transport.finishForRegression(retryToken, preservedURL: response, statusCode: 401, responseBytes: 1)
    }
    manager.tasksByDownloadID[retryID] = task
    manager.taskGenerations[retryID] = 0
    precondition(manager.callbackMatches(retryToken), "current callback fixture is not attached")
    let staleToken = WatchDownloadCallbackToken(id: retryID, taskIdentifier: 7, generation: -1)
    let wrongTaskToken = WatchDownloadCallbackToken(id: retryID, taskIdentifier: 8, generation: 0)
    let beforeStale = await store.manifest(id: retryID)
    for lateToken in [staleToken, wrongTaskToken] {
      let lateFile = root.appendingPathComponent("late.part")
      try Data([1, 2, 3, 4]).write(to: lateFile)
      state.began(lateToken)
      await manager.transport.finishForRegression(lateToken, preservedURL: lateFile, statusCode: 200, responseBytes: 4)
      await manager.didProgress(lateToken, totalBytesWritten: 4, totalBytesExpectedToWrite: 4)
      await manager.didFail(lateToken, error: URLError(.cancelled))
      precondition(!FileManager.default.fileExists(atPath: lateFile.path), "stale callback leaked its preserved file")
      let afterStale = await store.manifest(id: retryID)
      precondition(afterStale == beforeStale, "stale callback changed the current manifest")
      precondition(state.pending == 0, "stale callback remained pending")
    }
    precondition(renewals.count == 1, "media authorization renewed more than once")
    manager.renewedIDs.insert(id)
    manager.active = false
    await manager.redownload(id: id)
    precondition(!manager.renewedIDs.contains(id), "fresh redownload inherited the previous renewal limit")
    let completion = DownloadProbe()
    manager.handleBackgroundEvents { completion.increment() }
    await manager.stop()
    precondition(completion.count == 1, "stop dropped background completion")
    precondition(publications.count > 0 && publishedDownloads.isEmpty, "stop did not publish cleared downloads")
    await manager.stop()
    precondition(completion.count == 1, "completion called twice")
    print("watch download regressions passed")
  }
}
extension WatchDownloadManager {
  /// A Wi-Fi hold must stay escapable. Automatic admission still respects the signal, but an
  /// explicit retry bypasses it, because the signal is a guess about a path watchOS does not
  /// describe honestly and a retry gated on it can only reproduce the hold it is escaping.
  static func runWiFiAdmissionRegressions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try WatchAccountStamp(accountIdentityHash: "a", serverIdentityHash: "s")
    let store = try WatchDownloadStore(rootURL: root, accountStamp: stamp, storageQuotaBytes: 100)
    // The provider throws so admission is observable without resuming a real background task.
    let manager = WatchDownloadManager(
      store: store, accountStamp: stamp,
      requestProvider: { _ in throw URLError(.notConnectedToInternet) },
      rootURL: root, isWiFiAvailable: { false })
    manager.active = true
    let id = UUID()
    _ = try await store.enqueue(
      selection: .audiobookshelf(itemID: "book", episodeID: nil), fileID: "file",
      expectedBytes: 4, expectedMIMEType: "audio/mpeg", id: id)
    await manager.startDownload(id: id)
    let held = await store.manifest(id: id)
    precondition(
      held?.state == .queued && held?.failureReason == .waitingForWiFi,
      "automatic admission ignored the Wi-Fi policy")
    await manager.startDownload(id: id, userInitiated: true)
    let escaped = await store.manifest(id: id)
    precondition(
      escaped?.state != .queued && escaped?.failureReason != .waitingForWiFi,
      "an explicit retry re-ran the admission decision that produced the hold")
    // `retry` leaves only `failed`, so a paused row must be resumed instead of silently rejected.
    let pausedID = UUID()
    _ = try await store.enqueue(
      selection: .audiobookshelf(itemID: "paused", episodeID: nil), fileID: "file",
      expectedBytes: 4, expectedMIMEType: "audio/mpeg", id: pausedID)
    _ = try await store.beginTransfer(id: pausedID, isWiFiAvailable: true)
    _ = try await store.pause(id: pausedID)
    await manager.resume(id: pausedID)
    let resumed = await store.manifest(id: pausedID)
    precondition(resumed?.state != .paused, "a paused row could not be resumed")
    await manager.stop()
    print("watch download admission regressions passed")
  }
}

@main struct DownloadRegression {
  static func main() async throws {
    try await WatchDownloadManager.runDownloadRegressions()
    try await WatchDownloadManager.runWiFiAdmissionRegressions()
    try await WatchDownloadURLSessionAdapter.runTransportRegressions()
  }
}

@MainActor
private final class TransportLedger {
  var finished = 0
  var drained = 0
}

@MainActor
private final class DownloadTransportProbe: WatchDownloadURLSessionEvents {
  var ledger: TransportLedger?
  var finishedToken: WatchDownloadCallbackToken?
  var receivedBytes: Data?
  var progressCount = 0
  var failureCount = 0
  var drainedCount = 0
  var backgroundFinished = false

  func didProgress(
    _ token: WatchDownloadCallbackToken, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) async { progressCount += 1 }
  func didFinish(
    _ token: WatchDownloadCallbackToken, preservedURL: URL?, statusCode: Int?, responseBytes: Int64?
  ) async {
    precondition(statusCode == 200 && responseBytes == 4)
    receivedBytes = preservedURL.flatMap { try? Data(contentsOf: $0) }
    finishedToken = token
    ledger?.finished += 1
    if let preservedURL { try? FileManager.default.removeItem(at: preservedURL) }
  }
  func didFail(_ token: WatchDownloadCallbackToken, error: Error?) async { failureCount += 1 }
  func didRecoverTasks(_ tasks: [URLSessionDownloadTask], generation: Int) async {}
  func didFinishBackgroundEvents() { backgroundFinished = true }
  func didDrainCallbacks() {
    drainedCount += 1
    ledger?.drained += 1
  }
}

/// Accepts whatever status the adapter delivers. The double optional separates "no finish" from a
/// delivered `nil`, which is how a refused redirect reports that the file must not be committed.
@MainActor
private final class RedirectTransportProbe: WatchDownloadURLSessionEvents {
  var statusCode: Int??
  var handedOverFile: URL?
  var receivedBytes: Data?
  var drainedCount = 0

  func didProgress(
    _ token: WatchDownloadCallbackToken, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) async {}
  func didFinish(
    _ token: WatchDownloadCallbackToken, preservedURL: URL?, statusCode: Int?, responseBytes: Int64?
  ) async {
    self.statusCode = .some(statusCode)
    handedOverFile = preservedURL
    receivedBytes = preservedURL.flatMap { try? Data(contentsOf: $0) }
  }
  func didFail(_ token: WatchDownloadCallbackToken, error: Error?) async {}
  func didRecoverTasks(_ tasks: [URLSessionDownloadTask], generation: Int) async {}
  func didFinishBackgroundEvents() {}
  func didDrainCallbacks() { drainedCount += 1 }
}

extension WatchDownloadURLSessionAdapter {
  static func runTransportRegressions() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = WatchDownloadURLSessionAdapter(
      rootURL: root, accountIdentity: "account-server", identifier: UUID().uuidString, networkPolicy: .wifiOnly)
    defer { adapter.invalidateAndCancel() }
    let probe = DownloadTransportProbe()
    adapter.events = probe
    let id = UUID()
    let encoded = taskDescription(for: id, generation: 9)
    precondition(downloadID(from: encoded) == id && taskReference(from: encoded)?.generation == 9)
    precondition(downloadID(from: taskDescription(for: id)) == id)
    precondition(downloadID(from: encoded + ":extra") == nil)
    precondition(downloadID(from: "invalid") == nil)
    let source = URL(string: "https://example.invalid/base/api/items/book/file")!
    precondition(allowsRedirect(from: source, to: URL(string: "https://example.invalid/base/api/items/other/file")))
    for target in [
      "https://other.invalid/base/api/items/book/file", "http://example.invalid/base/api/items/book/file",
      "https://example.invalid/unrelated", "https://user@example.invalid/base/api/items/book/file",
    ] {
      precondition(!allowsRedirect(from: source, to: URL(string: target)))
    }
    precondition(acceptsFinalURL(source: nil, final: source), "a task without an original request was refused")
    precondition(acceptsFinalURL(source: source, final: nil), "a task without a final URL was refused")
    precondition(acceptsFinalURL(source: source, final: source), "an unredirected download was refused")
    precondition(
      acceptsFinalURL(source: source, final: URL(string: "https://example.invalid/base/api/items/other/file")),
      "a same-origin move under /api/items/ was refused")
    for target in [
      "https://other.invalid/base/api/items/book/file", "http://example.invalid/base/api/items/book/file",
      "https://example.invalid:8443/base/api/items/book/file", "https://example.invalid/unrelated",
      // Exact URL equality decides this first; the rule compares ports, so an explicit default
      // port is refused. Pinned so accepting it again is deliberate.
      "https://example.invalid:443/base/api/items/book/file",
    ] {
      precondition(!acceptsFinalURL(source: source, final: URL(string: target)), "accepted \(target)")
    }
    let configuration = makeBackgroundConfiguration(identifier: UUID().uuidString)
    precondition(!configuration.allowsCellularAccess && !configuration.httpShouldSetCookies)
    precondition(configuration.httpCookieStorage == nil && configuration.urlCredentialStorage == nil)
    precondition(configuration.urlCache == nil && configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    precondition(
      makeBackgroundConfiguration(identifier: UUID().uuidString, networkPolicy: .anyNetwork).allowsCellularAccess)

    let task = RegressionDownloadTask()
    task.taskDescription = encoded
    let location = root.appendingPathComponent("system-temporary.part")
    try Data([1, 2, 3, 4]).write(to: location)
    adapter.urlSession(.shared, downloadTask: task, didFinishDownloadingTo: location)
    precondition(
      !FileManager.default.fileExists(atPath: location.path), "delegate returned before moving the system file")
    precondition(
      adapter.pendingCallbacks == 1 && probe.finishedToken == nil,
      "handoff was not registered synchronously before the actor hop")
    await hostAwait(
      "the handoff to drain", observing: { "\(adapter.pendingCallbacks) pending" },
      until: {
        adapter.pendingCallbacks == 0
      })
    precondition(probe.finishedToken == WatchDownloadCallbackToken(id: id, taskIdentifier: 7, generation: 9))
    precondition(probe.receivedBytes == Data([1, 2, 3, 4]) && probe.drainedCount == 1)
    precondition(adapter.pendingCallbacks == 0)
    // A receiver whose last external owner goes away after the synchronous handoff still gets
    // the finished callback and the drain notification.
    let ledger = TransportLedger()
    do {
      let transient = DownloadTransportProbe()
      transient.ledger = ledger
      adapter.events = transient
      let secondLocation = root.appendingPathComponent("system-temporary-2.part")
      try Data([1, 2, 3, 4]).write(to: secondLocation)
      adapter.urlSession(.shared, downloadTask: task, didFinishDownloadingTo: secondLocation)
      precondition(adapter.pendingCallbacks == 1)
    }
    await hostAwait(
      "the released receiver's handoff to drain", observing: { "\(adapter.pendingCallbacks) pending" },
      until: {
        adapter.pendingCallbacks == 0
      })
    precondition(
      ledger.finished == 1 && ledger.drained == 1,
      "a receiver released after the handoff lost its finished callback")
    // A background session never calls willPerformHTTPRedirection, so the final URL is judged when
    // the download finishes. A cross-host response is still preserved for the manager and reported
    // without a status, which makes the manager delete it and fail the row.
    let redirectProbe = RedirectTransportProbe()
    adapter.events = redirectProbe
    task.url = URL(string: "https://example.invalid/base/api/items/book/file")!
    task.responseURL = URL(string: "https://other.invalid/steal/file")!
    let refusedLocation = root.appendingPathComponent("redirect-refused.part")
    try Data([1, 2, 3, 4]).write(to: refusedLocation)
    adapter.urlSession(.shared, downloadTask: task, didFinishDownloadingTo: refusedLocation)
    await hostAwait(
      "the refused redirect's handoff to drain", observing: { "\(adapter.pendingCallbacks) pending" },
      until: {
        adapter.pendingCallbacks == 0
      })
    precondition(redirectProbe.statusCode == .some(nil), "a cross-host response was reported as a valid download")
    precondition(
      redirectProbe.handedOverFile != nil && redirectProbe.receivedBytes == Data([1, 2, 3, 4]),
      "a refused redirect did not preserve its file for the manager to remove")
    precondition(redirectProbe.drainedCount == 1, "a refused redirect's handoff was not drained")
    if let file = redirectProbe.handedOverFile { try? FileManager.default.removeItem(at: file) }
    // A same-origin move inside /api/items/ is an accepted redirect, so its status passes through.
    redirectProbe.statusCode = nil
    redirectProbe.handedOverFile = nil
    redirectProbe.receivedBytes = nil
    redirectProbe.drainedCount = 0
    task.responseURL = URL(string: "https://example.invalid/base/api/items/other/file")!
    let acceptedLocation = root.appendingPathComponent("redirect-accepted.part")
    try Data([1, 2, 3, 4]).write(to: acceptedLocation)
    adapter.urlSession(.shared, downloadTask: task, didFinishDownloadingTo: acceptedLocation)
    await hostAwait(
      "the accepted redirect's handoff to drain", observing: { "\(adapter.pendingCallbacks) pending" },
      until: {
        adapter.pendingCallbacks == 0
      })
    precondition(redirectProbe.statusCode == .some(200), "a same-origin redirect under /api/items/ was refused")
    precondition(redirectProbe.drainedCount == 1, "an accepted redirect's handoff was not drained")
    if let file = redirectProbe.handedOverFile { try? FileManager.default.removeItem(at: file) }
    task.responseURL = nil
    adapter.events = probe
    adapter.urlSession(.shared, downloadTask: task, didWriteData: 4, totalBytesWritten: 4, totalBytesExpectedToWrite: 4)
    task.responseStatus = 401
    adapter.urlSession(.shared, downloadTask: task, didWriteData: 4, totalBytesWritten: 4, totalBytesExpectedToWrite: 4)
    adapter.urlSession(.shared, task: task, didCompleteWithError: URLError(.cancelled))
    adapter.urlSessionDidFinishEvents(forBackgroundURLSession: .shared)
    await hostAwait(
      "the progress, failure and background-finish callbacks",
      observing: {
        "progress \(probe.progressCount), failures \(probe.failureCount), finished \(probe.backgroundFinished)"
      }, until: { probe.progressCount == 1 && probe.failureCount == 1 && probe.backgroundFinished })
    precondition(probe.progressCount == 1, "HTTP error body was reported as download progress")
    precondition(probe.failureCount == 1 && probe.backgroundFinished)
    print("watch download transport regressions passed")
  }
}
