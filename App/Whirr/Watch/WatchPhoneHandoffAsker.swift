import AppModel
import Foundation
import Persistence
import WatchProtocol

/// The phone's side of the pause request: before a live phone play, ask the Watch to pause, but only when its
/// latest `WatchPlayingReport` says it is playing. It never denies a start; any failure plays on.
@MainActor
final class WatchPhoneHandoffAsker {
  typealias Send = @MainActor (_ request: Data, _ wait: Duration) async -> Data?

  /// The wait for the same title, where the position matters.
  static let sameTitleWait: Duration = .seconds(3)
  /// A start's request and the resume observed right after it are one ask.
  static let repeatWindow: TimeInterval = 15

  private let report: @MainActor () -> WatchPlayingReport?
  private let authenticatedStamp: @MainActor () -> WatchAccountStamp?
  private let send: Send
  private let storedListen: @MainActor (_ itemID: String, _ episodeID: String?) -> Date?
  private let now: @MainActor () -> Date
  private var lastAskedAt: Date?
  /// The latest request that is not awaited, so tests can wait for it.
  private(set) var unawaitedSend: Task<Void, Never>?

  init(
    report: @escaping @MainActor () -> WatchPlayingReport?,
    authenticatedStamp: @escaping @MainActor () -> WatchAccountStamp?,
    send: @escaping Send,
    storedListen: @escaping @MainActor (String, String?) -> Date?,
    now: @escaping @MainActor () -> Date = { Date() }
  ) {
    self.report = report
    self.authenticatedStamp = authenticatedStamp
    self.send = send
    self.storedListen = storedListen
    self.now = now
  }

  /// `nil` for a native feed title, which the wire cannot name.
  static func wireSelection(_ selection: CompanionSelection) -> WatchABSSelection? {
    guard case .abs = selection.source.source else { return nil }
    return try? WatchABSSelection(itemID: selection.itemID, episodeID: selection.episodeID)
  }

  static func wireSelection(itemID: String, episodeID: String?) -> WatchABSSelection? {
    guard let source = PodcastSourceIdentity(itemId: itemID) else { return nil }
    return wireSelection(CompanionSelection(source: source, episodeID: episodeID))
  }

  /// Asks before a phone start. For the title the Watch is playing, waits up to 3 s and returns the
  /// Watch's position when its listen is newer than the phone's own; for another title the
  /// request is not awaited.
  func positionForStart(itemID: String, episodeID: String?) async -> Double? {
    guard let (request, data) = makeRequest(selection: Self.wireSelection(itemID: itemID, episodeID: episodeID))
    else { return nil }
    lastAskedAt = now()
    guard let selection = request.selection, report()?.selection == selection else {
      fireAndForget(data)
      return nil
    }
    guard let replyData = await send(data, Self.sameTitleWait),
      let reply = WatchPhoneRequestRunner.decode(WatchHandoffReply.self, from: replyData),
      reply.handoffID == request.handoffID, let position = reply.position(for: selection),
      let listenedAt = reply.lastListenedAt,
      listenedAt > (storedListen(itemID, episodeID) ?? .distantPast)
    else { return nil }
    return position
  }

  /// A phone resume of a paused loaded title: fire and forget, and not again right
  /// after a start already asked. Returns the in-flight send for tests to await.
  @discardableResult
  func askOnResume(selection: WatchABSSelection?) -> Task<Void, Never>? {
    if let lastAskedAt, now().timeIntervalSince(lastAskedAt) < Self.repeatWindow { return nil }
    guard let (_, data) = makeRequest(selection: selection) else { return nil }
    lastAskedAt = now()
    return fireAndForget(data)
  }

  private func makeRequest(selection: WatchABSSelection?) -> (WatchHandoffRequest, Data)? {
    let current = now()
    // A Watch playing a received RSS episode is asked by `WatchNativeStartGate` instead: a handoff
    // request would pause it with no position the phone can use, racing the ask that has one.
    guard let stamp = authenticatedStamp(), let report = self.report(), report.nativeSelection == nil,
      report.isPlaying(for: stamp, at: current),
      let request = try? WatchHandoffRequest(accountStamp: stamp, selection: selection, issuedAt: current),
      let data = try? WatchWireCodec.encode(request)
    else { return nil }
    return (request, data)
  }

  @discardableResult
  private func fireAndForget(_ data: Data) -> Task<Void, Never> {
    let send = send
    let task = Task { @MainActor in _ = await send(data, Self.sameTitleWait) }
    unawaitedSend = task
    return task
  }
}
