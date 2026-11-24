import Foundation
import Persistence
import WatchProtocol

/// Before the phone starts any title, a Watch playing a received RSS episode is asked to pause
/// Native playback has no handoff, so this only avoids a concurrent start:
/// for the same episode the phone waits briefly and starts from the Watch's position, and for any
/// other title the request is not awaited. No outcome ever denies the start.
@MainActor
final class WatchNativeStartGate {
  typealias Send = @MainActor (_ data: Data, _ wait: Duration) async -> Data?
  typealias ApplyListen =
    @MainActor (
      _ selection: WatchNativeSelection, _ position: Double, _ lastListenedAt: Date
    ) async -> Void

  private let report: @MainActor () -> WatchPlayingReport?
  private let send: Send
  private let applyListen: ApplyListen
  private let now: @MainActor () -> Date

  /// The latest request that is not awaited, so tests can wait for it.
  private(set) var unawaitedSend: Task<Void, Never>?

  init(
    report: @escaping @MainActor () -> WatchPlayingReport?,
    send: @escaping Send,
    applyListen: @escaping ApplyListen,
    now: @escaping @MainActor () -> Date = { Date() }
  ) {
    self.report = report
    self.send = send
    self.applyListen = applyListen
    self.now = now
  }

  /// The Watch's position when it was playing this episode, else `nil` to leave the start as it
  /// was. The reply's listen is applied before returning so the phone's row already reflects it
  /// when the start reads the row.
  func positionForStart(itemID: String, episodeID: String?) async -> Double? {
    let current = now()
    // `report()` is already fenced to the bound account by the runtime, so the report's own stamp
    // is the one its expiry helper has to see.
    guard let report = report(), report.playing, let watchSelection = report.nativeSelection,
      report.isPlaying(for: report.accountStamp, at: current)
    else { return nil }
    guard
      let request = try? WatchNativePauseRequest(selection: watchSelection, sentAt: current),
      let data = try? WatchWireCodec.encode(request)
    else { return nil }

    // An ABS title, a native episode that is not the one playing, and an RSS start with no episode
    // all name no position to use, so the Watch is paused without holding up the start.
    guard let start = Self.nativeSelection(itemID: itemID, episodeID: episodeID),
      start == watchSelection
    else {
      fireAndForget(data)
      return nil
    }

    guard let replyData = await send(data, WatchPhoneHandoffAsker.sameTitleWait),
      let reply = try? WatchWireCodec.decode(WatchNativePauseReply.self, from: replyData),
      reply.selection == watchSelection, reply.paused, let position = reply.position
    else { return nil }
    // A reply that omits its listen time still describes a Watch playing this episode now, so the
    // start's own clock is the closest honest stamp for the phone's row.
    await applyListen(watchSelection, position, reply.lastListenedAt ?? current)
    return position
  }

  /// A phone resume while the Watch plays a received episode: the pause is sent without waiting,
  /// and nothing is applied here because the Watch's listen returns through the progress inbox,
  /// which holds it until this phone's session on the episode ends.
  @discardableResult
  func askOnResume() -> Task<Void, Never>? {
    let current = now()
    guard let report = report(), report.playing, let watchSelection = report.nativeSelection,
      report.isPlaying(for: report.accountStamp, at: current),
      let request = try? WatchNativePauseRequest(selection: watchSelection, sentAt: current),
      let data = try? WatchWireCodec.encode(request)
    else { return nil }
    return fireAndForget(data)
  }

  /// The native selection a phone start names: an RSS item id with an episode, otherwise `nil`
  /// (an ABS title or an RSS start without an episode).
  static func nativeSelection(itemID: String, episodeID: String?) -> WatchNativeSelection? {
    guard let identity = PodcastSourceIdentity(itemId: itemID),
      case .rss(let feedId) = identity.source, let episodeID, episodeID.isEmpty == false
    else { return nil }
    return try? WatchNativeSelection(feedID: String(feedId), episodeID: episodeID)
  }

  @discardableResult
  private func fireAndForget(_ data: Data) -> Task<Void, Never> {
    let send = send
    let task = Task { @MainActor in _ = await send(data, WatchPhoneHandoffAsker.sameTitleWait) }
    unawaitedSend = task
    return task
  }
}
