import Foundation
import WatchPlayback
import WatchProtocol

/// The decoded form of a task's `taskDescription`: the store entry's identifiers and revision,
/// never a URL, a title or the account.
nonisolated private struct WatchRSSTaskPayload: Codable {
  var selection: WatchNativeSelection
  var revision: UInt64
}

/// The Watch's own background `URLSession` for RSS enclosures, beside the Audiobookshelf session.
/// It sends no `Authorization` header, cookie, credential or cached response of any kind (ADR 0020
/// Decision 2), and it never follows a redirect through a delegate: a background session follows
/// redirects itself, so the chain is judged after completion from the task's metrics.
@MainActor
final class WatchRSSDownloadURLSessionAdapter: NSObject {
  /// Background sessions persist on the system by identifier, so the app's is fixed for its
  /// lifetime.
  nonisolated static let sessionIdentifier: String = {
    #if os(watchOS)
      let base = Bundle.main.bundleIdentifier ?? "com.remoteconcern.whirr.watchkitapp"
      return "\(base).rssEnclosures"
    #else
      return "com.remoteconcern.whirr.watch.rssEnclosures.host"
    #endif
  }()

  private nonisolated static let taskDescriptionPrefix = "whirr-watch-rss:"

  /// Read from the session queue, so it is not actor-isolated. Set once by the driver before any
  /// task starts, and the receiver is retained for the life of each delivered outcome.
  nonisolated(unsafe) weak var events: (any WatchRSSDownloadURLSessionEvents)?

  /// Two background sessions may never share one identifier in a process, and the Watch host
  /// harness builds several drivers.
  nonisolated private let identifier: String
  nonisolated private let staging: WatchRSSDownloadStaging
  nonisolated private let state = WatchRSSTransferState()
  nonisolated private let queue: OperationQueue
  private var session: URLSession?

  init(rootURL: URL) {
    staging = WatchRSSDownloadStaging(rootURL: rootURL)
    identifier = Self.makeIdentifier()
    let queue = OperationQueue()
    queue.name = "com.remoteconcern.whirr.watch-rss-session"
    // One serial delegate queue: every callback below sees one task's events in order.
    queue.maxConcurrentOperationCount = 1
    self.queue = queue
    super.init()
  }

  private nonisolated static func makeIdentifier() -> String {
    #if os(watchOS)
      return sessionIdentifier
    #else
      return "\(sessionIdentifier)-\(UUID().uuidString.lowercased())"
    #endif
  }

  // MARK: Tasks

  func downloadTask(with request: URLRequest) -> URLSessionDownloadTask {
    makeSession().downloadTask(with: request)
  }

  func allTasks() async -> [URLSessionTask] {
    await withCheckedContinuation { continuation in
      makeSession().getAllTasks { continuation.resume(returning: $0) }
    }
  }

  /// Cancels every live task without invalidating the session, which the driver keeps for the life
  /// of the app. A driver that never started a transfer has no session, and none is created here.
  func cancelAllTasks() async {
    guard let session else { return }
    let tasks: [URLSessionTask] = await withCheckedContinuation { continuation in
      session.getAllTasks { continuation.resume(returning: $0) }
    }
    for task in tasks { task.cancel() }
  }

  func discardStagedFile(_ url: URL?) {
    staging.discard(url)
  }

  // MARK: Background wake

  /// Called for a `WKURLSessionRefreshBackgroundTask` carrying this session's identifier. Recreating
  /// the session is what makes the system deliver the events that woke the app; `completion` runs
  /// once they are drained, or on a grace period when the session has nothing to deliver.
  func handleBackgroundEvents(completion: @escaping @Sendable () -> Void) {
    WatchRSSDiagnostics.log("bg_events_attach")
    state.addBackgroundCompletion(completion)
    let session = makeSession()
    let state = state
    session.getAllTasks { tasks in
      // A session with nothing left to deliver can stay silent, and the WatchKit task would then
      // wait for the system to expire it.
      guard tasks.isEmpty else { return }
      DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        let handlers = state.noteEventsFinished()
        WatchRSSDiagnostics.log("bg_events_grace", ["handlers": String(handlers.count)])
        for handler in handlers { handler() }
      }
    }
  }

  // MARK: Session

  /// Created on first use: a background session with one identifier must exist at most once in a
  /// process, and constructing the delegate before the account is restored must not create it.
  private func makeSession() -> URLSession {
    if let session { return session }
    staging.sweepUnclaimed()
    let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
    configuration.isDiscretionary = false
    configuration.sessionSendsLaunchEvents = true
    configuration.waitsForConnectivity = true
    // The session default is permissive because the download setting is decided per request, from
    // the store the account currently has; a stale session snapshot must not veto a request that
    // is allowed cellular. The relay path is marked both expensive and constrained, so refusing
    // those would stop every Wi-Fi download behind the paired iPhone.
    configuration.allowsCellularAccess = true
    configuration.allowsExpensiveNetworkAccess = true
    configuration.allowsConstrainedNetworkAccess = true
    // An enclosure fetch carries none of the Audiobookshelf session's state.
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let created = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    session = created
    WatchRSSDiagnostics.log("session_created", ["identifier": identifier])
    return created
  }

  // MARK: Task attribution

  /// `taskDescription` survives a relaunch, and holds only the entry's identifiers and revision.
  nonisolated static func taskDescription(for key: WatchRSSDownloadKey) -> String {
    let payload = WatchRSSTaskPayload(selection: key.selection, revision: key.revision)
    guard let data = try? JSONEncoder().encode(payload) else { return "" }
    return taskDescriptionPrefix + data.base64EncodedString()
  }

  nonisolated static func key(from taskDescription: String?) -> WatchRSSDownloadKey? {
    guard let taskDescription, taskDescription.hasPrefix(taskDescriptionPrefix),
      let data = Data(base64Encoded: String(taskDescription.dropFirst(taskDescriptionPrefix.count))),
      let payload = try? JSONDecoder().decode(WatchRSSTaskPayload.self, from: data)
    else { return nil }
    return WatchRSSDownloadKey(selection: payload.selection, revision: payload.revision)
  }

  nonisolated static func fileSize(at url: URL) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? NSNumber
    else { return nil }
    return size.int64Value
  }

  /// Hops to the main actor to deliver one outcome, then releases a WatchKit completion that was
  /// waiting for this task's durable work.
  private nonisolated func deliver(
    _ completion: WatchRSSDownloadCompletion?, token: WatchRSSCallbackToken, error: Error?,
    waitsForCallback: Bool
  ) {
    let receiver = events
    Task { @MainActor [self] in
      if let error {
        await receiver?.rssDidFail(token, error: error)
      } else if let receiver, let completion {
        await receiver.rssDidComplete(token, completion: completion)
      }
      if error != nil || receiver == nil, let url = completion?.stagedFileURL {
        staging.discard(url)
      }
      if waitsForCallback {
        for handler in state.endedCallback() { handler() }
      }
    }
  }
}

// URLSession calls these on the adapter's serial delegate queue.
nonisolated extension WatchRSSDownloadURLSessionAdapter: URLSessionDownloadDelegate {
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    guard let key = Self.key(from: downloadTask.taskDescription) else { return }
    #if DEBUG
      // At most one line per 5% of a transfer, so a fast download cannot flood the file.
      let fraction =
        totalBytesExpectedToWrite > 0
        ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : -1
      let identifier = downloadTask.taskIdentifier
      if state.admitsProgressLine(taskIdentifier: identifier, fraction: fraction) {
        WatchRSSDiagnostics.log(
          "progress", key, taskIdentifier: identifier,
          [
            "received": String(totalBytesWritten), "expected": String(totalBytesExpectedToWrite),
            "bytesWritten": String(bytesWritten),
          ])
      }
    #endif
    let token = WatchRSSCallbackToken(key: key, taskIdentifier: downloadTask.taskIdentifier)
    Task { @MainActor [weak self] in
      await self?.events?.rssDidWrite(
        token, totalBytesWritten: totalBytesWritten,
        totalBytesExpectedToWrite: totalBytesExpectedToWrite)
    }
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
  ) {
    guard Self.key(from: downloadTask.taskDescription) != nil else {
      try? FileManager.default.removeItem(at: location)
      return
    }
    // The system deletes `location` when this returns, so the file is moved before any hop. The
    // metrics for this task may arrive after this call, so the outcome is assembled in
    // `didCompleteWithError` from everything recorded here.
    let staged = staging.preserve(location, taskIdentifier: downloadTask.taskIdentifier)
    let response = downloadTask.response as? HTTPURLResponse
    let expected = response?.expectedContentLength ?? -1
    let finish = WatchRSSDownloadFinish(
      stagedFileURL: staged,
      measuredBytes: staged.flatMap(Self.fileSize(at:)),
      statusCode: response?.statusCode,
      expectedContentLength: expected > 0 ? expected : nil,
      contentRangeTotal: response?.value(forHTTPHeaderField: "Content-Range").flatMap(
        WatchEnclosureResponseCheck.contentRangeTotal(from:)))
    state.recordFinish(finish, taskIdentifier: downloadTask.taskIdentifier)
    WatchRSSDiagnostics.log(
      "download_file",
      [
        "taskIdentifier": String(downloadTask.taskIdentifier),
        "bytes": String(finish.measuredBytes ?? -1), "status": String(finish.statusCode ?? -1),
      ])
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    guard let key = Self.key(from: task.taskDescription) else {
      // A task this build cannot attribute is one it never resumed; nothing here can settle it.
      WatchRSSDiagnostics.log(
        "download_completed", ["taskIdentifier": String(task.taskIdentifier), "decoded": "no"])
      _ = state.take(taskIdentifier: task.taskIdentifier)
      return
    }
    let token = WatchRSSCallbackToken(key: key, taskIdentifier: task.taskIdentifier)
    let nsError = error as NSError?
    WatchRSSDiagnostics.log(
      "download_completed", token.key, taskIdentifier: task.taskIdentifier,
      [
        "error": error == nil ? "no" : "yes", "domain": nsError?.domain ?? "-",
        "code": String(nsError?.code ?? 0),
      ])
    let (finish, hops) = state.take(taskIdentifier: task.taskIdentifier)
    let waitsForCallback = finish != nil
    if let error {
      deliver(nil, token: token, error: error, waitsForCallback: waitsForCallback)
      // A file that arrived before the session gave up is not a copy the listener can play.
      staging.discard(finish?.stagedFileURL)
      return
    }
    let completion = WatchRSSDownloadCompletion(
      stagedFileURL: finish?.stagedFileURL,
      measuredBytes: finish?.measuredBytes,
      statusCode: finish?.statusCode ?? (task.response as? HTTPURLResponse)?.statusCode,
      expectedContentLength: finish?.expectedContentLength,
      contentRangeTotal: finish?.contentRangeTotal,
      hops: hops,
      requestedURL: task.originalRequest?.url)
    deliver(completion, token: token, error: nil, waitsForCallback: waitsForCallback)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    var hops: [URL] = []
    for transaction in metrics.transactionMetrics {
      if let url = transaction.request.url ?? transaction.response?.url { hops.append(url) }
    }
    state.recordHops(hops, taskIdentifier: task.taskIdentifier)
  }

  func urlSession(
    _ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask
  ) {
    guard let key = Self.key(from: task.taskDescription) else { return }
    let token = WatchRSSCallbackToken(key: key, taskIdentifier: task.taskIdentifier)
    Task { @MainActor [weak self] in
      await self?.events?.rssTaskIsWaitingForConnectivity(token)
    }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    let handlers = state.noteEventsFinished()
    WatchRSSDiagnostics.log("bg_events_finished", ["handlers": String(handlers.count)])
    for handler in handlers { handler() }
  }
}
