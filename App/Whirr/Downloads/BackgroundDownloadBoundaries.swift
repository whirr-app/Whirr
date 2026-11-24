import ABSApi
import Foundation

// MARK: - Injected session/task shims
//
// These mirror the `URLSessionDownloadTask`/`URLSession` surface the adapter needs, so real
// conformances are plain `extension`s and tests can substitute fakes. Every requirement is
// `nonisolated`: delegate callbacks arrive off the main actor, and the default-MainActor build
// setting would otherwise infer main-actor isolation.

/// A single background download task, as the adapter needs to control it: identity for reattach
/// (`taskDescription` carries the `downloadId`, `DownloadDestinationToken`'s identity), and
/// the three intents `BackgroundTransferring` exposes (pause/resume/cancel).
protocol BackgroundDownloadTaskHandle: AnyObject {
  nonisolated var taskDescription: String? { get set }
  nonisolated var countOfBytesClientExpectsToReceive: Int64 { get set }
  nonisolated func resume()
  nonisolated func suspend()
  nonisolated func cancel()
}

extension URLSessionDownloadTask: BackgroundDownloadTaskHandle {}

/// The background session, as the adapter needs to control it: mint a task for an already-
/// authorized `URLRequest`, discover tasks the system already has in flight (reattach after
/// relaunch), and invalidate at teardown.
protocol BackgroundDownloadSessionProviding: AnyObject {
  nonisolated func makeDownloadTask(for request: URLRequest) -> BackgroundDownloadTaskHandle
  nonisolated func pendingTasks(completion: @escaping @Sendable ([BackgroundDownloadTaskHandle]) -> Void)
  nonisolated func invalidateAndCancel()
}

/// Wraps a real, background-configured `URLSession`. The adapter is always this session's
/// delegate, constructed via `BackgroundDownloadSessionFactory`, never here.
nonisolated final class RealBackgroundDownloadSession: BackgroundDownloadSessionProviding {
  private let session: URLSession

  init(session: URLSession) {
    self.session = session
  }

  func makeDownloadTask(for request: URLRequest) -> BackgroundDownloadTaskHandle {
    session.downloadTask(with: request)
  }

  func pendingTasks(completion: @escaping @Sendable ([BackgroundDownloadTaskHandle]) -> Void) {
    session.getAllTasks { tasks in
      completion(tasks.compactMap { $0 as? URLSessionDownloadTask })
    }
  }

  func invalidateAndCancel() {
    session.invalidateAndCancel()
  }
}

/// Builds the one session a `BackgroundDownloadSessionAdapter` uses. Real production supplies
/// `RealBackgroundDownloadSessionFactory.make`; tests supply a fake that never constructs a real
/// background-configured `URLSession`.
typealias BackgroundDownloadSessionFactory =
  @Sendable (
    _ identifier: String,
    _ delegate: URLSessionDownloadDelegate,
    _ delegateQueue: OperationQueue?
  ) -> BackgroundDownloadSessionProviding

nonisolated enum RealBackgroundDownloadSessionFactory {
  static func makeConfiguration(identifier: String) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = HTTPTransportClass.download.requestTimeout
    configuration.timeoutIntervalForResource = HTTPTransportClass.download.resourceTimeout
    // API-CONVENTIONS rule 25 is also enforced by SyncEngine's scheduler; this session-level cap is
    // defense in depth if task restoration or a future scheduling change presents more work.
    configuration.httpMaximumConnectionsPerHost = 2
    return configuration
  }

  /// Recreating a background session with the same identifier reattaches it, so one stable
  /// identifier for the app's lifetime (`BackgroundDownloadHardware.sessionIdentifier`) is what
  /// makes reattachment work. With `delegateQueue: nil` the system vends its own serial
  /// background queue, so delegate callbacks run off the main thread.
  static let make: BackgroundDownloadSessionFactory = { identifier, delegate, delegateQueue in
    let configuration = makeConfiguration(identifier: identifier)
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: delegateQueue)
    return RealBackgroundDownloadSession(session: session)
  }
}

// MARK: - Injected file-mover
//
// The OS deletes the temp file the instant `didFinishDownloadingTo` returns, so the move to a
// durable location must be synchronous, and injected so `BackgroundDownloadAdapterTests` never
// touches the real filesystem's background-session temp-file lifecycle.
protocol BackgroundDownloadFileMoving: Sendable {
  nonisolated func moveDownloadedFile(from temporaryURL: URL, to destinationURL: URL) throws
}

nonisolated struct FileManagerDownloadFileMover: BackgroundDownloadFileMoving {
  func moveDownloadedFile(from temporaryURL: URL, to destinationURL: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: destinationURL.path) {
      try fileManager.removeItem(at: destinationURL)
    }
    try fileManager.moveItem(at: temporaryURL, to: destinationURL)
  }
}
