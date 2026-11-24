import ABSApi
import Foundation
import PodcastFeeds
import SyncEngine

/// The App's background `URLSession` adapter (see `ARCHITECTURE.md`): executes already-authorized
/// requests minted by ABSApi, reports durable state to SyncEngine through `BackgroundTransferring`,
/// and never stores a token (the one-shot `URLRequest` given to the session at `enqueue` is not
/// retained; `BackgroundDownloadAdapterTests`' reflection canary pins this).
///
/// Delegate-only: the async `URLSession` surface crashes on a background-configured session, so
/// every event is a translated `URLSessionDownloadDelegate` callback, in plain `handle*` methods
/// keyed by `TransferIdentity` (from `taskDescription`, set at `enqueue`) so tests need no task.
///
/// `nonisolated final class ... @unchecked Sendable`, lock-guarded, like
/// `CoreSupport.AsyncEventMulticaster`: callbacks arrive on a non-main serial queue and an `actor`
/// cannot be the `NSObject` delegate. `nonisolated` on the type lifts the target's default
/// main-actor isolation from every member.
nonisolated final class BackgroundDownloadSessionAdapter: NSObject, BackgroundTransferring, @unchecked Sendable {
  private struct ProgressState {
    var receivedBytes: Int64
    var expectedBytes: Int64?
    var lastEmittedAt: TimeInterval?
    var lastEmittedBytes: Int64?
  }

  private static let progressEmissionInterval: TimeInterval = 0.25
  private static let missingDestinationErrorDomain = "whirr.adapter.missingDestination"
  private static let moveFailedErrorDomain = "whirr.adapter.moveFailed"
  private static let overrunErrorDomain = "whirr.adapter.overrun"
  private static let redirectDeniedErrorDomain = "whirr.adapter.redirectDenied"
  private static let overrunMarginBytes: Int64 = 1_048_576
  /// The absolute per-transfer cap for every feed enclosure, mirrored from `RSSFileStore` so the
  /// in-flight bound and the completion bound cannot disagree (Persistence is not imported here).
  static let feedSizeCapBytes: Int64 = 1_073_741_824

  private enum ProgressDecision {
    case allowed
    case overrun
    case alreadyOverrun
  }

  let sessionIdentifier: String

  private let fileMover: BackgroundDownloadFileMoving
  private let progressNow: @Sendable () -> TimeInterval
  private let mainQueueDispatch: @Sendable (@escaping @Sendable () -> Void) -> Void

  /// Everything the adapter remembers about one transfer. One record, so enqueue, reattach,
  /// progress and teardown each touch one dictionary key and no fact can be stranded by a
  /// teardown that forgot its own parallel dictionary.
  private struct TaskState {
    var task: BackgroundDownloadTaskHandle?
    var destinationURL: URL?
    var byteLimit: Int64?
    var progress: ProgressState?
    var overrun = false
    var redirectDenied = false
    var redirectPolicy: TransferRedirectPolicy = .abs
    var redirectHop = 0
  }

  private let lock = NSLock()
  private var session: BackgroundDownloadSessionProviding!
  private var stateByIdentity: [TransferIdentity: TaskState] = [:]
  private var launchEventsCompletionHandler: (@Sendable () -> Void)?
  /// Finished transfers yielded on `events` and not yet acknowledged by a coordinator. The file is
  /// already at its destination, so launch reconciliation reattaches these rows instead of
  /// requeuing them, and a background-session wake waits for this to empty before completing.
  private var undeliveredFinishIdentities: Set<TransferIdentity> = []
  /// How many times the session has reported `urlSessionDidFinishEvents` in this process. The
  /// SwiftUI wake route has no stored handler; it compares this against a baseline to learn that
  /// the session has handed over every event of its wake.
  private var finishedSessionEventsCount = 0

  let events: AsyncStream<BackgroundTransferEvent>
  private let eventsContinuation: AsyncStream<BackgroundTransferEvent>.Continuation

  init(
    sessionIdentifier: String,
    fileMover: BackgroundDownloadFileMoving,
    sessionFactory: BackgroundDownloadSessionFactory,
    progressNow: @escaping @Sendable () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    },
    mainQueueDispatch: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = {
      DispatchQueue.main.async(execute: $0)
    }
  ) {
    self.sessionIdentifier = sessionIdentifier
    self.fileMover = fileMover
    self.progressNow = progressNow
    self.mainQueueDispatch = mainQueueDispatch
    var continuation: AsyncStream<BackgroundTransferEvent>.Continuation!
    events = AsyncStream { continuation = $0 }
    eventsContinuation = continuation
    super.init()
    // `self` is only usable as the delegate argument once every stored property above is set,
    // so `session` is constructed last, after `super.init()`.
    session = sessionFactory(sessionIdentifier, self, nil)
    reattachExistingTasks()
  }

  /// Recreating a background session with the same identifier reattaches to whatever tasks the
  /// system already has in flight for it (relaunch after a normal, not force-quit, termination).
  /// `taskDescription` recovers a reattached task's identity, since it was set at `enqueue` and
  /// the system persists it across relaunch.
  private func reattachExistingTasks() {
    session.pendingTasks { [weak self] tasks in
      guard let self else { return }
      self.storeReattachedTasks(tasks)
    }
  }

  // MARK: - BackgroundTransferring

  func enqueue(_ request: AuthorizedTransferRequest, destination: DownloadDestinationToken) async {
    let urlRequest = request.request
    let task = session.makeDownloadTask(for: urlRequest)
    task.taskDescription = Self.taskDescription(
      for: destination, redirectPolicy: request.redirectPolicy,
      effectiveByteLimit: request.redirectPolicy == .feed ? Self.effectiveByteLimit(for: request) : nil)
    if let expectedBytes = request.expectedBytes, expectedBytes > 0 {
      // Preserve the ABS adapter contract exactly: this URLSession scheduling hint is the
      // server-declared size, while the larger tolerance value remains an internal hard limit.
      task.countOfBytesClientExpectsToReceive = expectedBytes
    }

    storeEnqueuedTask(
      task, destination: destination, expectedBytes: request.expectedBytes,
      redirectPolicy: request.redirectPolicy)

    task.resume()
  }

  // `NSLock.lock()`/`.unlock()` are unavailable directly inside an `async` function body
  // (async-safe scoped locking only), so every lock/unlock pair below lives in a plain
  // synchronous helper called from the `async` `BackgroundTransferring` methods above.
  private func storeEnqueuedTask(
    _ task: BackgroundDownloadTaskHandle,
    destination: DownloadDestinationToken,
    expectedBytes: Int64?,
    redirectPolicy: TransferRedirectPolicy
  ) {
    lock.lock()
    let identity = destination.identity
    var state = stateByIdentity[identity] ?? TaskState()
    state.task = task
    state.destinationURL = destination.destinationURL
    state.byteLimit = Self.effectiveByteLimit(expectedBytes: expectedBytes, policy: redirectPolicy)
    state.redirectPolicy = redirectPolicy
    state.redirectHop = 0
    stateByIdentity[identity] = state
    lock.unlock()
  }

  func pause(identity: TransferIdentity) async {
    task(for: identity)?.suspend()
  }

  func resume(identity: TransferIdentity) async {
    task(for: identity)?.resume()
  }

  func cancel(identity: TransferIdentity) async {
    // Plain `cancel()`, never `cancel(byProducingResumeData:)`: byte-level resume is not
    // implemented, so there is nothing to hand back. The cancellation still surfaces as
    // `.failed` through the ordinary `didCompleteWithError` path.
    task(for: identity)?.cancel()
  }

  func currentTasks() async -> [BackgroundTransferSnapshot] {
    // `getAllTasks` is asynchronous. Query it here instead of trusting the eager init-time
    // callback to have won the race with launch reconciliation.
    await withCheckedContinuation { continuation in
      session.pendingTasks { [weak self] tasks in
        guard let self else {
          continuation.resume(returning: [])
          return
        }
        self.storeReattachedTasks(tasks)
        continuation.resume(
          returning: self.currentTaskIds().map {
            BackgroundTransferSnapshot(identity: $0)
          })
      }
    }
  }

  private func currentTaskIds() -> [TransferIdentity] {
    lock.lock()
    defer { lock.unlock() }
    // Progress can arrive for an identity this adapter has no task for (a late callback after
    // teardown), which leaves a record with no task; a snapshot of live tasks must not name it.
    return stateByIdentity.compactMap { $0.value.task == nil ? nil : $0.key }
  }

  private func task(for identity: TransferIdentity) -> BackgroundDownloadTaskHandle? {
    lock.lock()
    defer { lock.unlock() }
    return stateByIdentity[identity]?.task
  }

  private func destination(for identity: TransferIdentity) -> URL? {
    lock.lock()
    defer { lock.unlock() }
    return stateByIdentity[identity]?.destinationURL
  }

  private func storeReattachedTasks(_ tasks: [BackgroundDownloadTaskHandle]) {
    lock.lock()
    for task in tasks {
      guard let metadata = Self.taskMetadata(from: task.taskDescription) else { continue }
      var state = stateByIdentity[metadata.identity] ?? TaskState()
      state.task = task
      if let destinationURL = metadata.destinationURL {
        state.destinationURL = destinationURL
      }
      state.byteLimit = metadata.effectiveByteLimit
      state.redirectPolicy = metadata.redirectPolicy
      state.redirectHop = metadata.hopCount
      stateByIdentity[metadata.identity] = state
    }
    lock.unlock()
  }

  // MARK: - Launch-events completion handler

  /// Stored by the `@UIApplicationDelegateAdaptor` bridge's
  /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`. Invoked exactly
  /// once, after event drain (`handleSessionFinishedEvents`), on the main queue
  /// (`urlSessionDidFinishEvents` itself may fire on a secondary queue).
  func storeLaunchEventsCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
    lock.lock()
    launchEventsCompletionHandler = handler
    lock.unlock()
  }

  /// Translates `urlSessionDidFinishEvents(forBackgroundURLSession:)`. Internal (not `private`) so
  /// `BackgroundDownloadAdapterTests` can drive it directly without a real background session.
  func handleSessionFinishedEvents() {
    lock.lock()
    finishedSessionEventsCount += 1
    let handler = launchEventsCompletionHandler
    launchEventsCompletionHandler = nil
    lock.unlock()
    guard let handler else { return }
    mainQueueDispatch(handler)
  }

  // MARK: - Teardown

  func invalidate() {
    session.invalidateAndCancel()
    eventsContinuation.finish()
  }

  // MARK: - Delegate-callback translation (internal, directly testable)

  /// Translates `didWriteData`. `expectedBytes` may be `NSURLSessionTransferSizeUnknown` (`-1`)
  /// when the server sent no `Content-Length`; that maps to `nil` rather than a bogus negative
  /// expectation.
  func handleProgress(identity: TransferIdentity, receivedBytes: Int64, expectedBytes: Int64) {
    switch progressDecision(identity: identity, receivedBytes: receivedBytes) {
    case .overrun:
      task(for: identity)?.cancel()
      return
    case .alreadyOverrun:
      return
    case .allowed:
      break
    }

    let expected: Int64? = expectedBytes < 0 ? nil : expectedBytes
    guard
      let event = progressEventIfDue(
        identity: identity, receivedBytes: receivedBytes, expectedBytes: expected)
    else { return }
    eventsContinuation.yield(event)
  }

  /// Translates `didFinishDownloadingTo`. Runs the mover synchronously: the platform deletes the
  /// temp file the instant the delegate method returns, so the wrapper calls this with no `await`.
  /// A `401` reports `.authChallenge` (the coordinator's one renewed retry), not `.finished`; a
  /// mover failure reports `.failed`, so `DownloadFileStore` never hears of a file that did not
  /// land.
  func handleFinishedDownloading(
    identity: TransferIdentity,
    temporaryFileURL: URL,
    httpResponse: HTTPURLResponse?,
    persistedDestinationURL: URL? = nil
  ) {
    guard let destinationURL = persistedDestinationURL ?? destination(for: identity) else {
      finishTask(identity: identity)
      eventsContinuation.yield(
        .failed(
          identity: identity, errorDomain: Self.missingDestinationErrorDomain, errorCode: nil))
      return
    }

    if httpResponse?.statusCode == 401 {
      finishTask(identity: identity)
      eventsContinuation.yield(.authChallenge(identity: identity))
      return
    }

    do {
      try fileMover.moveDownloadedFile(from: temporaryFileURL, to: destinationURL)
    } catch {
      finishTask(identity: identity, emittingFinalProgress: true)
      eventsContinuation.yield(
        .failed(identity: identity, errorDomain: Self.moveFailedErrorDomain, errorCode: nil))
      return
    }

    let expectedContentLength = httpResponse?.expectedContentLength
    let response = BackgroundTransferResponse(
      httpStatusCode: httpResponse?.statusCode ?? 0,
      mimeType: httpResponse?.mimeType,
      contentLength: (expectedContentLength ?? -1) < 0 ? nil : expectedContentLength,
      contentRange: httpResponse?.value(forHTTPHeaderField: "Content-Range")
    )
    // Marked undelivered under the same lock that drops the live task, so a reconcile reading
    // both never sees the identity in neither.
    finishTask(identity: identity, markingUndelivered: true)
    eventsContinuation.yield(.finished(identity: identity, temporaryFileURL: destinationURL, response: response))
  }

  var finishedSessionEvents: Int {
    lock.lock()
    defer { lock.unlock() }
    return finishedSessionEventsCount
  }

  func undeliveredFinishes() async -> Set<TransferIdentity> {
    undeliveredFinishSnapshot()
  }

  func acknowledgeFinish(identity: TransferIdentity) async {
    removeUndeliveredFinish(identity)
  }

  private func undeliveredFinishSnapshot() -> Set<TransferIdentity> {
    lock.lock()
    defer { lock.unlock() }
    return undeliveredFinishIdentities
  }

  private func removeUndeliveredFinish(_ identity: TransferIdentity) {
    lock.lock()
    undeliveredFinishIdentities.remove(identity)
    lock.unlock()
  }

  /// Translates `didCompleteWithError`; `nil` means `didFinishDownloadingTo` handled success. Any
  /// `NSURLSessionDownloadTaskResumeData` is discarded: the system daemon owns retries and nothing
  /// above resumes by bytes, so an interrupted transfer restarts.
  func handleTaskCompletion(identity: TransferIdentity, error: Error?) {
    guard let error else { return }
    let nsError = error as NSError
    let errorDomain = terminalErrorDomain(identity: identity, error: nsError)
    finishTask(identity: identity, emittingFinalProgress: true)
    eventsContinuation.yield(
      .failed(identity: identity, errorDomain: errorDomain, errorCode: nsError.code))
  }

  /// Applies the redirect policy without depending on Foundation's concrete task type, so the
  /// denial path can be driven synchronously with the injected task shim.
  func handleRedirect(
    identity: TransferIdentity,
    task: BackgroundDownloadTaskHandle,
    originalURL: URL?,
    request: URLRequest,
    completionHandler: (URLRequest?) -> Void
  ) {
    let policy: TransferRedirectPolicy = {
      lock.lock()
      defer { lock.unlock() }
      return stateByIdentity[identity]?.redirectPolicy ?? .abs
    }()
    let hopNumber: Int = {
      lock.lock()
      defer { lock.unlock() }
      var state = stateByIdentity[identity] ?? TaskState()
      state.redirectHop += 1
      stateByIdentity[identity] = state
      return state.redirectHop
    }()
    guard
      let originalURL,
      let targetURL = request.url,
      Self.redirectDecision(
        policy: policy, original: originalURL, target: targetURL, hopNumber: hopNumber) != nil
    else {
      lock.lock()
      var state = stateByIdentity[identity] ?? TaskState()
      state.redirectDenied = true
      stateByIdentity[identity] = state
      lock.unlock()
      // Cancel before completing: completing with nil first would let the session start
      // delivering the 3xx body in the gap, and a fast redirect response could then surface as a
      // spurious finished download instead of the intended failure.
      task.cancel()
      completionHandler(nil)
      return
    }

    // ABS redirects retain the original adapter behavior byte-for-byte: pass Foundation's
    // request straight through and do not require or rewrite persisted feed-hop metadata.
    guard policy == .feed else {
      completionHandler(request)
      return
    }

    var follow = request
    if let targetURL = request.url,
      FeedRedirectPolicy.evaluate(original: originalURL, target: targetURL, hopNumber: hopNumber)
        == .allow(stripAuthorization: true)
    {
      follow.setValue(nil, forHTTPHeaderField: "Authorization")
    }
    // Persist the hop count in taskDescription so a process relaunch cannot reset a redirect
    // chain and accidentally permit an unbounded sequence.
    guard let destinationURL = destination(for: identity) else {
      task.cancel()
      completionHandler(nil)
      return
    }
    task.taskDescription = Self.taskDescription(
      for: DownloadDestinationToken(identity: identity, destinationURL: destinationURL),
      redirectPolicy: policy, hopCount: hopNumber,
      effectiveByteLimit: {
        lock.lock()
        defer { lock.unlock() }
        return stateByIdentity[identity]?.byteLimit
      }())
    completionHandler(follow)
  }

  private static func redirectDecision(
    policy: TransferRedirectPolicy, original: URL, target: URL, hopNumber: Int
  ) -> URLRequest? {
    switch policy {
    case .abs:
      guard ABSRedirectPolicy.evaluate(original: original, target: target, isAuthenticationRoute: false) == .allow
      else { return nil }
    case .feed:
      guard FeedRedirectPolicy.evaluate(original: original, target: target, hopNumber: hopNumber) != .reject
      else { return nil }
    }
    return URLRequest(url: target)
  }

  private func progressEventIfDue(
    identity: TransferIdentity, receivedBytes: Int64, expectedBytes: Int64?
  ) -> BackgroundTransferEvent? {
    lock.lock()
    defer { lock.unlock() }

    let now = progressNow()
    var state = stateByIdentity[identity] ?? TaskState()
    var progress =
      state.progress
      ?? ProgressState(
        receivedBytes: receivedBytes, expectedBytes: expectedBytes,
        lastEmittedAt: nil, lastEmittedBytes: nil)
    progress.receivedBytes = receivedBytes
    progress.expectedBytes = expectedBytes
    let shouldEmit =
      progress.lastEmittedAt.map { now - $0 >= Self.progressEmissionInterval } ?? true
    if shouldEmit {
      progress.lastEmittedAt = now
      progress.lastEmittedBytes = receivedBytes
    }
    state.progress = progress
    stateByIdentity[identity] = state
    guard shouldEmit else { return nil }
    return .progress(
      identity: identity, receivedBytes: receivedBytes, expectedBytes: expectedBytes)
  }

  private func progressDecision(identity: TransferIdentity, receivedBytes: Int64) -> ProgressDecision {
    lock.lock()
    defer { lock.unlock() }

    guard var state = stateByIdentity[identity], let byteLimit = state.byteLimit else {
      return .allowed
    }
    if state.overrun { return .alreadyOverrun }
    guard receivedBytes > byteLimit else { return .allowed }
    state.overrun = true
    stateByIdentity[identity] = state
    return .overrun
  }

  private func terminalErrorDomain(identity: TransferIdentity, error: NSError) -> String {
    guard error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled else {
      return error.domain
    }

    lock.lock()
    var domain = error.domain
    if var state = stateByIdentity[identity] {
      if state.overrun {
        state.overrun = false
        stateByIdentity[identity] = state
        domain = Self.overrunErrorDomain
      } else if state.redirectDenied {
        state.redirectDenied = false
        stateByIdentity[identity] = state
        domain = Self.redirectDeniedErrorDomain
      }
    }
    lock.unlock()
    return domain
  }

  /// The one teardown path: drops the transfer's whole record, so no fact outlives the task under
  /// an identity a later row can reuse. `emittingFinalProgress` yields the last unreported byte
  /// count before the removal's caller reports its terminal event.
  private func finishTask(
    identity: TransferIdentity,
    emittingFinalProgress: Bool = false,
    markingUndelivered: Bool = false
  ) {
    let progressEvent: BackgroundTransferEvent?
    lock.lock()
    let removed = stateByIdentity.removeValue(forKey: identity)
    if emittingFinalProgress, let progress = removed?.progress,
      progress.lastEmittedBytes != progress.receivedBytes
    {
      progressEvent = .progress(
        identity: identity, receivedBytes: progress.receivedBytes,
        expectedBytes: progress.expectedBytes)
    } else {
      progressEvent = nil
    }
    if markingUndelivered { undeliveredFinishIdentities.insert(identity) }
    lock.unlock()
    if let progressEvent {
      eventsContinuation.yield(progressEvent)
    }
  }

  private static func taskDescription(
    for destination: DownloadDestinationToken,
    redirectPolicy: TransferRedirectPolicy = .abs,
    hopCount: Int = 0,
    effectiveByteLimit: Int64? = nil
  ) -> String {
    let metadata = PersistedTaskMetadata(
      identity: destination.identity, destinationURL: destination.destinationURL,
      redirectPolicy: redirectPolicy, hopCount: hopCount, effectiveByteLimit: effectiveByteLimit)
    guard let data = try? JSONEncoder().encode(metadata),
      let description = String(data: data, encoding: .utf8)
    else {
      return destination.identity.encoded
    }
    return description
  }

  private static func taskMetadata(
    from description: String?
  ) -> (
    identity: TransferIdentity, destinationURL: URL?, redirectPolicy: TransferRedirectPolicy,
    hopCount: Int, effectiveByteLimit: Int64?
  )? {
    guard let description else { return nil }
    if let data = description.data(using: .utf8),
      let metadata = try? JSONDecoder().decode(PersistedTaskMetadata.self, from: data)
    {
      return (
        metadata.identity, metadata.destinationURL, metadata.redirectPolicy, metadata.hopCount,
        metadata.effectiveByteLimit
      )
    }
    return TransferIdentity(encoded: description).map { ($0, nil, .abs, 0, nil) }
  }

  private static func effectiveByteLimit(for request: AuthorizedTransferRequest) -> Int64? {
    effectiveByteLimit(expectedBytes: request.expectedBytes, policy: request.redirectPolicy)
  }

  /// The in-flight defensive bound, applied to `didWriteData` byte counts.
  ///
  /// ABS serves the file it describes, so its declared size plus a margin is a real bound. A
  /// feed's enclosure length is advisory and often disagrees with the CDN either way, so feed
  /// transfers get only the absolute cap.
  static func effectiveByteLimit(
    expectedBytes: Int64?, policy: TransferRedirectPolicy
  ) -> Int64? {
    switch policy {
    case .feed:
      return feedSizeCapBytes
    case .abs:
      guard let expectedBytes, expectedBytes > 0 else { return nil }
      let tolerance = max(expectedBytes / 10, overrunMarginBytes)
      let (limit, overflow) = expectedBytes.addingReportingOverflow(tolerance)
      return overflow ? Int64.max : limit
    }
  }
}

// MARK: - Real URLSessionDownloadDelegate conformance
//
// Thin: see the `handle*` methods above for the tested logic. These methods only resolve
// `downloadId` from the concrete `URLSessionDownloadTask`/`URLSessionTask` Foundation hands over,
// then forward.
extension BackgroundDownloadSessionAdapter: URLSessionDownloadDelegate {
  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard let identity = Self.taskMetadata(from: downloadTask.taskDescription)?.identity else { return }
    handleProgress(
      identity: identity, receivedBytes: totalBytesWritten, expectedBytes: totalBytesExpectedToWrite)
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard let metadata = Self.taskMetadata(from: downloadTask.taskDescription) else { return }
    handleFinishedDownloading(
      identity: metadata.identity,
      temporaryFileURL: location,
      httpResponse: downloadTask.response as? HTTPURLResponse,
      persistedDestinationURL: metadata.destinationURL)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard
      let metadata = Self.taskMetadata(from: task.taskDescription),
      let downloadTask = task as? BackgroundDownloadTaskHandle
    else {
      task.cancel()
      completionHandler(nil)
      return
    }
    // ABS keeps its historical initial-request origin selection byte-for-byte. Feed redirects
    // are hop-aware, so each decision must compare the response URL that issued this redirect.
    let originalURL =
      metadata.redirectPolicy == .feed
      ? response.url : (task.originalRequest?.url ?? task.currentRequest?.url)
    handleRedirect(
      identity: metadata.identity,
      task: downloadTask,
      originalURL: originalURL,
      request: request,
      completionHandler: completionHandler)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let identity = Self.taskMetadata(from: task.taskDescription)?.identity else { return }
    handleTaskCompletion(identity: identity, error: error)
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    handleSessionFinishedEvents()
  }
}
