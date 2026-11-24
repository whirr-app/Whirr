import Foundation
import WatchPlayback
import WatchProtocol

/// The received-episode entry one RSS download serves. It is the whole of `taskDescription`, so a
/// task a new process inherits can be attributed without persisting a URL, a title or the account.
nonisolated struct WatchRSSDownloadKey: Hashable, Sendable {
  let selection: WatchNativeSelection
  let revision: UInt64

  init(selection: WatchNativeSelection, revision: UInt64) {
    self.selection = selection
    self.revision = revision
  }

  init(_ entry: WatchReceivedEpisode) {
    self.init(selection: entry.selection, revision: entry.revision)
  }
}

/// Names the system task a delegate callback belongs to, so a callback from a task the driver has
/// replaced or cancelled cannot commit anything.
nonisolated struct WatchRSSCallbackToken: Hashable, Sendable {
  let key: WatchRSSDownloadKey
  let taskIdentifier: Int
}

/// One task's outcome, assembled on the delegate queue once the metrics and the temporary file have
/// both arrived. A background session deletes the file when `didFinishDownloadingTo` returns, so
/// `stagedFileURL` is this app's copy and the driver owns it.
nonisolated struct WatchRSSDownloadCompletion: Sendable {
  var stagedFileURL: URL?
  var measuredBytes: Int64?
  var statusCode: Int?
  /// The final response's `Content-Length`, or nil when it sent none.
  var expectedContentLength: Int64?
  var contentRangeTotal: Int64?
  /// Every transaction URL, in visit order. Empty metrics are a rejection (ADR 0020 Decision 3).
  var hops: [URL]
  var requestedURL: URL?
}

/// Received on the main actor for every task event the RSS session raises.
@MainActor
protocol WatchRSSDownloadURLSessionEvents: AnyObject {
  func rssDidWrite(
    _ token: WatchRSSCallbackToken, totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64) async
  func rssDidComplete(_ token: WatchRSSCallbackToken, completion: WatchRSSDownloadCompletion) async
  func rssDidFail(_ token: WatchRSSCallbackToken, error: Error?) async
  func rssTaskIsWaitingForConnectivity(_ token: WatchRSSCallbackToken) async
}

/// What one task reported while finishing, kept until `didCompleteWithError` can combine it with
/// the metrics. `didFinishCollecting` may arrive after `didFinishDownloadingTo`.
nonisolated struct WatchRSSDownloadFinish: Sendable {
  var stagedFileURL: URL?
  var measuredBytes: Int64?
  var statusCode: Int?
  var expectedContentLength: Int64?
  var contentRangeTotal: Int64?
}
