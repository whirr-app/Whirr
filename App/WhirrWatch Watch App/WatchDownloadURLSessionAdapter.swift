import Foundation
import WatchPlayback

/// Transport events retain the task identifier and epoch so the manager can fence stale work.
@MainActor
protocol WatchDownloadURLSessionEvents: AnyObject {
  func didProgress(
    _ token: WatchDownloadCallbackToken,
    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) async
  func didFinish(
    _ token: WatchDownloadCallbackToken,
    preservedURL: URL?, statusCode: Int?, responseBytes: Int64?
  ) async
  func didFail(_ token: WatchDownloadCallbackToken, error: Error?) async
  func didRecoverTasks(_ tasks: [URLSessionDownloadTask], generation: Int) async
  func didFinishBackgroundEvents()
  func didDrainCallbacks()
}

/// Owns URLSession and the synchronous temporary-file handoff; durable policy stays in the manager.
@MainActor
final class WatchDownloadURLSessionAdapter: NSObject {
  /// Set once by the owning manager before any task starts; delegate callbacks read it from the
  /// session queue to retain the receiver for the life of each pending callback.
  nonisolated(unsafe) weak var events: (any WatchDownloadURLSessionEvents)?
  nonisolated private let handoff: WatchDownloadTemporaryFileHandoff
  nonisolated private let callbackState = WatchDownloadCallbackState()
  private var session: URLSession!

  init(rootURL: URL, accountIdentity: String, identifier: String, networkPolicy: WatchDownloadNetworkPolicy) {
    handoff = WatchDownloadTemporaryFileHandoff(rootURL: rootURL, accountIdentity: accountIdentity)
    super.init()
    session = URLSession(
      configuration: Self.makeBackgroundConfiguration(identifier: identifier, networkPolicy: networkPolicy),
      delegate: self, delegateQueue: nil)
  }

  func invalidateAndCancel() { session.invalidateAndCancel() }

  func downloadTask(with request: URLRequest) -> URLSessionDownloadTask {
    session.downloadTask(with: request)
  }

  /// Continues a transfer from the partial data a failed task reported, instead of from zero.
  func downloadTask(withResumeData data: Data) -> URLSessionDownloadTask {
    session.downloadTask(withResumeData: data)
  }

  func recoverTasks(generation: Int) async {
    let tasks: [URLSessionDownloadTask] = await withCheckedContinuation { continuation in
      session.getAllTasks { tasks in
        continuation.resume(returning: tasks.compactMap { $0 as? URLSessionDownloadTask })
      }
    }
    await events?.didRecoverTasks(tasks, generation: generation)
  }

  var pendingCallbacks: Int { callbackState.pending }

  func hasPendingCallback(_ token: WatchDownloadCallbackToken) -> Bool { callbackState.contains(token) }

  func hasPendingCallback(forDownloadID id: UUID) -> Bool { callbackState.contains(downloadID: id) }

  /// Removes handoff files that no callback in this process produced, which are leftovers from a
  /// run that ended before it committed them.
  func sweepUnclaimedIncoming() { handoff.sweepUnclaimed() }

  private func handleFinished(
    _ token: WatchDownloadCallbackToken,
    receiver: (any WatchDownloadURLSessionEvents)?,
    preservedURL: URL?, statusCode: Int?, responseBytes: Int64?
  ) async {
    defer {
      callbackState.finished(token)
      receiver?.didDrainCallbacks()
    }
    guard let receiver else {
      if let preservedURL { try? FileManager.default.removeItem(at: preservedURL) }
      return
    }
    await receiver.didFinish(token, preservedURL: preservedURL, statusCode: statusCode, responseBytes: responseBytes)
  }

  nonisolated static func makeBackgroundConfiguration(
    identifier: String, networkPolicy: WatchDownloadNetworkPolicy = .wifiOnly
  ) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.allowsCellularAccess = networkPolicy == .anyNetwork
    configuration.isDiscretionary = false
    return configuration
  }

  nonisolated static func taskDescription(for id: UUID, generation: Int? = nil) -> String {
    let base = "whirr-watch-download:\(id.uuidString.lowercased())"
    guard let generation else { return base }
    return "\(base):g\(generation)"
  }

  nonisolated static func downloadID(from taskDescription: String?) -> UUID? {
    taskReference(from: taskDescription)?.id
  }

  nonisolated private static func taskReference(
    from taskDescription: String?
  ) -> (id: UUID, generation: Int?)? {
    guard let taskDescription,
      taskDescription.hasPrefix("whirr-watch-download:")
    else { return nil }
    let raw = String(taskDescription.dropFirst("whirr-watch-download:".count))
    let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
    guard let id = UUID(uuidString: String(parts[0])) else { return nil }
    guard parts.count == 1 else {
      guard parts.count == 2, parts[1].hasPrefix("g"),
        let generation = Int(parts[1].dropFirst())
      else { return nil }
      return (id, generation)
    }
    return (id, nil)
  }

  /// ABS file and EPUB downloads may follow only a same-origin redirect that remains under the
  /// `/api/items/` resource family. This prevents an authenticated request from following a
  /// redirect to another host or to an unrelated route. `acceptsFinalURL` enforces it after a
  /// background download completes, since a background session never calls the redirect delegate.
  nonisolated static func allowsRedirect(from source: URL?, to target: URL?) -> Bool {
    guard let source, let target,
      let sourceScheme = source.scheme?.lowercased(),
      let targetScheme = target.scheme?.lowercased(),
      sourceScheme == targetScheme,
      ["http", "https"].contains(sourceScheme),
      source.host?.lowercased() == target.host?.lowercased(),
      source.port == target.port,
      source.user == nil, source.password == nil,
      target.user == nil, target.password == nil,
      let marker = source.path.range(of: "/api/items/"),
      target.path.hasPrefix(String(source.path[..<marker.upperBound]))
    else { return false }
    return true
  }

  /// Judges where a completed download actually came from, because a background session never
  /// calls `urlSession(_:task:willPerformHTTPRedirection:…)`. A missing source or final URL
  /// accepts: resume-data continuation and tasks recovered after a relaunch do not build the
  /// request here, and refusing them would fail transfers that the redirect rule never saw.
  nonisolated static func acceptsFinalURL(source: URL?, final: URL?) -> Bool {
    guard let source, let final else { return true }
    return final == source || allowsRedirect(from: source, to: final)
  }

}

nonisolated private final class WatchDownloadTemporaryFileHandoff: @unchecked Sendable {
  private let rootURL: URL
  private let accountIdentity: String
  private let lock = NSLock()
  private var preservedPaths: Set<String> = []

  init(rootURL: URL, accountIdentity: String) {
    self.rootURL = rootURL
    self.accountIdentity = accountIdentity
  }

  func preserve(_ sourceURL: URL, taskIdentifier: Int) throws -> URL {
    lock.lock()
    defer { lock.unlock() }
    let directory = rootURL.appendingPathComponent("incoming", isDirectory: true)
    guard Self.hasNoSymlink(at: rootURL), Self.hasNoSymlink(at: directory) else {
      throw CocoaError(.fileWriteNoPermission)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard Self.hasNoSymlink(at: directory) else { throw CocoaError(.fileWriteNoPermission) }
    let destination = directory.appendingPathComponent(
      "task-\(accountIdentity)-\(taskIdentifier)-\(UUID().uuidString.lowercased()).part")
    try FileManager.default.moveItem(at: sourceURL, to: destination)
    preservedPaths.insert(destination.lastPathComponent)
    return destination
  }

  /// Holds the same lock as `preserve`, so a file preserved by this process can never be swept.
  func sweepUnclaimed() {
    lock.lock()
    defer { lock.unlock() }
    let directory = rootURL.appendingPathComponent("incoming", isDirectory: true)
    guard Self.hasNoSymlink(at: directory),
      let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    else { return }
    for file in files where file.pathExtension == "part" && !preservedPaths.contains(file.lastPathComponent) {
      try? FileManager.default.removeItem(at: file)
    }
  }

  private static func hasNoSymlink(at url: URL) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let type = attributes[.type] as? FileAttributeType
    else { return true }
    return type != .typeSymbolicLink
  }
}

nonisolated struct WatchDownloadCallbackToken: Hashable, Sendable {
  let id: UUID
  let taskIdentifier: Int
  let generation: Int
}

nonisolated private final class WatchDownloadCallbackState: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var pendingTokens: Set<WatchDownloadCallbackToken> = []

  var pending: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func began(_ token: WatchDownloadCallbackToken) {
    lock.lock()
    count += 1
    pendingTokens.insert(token)
    lock.unlock()
  }

  @discardableResult
  func finished(_ token: WatchDownloadCallbackToken) -> Int {
    lock.lock()
    count = max(0, count - 1)
    pendingTokens.remove(token)
    let remaining = count
    lock.unlock()
    return remaining
  }

  func contains(_ token: WatchDownloadCallbackToken) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return pendingTokens.contains(token)
  }

  func contains(downloadID id: UUID) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return pendingTokens.contains { $0.id == id }
  }
}

extension WatchDownloadURLSessionAdapter: URLSessionDownloadDelegate {
  nonisolated func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard (downloadTask.response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
      let reference = Self.taskReference(from: downloadTask.taskDescription),
      let generation = reference.generation
    else { return }
    let token = WatchDownloadCallbackToken(
      id: reference.id, taskIdentifier: downloadTask.taskIdentifier, generation: generation)
    Task { @MainActor [weak self] in
      await self?.events?.didProgress(
        token, totalBytesWritten: totalBytesWritten,
        totalBytesExpectedToWrite: totalBytesExpectedToWrite)
    }
  }

  nonisolated func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
  ) {
    guard let reference = Self.taskReference(from: downloadTask.taskDescription),
      let generation = reference.generation
    else { return }
    let token = WatchDownloadCallbackToken(
      id: reference.id, taskIdentifier: downloadTask.taskIdentifier, generation: generation)
    // URLSession deletes location when this method returns. Move it synchronously before
    // hopping to MainActor, and keep the callback pending until durable processing finishes.
    self.callbackState.began(token)
    let preservedURL = try? self.handoff.preserve(location, taskIdentifier: downloadTask.taskIdentifier)
    let sourceURL = downloadTask.originalRequest?.url
    let finalURL = downloadTask.response?.url ?? downloadTask.currentRequest?.url
    let redirectAccepted = Self.acceptsFinalURL(source: sourceURL, final: finalURL)
    if !redirectAccepted { WatchDiagnostics.record(.downloadRedirectRefused) }
    // A refused redirect keeps its file for the manager to remove, which it does for any finish
    // without a 2xx status.
    let statusCode =
      redirectAccepted ? (downloadTask.response as? HTTPURLResponse)?.statusCode : nil
    let expected = (downloadTask.response as? HTTPURLResponse)?.expectedContentLength ?? -1
    // The receiver is retained until the durable commit and the drain notification have run, so
    // a manager whose last external owner goes away first still completes this download.
    let receiver = events
    Task { @MainActor [self] in
      await handleFinished(
        token, receiver: receiver, preservedURL: preservedURL, statusCode: statusCode,
        responseBytes: expected >= 0 ? expected : nil)
    }
  }

  nonisolated func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    guard let reference = Self.taskReference(from: task.taskDescription),
      let generation = reference.generation
    else { return }
    let token = WatchDownloadCallbackToken(
      id: reference.id, taskIdentifier: task.taskIdentifier, generation: generation)
    Task { @MainActor [weak self] in await self?.events?.didFail(token, error: error) }
  }

  /// A background session, which is what this adapter runs, does not call this delegate method:
  /// `acceptsFinalURL` in `urlSession(_:downloadTask:didFinishDownloadingTo:)` enforces the rule on
  /// the final URL. Keep this for a foreground session, and as the earlier refusal where it runs.
  nonisolated func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    let source = response.url ?? task.currentRequest?.url ?? task.originalRequest?.url
    guard Self.allowsRedirect(from: source, to: request.url) else {
      task.cancel()
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }

  nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      events?.didFinishBackgroundEvents()
    }
  }
}
