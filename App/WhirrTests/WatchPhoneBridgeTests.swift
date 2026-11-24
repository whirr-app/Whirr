import AppModel
import Foundation
import Persistence
import TestSupport
import Testing
import WatchProtocol

@testable import Whirr

@MainActor
@Suite("Watch phone bridge", .serialized)
struct WatchPhoneBridgeTests {

  @Test("opening a reachable Watch refreshes current playback even with no queued catalogue")
  func watchReconnectRefreshesCurrentPlayback() {
    let bridge = WatchPhoneBridge(bootstrap: {})
    var refreshes = 0
    bridge.refreshCatalogue = { refreshes += 1 }
    bridge.watchReachabilityChanged(isReachable: false)
    #expect(refreshes == 0)
    bridge.watchReachabilityChanged(isReachable: true)
    #expect(refreshes == 1)
    bridge.watchReachabilityChanged(isReachable: false)
    #expect(refreshes == 1)
    bridge.watchReachabilityChanged(isReachable: true)
    #expect(refreshes == 2)
  }

  @Test func reachabilityChangesReachTheSetupObserver() {
    let bridge = WatchPhoneBridge(bootstrap: {})
    var changes: [Bool] = []
    bridge.onWatchReachabilityChange = { changes.append($0) }
    bridge.watchReachabilityChanged(isReachable: true)
    bridge.watchReachabilityChanged(isReachable: false)
    #expect(changes == [true, false])
  }

  @Test("an unactivated transport reports an unknown prerequisite rather than a failed one")
  func installStateBeforeActivation() {
    let bridge = WatchPhoneBridge(bootstrap: {})
    // Nothing may be asserted before WatchConnectivity activates, so setup must not tell anyone
    // to pair or install on the strength of an unactivated session.
    #expect(bridge.installState == .unknown)
    #expect(bridge.isWatchInstalled == false)
  }

  @Test("the process router keeps only a weak account handler")
  func weakBinding() throws {
    let bridge = WatchPhoneBridge(bootstrap: {})
    weak var released: FakeCompanionHandler?
    do {
      let handler = FakeCompanionHandler()
      released = handler
      bridge.bind(handler, accountStamp: try Self.stamp("one"), currentSelection: { nil })
      #expect(bridge.isBound)
    }
    #expect(released == nil)
    #expect(bridge.isBound == false)
  }

  @Test("headless bootstrap runs once before admission")
  func headlessBootstrap() async throws {
    var bootstrapCount = 0
    let bridge = WatchPhoneBridge(bootstrap: { bootstrapCount += 1 })
    let command = try Self.command(stamp: Self.stamp("one"))

    let first = await Self.receive(command, through: bridge)
    let second = await Self.receive(command, through: bridge)

    #expect(first.first?.errorCode == .accountUnavailable)
    #expect(second.first?.errorCode == .accountUnavailable)
    #expect(bootstrapCount == 1)
    #expect(bridge.hasBootstrapped)
  }

  @Test("a wake before first unlock skips bootstrap, rejects the command, and retries on the next")
  func bootstrapWaitsForProtectedDatabase() async throws {
    var bootstrapCount = 0
    // A reference, not a captured `var`: the `@MainActor` closure is Sendable, so the test may not
    // mutate a local it has captured.
    let databaseAvailable = DatabaseAvailability()
    let bridge = WatchPhoneBridge(
      bootstrap: { bootstrapCount += 1 }, isDatabaseAvailable: { databaseAvailable.value })
    let command = try Self.command(stamp: Self.stamp("one"))

    let locked = try #require(await Self.receive(command, through: bridge).first)

    #expect(locked.status == .rejected)
    #expect(locked.errorCode == .accountUnavailable)
    #expect(bootstrapCount == 0)
    #expect(bridge.hasBootstrapped == false)

    databaseAvailable.value = true
    _ = await Self.receive(command, through: bridge)

    #expect(bootstrapCount == 1)
    #expect(bridge.hasBootstrapped)
  }

  @Test("a native listen held before the store opens is applied in arrival order after bootstrap")
  func heldNativeProgressIsDeliveredAfterBootstrap() async throws {
    var bootstrapCount = 0
    let databaseAvailable = DatabaseAvailability()
    let probes = Probe()
    let bridge = WatchPhoneBridge(
      bootstrap: { bootstrapCount += 1 },
      isDatabaseAvailable: {
        probes.value += 1
        return databaseAvailable.value
      })
    let install = "11111111-2222-3333-4444-555555555555"
    var applied: [Double] = []
    let inbox = WatchNativeProgressInbox(
      activeInstallID: { install },
      episodeIDs: { _, keys in
        Dictionary(uniqueKeysWithValues: keys.map { ($0, Int64(42)) })
      },
      apply: { _, position, _, _, _, _ in
        applied.append(position)
        return .applied(localSequence: 1)
      },
      isPlayingHere: { _ in false },
      removeFromWatch: { _ in })
    bridge.nativeProgressInbox = { inbox }
    let first = try Self.nativeProgress(install: install, sequence: 1, position: 100)
    let second = try Self.nativeProgress(install: install, sequence: 2, position: 200)

    bridge.receive(userInfo: [WatchNativeProgressReport.transportKey: first])
    await waitUntil { probes.value > 0 }
    #expect(applied.isEmpty)

    databaseAvailable.value = true
    bridge.receive(userInfo: [WatchNativeProgressReport.transportKey: second])
    await waitUntil { applied.count == 2 }

    #expect(bootstrapCount == 1)
    #expect(applied == [100, 200])
  }

  @Test("malformed transport payload receives one empty malformed reply")
  func malformedPayloadReply() async {
    let bridge = WatchPhoneBridge(bootstrap: {})
    var replies: [[String: Any]] = []
    bridge.receive(message: [:]) { replies.append($0) }
    #expect(replies.count == 1)
    _ = bridge
    await Task.yield()
  }

  @Test("a command from another account is rejected before dispatch")
  func wrongAccount() async throws {
    let handler = FakeCompanionHandler()
    let bridge = WatchPhoneBridge(bootstrap: {})
    bridge.bind(handler, accountStamp: try Self.stamp("one"), currentSelection: { nil })

    let reply = try #require(
      await Self.receive(
        try Self.command(stamp: Self.stamp("two")), through: bridge
      ).first)

    #expect(reply.status == .rejected)
    #expect(reply.errorCode == .accountUnavailable)
    #expect(handler.calls.isEmpty)
  }

  @Test("a start replies only once it has succeeded; a duplicate meanwhile is unresolved")
  func startRepliesWithRealOutcome() async throws {
    let handler = FakeCompanionHandler()
    handler.holdStarts = true
    let bridge = WatchPhoneBridge(bootstrap: {})
    bridge.bind(handler, accountStamp: try Self.stamp("one"), currentSelection: { nil })
    let command = try Self.command(stamp: Self.stamp("one"))

    let first = Self.send(command, through: bridge)
    await waitUntil { handler.startCallCount == 1 }
    #expect(first.replies.isEmpty)
    let duplicate = try #require(await Self.receive(command, through: bridge).first)
    #expect(duplicate.status == .rejected)
    #expect(duplicate.errorCode == .ambiguousTransport)
    #expect(bridge.isBusy)
    #expect(handler.startCallCount == 1)

    handler.releaseStart(with: .accepted)
    await waitUntil { first.replies.count == 1 }
    #expect(first.replies.first?.status == .accepted)
    await waitUntil { bridge.isBusy == false }
    let replay = try #require(await Self.receive(command, through: bridge).first)
    #expect(replay.status == .accepted)
    #expect(handler.startCallCount == 1)
  }

  @Test("a failed start is reported as rejected, not accepted")
  func failedStartIsRejected() async throws {
    let handler = FakeCompanionHandler()
    handler.holdStarts = true
    let bridge = WatchPhoneBridge(bootstrap: {})
    bridge.bind(handler, accountStamp: try Self.stamp("one"), currentSelection: { nil })
    let first = Self.send(try Self.command(stamp: Self.stamp("one")), through: bridge)
    await waitUntil { handler.startCallCount == 1 }
    handler.releaseStart(with: .rejected(.preparationFailed))
    await waitUntil { first.replies.count == 1 }
    #expect(first.replies.first?.status == .rejected)
    #expect(first.replies.first?.errorCode == .rejected)
  }

  @Test("a start that outlasts the reply bound is answered as unresolved and keeps running")
  func slowStartIsBounded() async throws {
    let handler = FakeCompanionHandler()
    handler.holdStarts = true
    let bridge = WatchPhoneBridge(bootstrap: {}, startReplyBound: .milliseconds(50))
    bridge.bind(handler, accountStamp: try Self.stamp("one"), currentSelection: { nil })
    let first = Self.send(try Self.command(stamp: Self.stamp("one")), through: bridge)
    await waitUntil { first.replies.count == 1 }
    #expect(first.replies.first?.status == .rejected)
    #expect(first.replies.first?.errorCode == .ambiguousTransport)
    #expect(bridge.isBusy)
    handler.releaseStart(with: .accepted)
    await waitUntil { bridge.isBusy == false }
  }

  @Test("a different start is rejected while one start is in flight")
  func busyGate() async throws {
    let handler = FakeCompanionHandler()
    handler.holdStarts = true
    let bridge = WatchPhoneBridge(bootstrap: {})
    bridge.bind(handler, accountStamp: try Self.stamp("one"), currentSelection: { nil })
    let first = try Self.command(stamp: Self.stamp("one"))
    let second = try Self.command(stamp: Self.stamp("one"))

    _ = Self.send(first, through: bridge)
    await waitUntil { handler.startCallCount == 1 }
    let reply = try #require(await Self.receive(second, through: bridge).first)

    #expect(reply.status == .rejected)
    #expect(reply.errorCode == .rejected)
    #expect(handler.startCallCount == 1)

    handler.releaseStart(with: .accepted)
    await waitUntil { bridge.isBusy == false }
  }

  @Test("a pause during a pending start is applied after the start, not refused")
  func pauseDuringPendingStart() async throws {
    let handler = FakeCompanionHandler()
    handler.holdStarts = true
    let bridge = WatchPhoneBridge(bootstrap: {})
    let started = try Self.selection(itemID: "book-1")
    let current = SelectionBox()
    bridge.bind(handler, accountStamp: try Self.stamp("one"), currentSelection: { current.value })
    let start = try Self.command(stamp: Self.stamp("one"))
    let pause = try Self.command(
      stamp: Self.stamp("one"), selection: .audiobookshelf(itemID: "book-1", episodeID: nil),
      action: .pause)

    let startReplies = Self.send(start, through: bridge)
    await waitUntil { handler.startCallCount == 1 }
    let pauseReplies = Self.send(pause, through: bridge)
    #expect(handler.calls == [.start(started)])

    current.value = started
    handler.releaseStart(with: .accepted)
    await waitUntil { pauseReplies.replies.count == 1 && startReplies.replies.count == 1 }
    #expect(startReplies.replies.first?.status == .accepted)
    #expect(startReplies.replies.first?.errorCode == nil)
    #expect(pauseReplies.replies.first?.status == .accepted)
    #expect(handler.calls == [.start(started), .pause])
  }

  @Test("controls are rejected when their source is stale")
  func staleControl() async throws {
    let handler = FakeCompanionHandler()
    let current = try Self.selection(itemID: "book-current")
    let stale = try Self.selection(itemID: "book-stale")
    let bridge = WatchPhoneBridge(bootstrap: {})
    bridge.bind(handler, accountStamp: try Self.stamp("one"), currentSelection: { current })

    let command = try Self.command(
      stamp: Self.stamp("one"), selection: .audiobookshelf(itemID: "book-stale", episodeID: nil),
      action: .pause)
    let reply = try #require(await Self.receive(command, through: bridge).first)

    #expect(reply.status == .rejected)
    #expect(reply.errorCode == .rejected)
    #expect(handler.calls.isEmpty)
    _ = stale
  }

  @Test("account rebinding cancels the old operation and rejects old-account commands")
  func accountChangeCancellation() async throws {
    let oldHandler = FakeCompanionHandler()
    oldHandler.holdStarts = true
    let newHandler = FakeCompanionHandler()
    let bridge = WatchPhoneBridge(bootstrap: {})
    bridge.bind(oldHandler, accountStamp: try Self.stamp("one"), currentSelection: { nil })
    let oldCommand = try Self.command(stamp: Self.stamp("one"))
    _ = Self.send(oldCommand, through: bridge)
    await waitUntil { oldHandler.startCallCount == 1 }

    bridge.bind(newHandler, accountStamp: try Self.stamp("two"), currentSelection: { nil })
    let oldReply = try #require(await Self.receive(oldCommand, through: bridge).first)

    #expect(oldReply.status == .rejected)
    #expect(oldReply.errorCode == .accountUnavailable)
    #expect(newHandler.calls.isEmpty)
    #expect(bridge.isBusy == false)
    oldHandler.releaseStart(with: .rejected(.cancelled))
  }

  @Test("native-feed selections map to typed RSS identity")
  func nativeFeedMapping() async throws {
    let handler = FakeCompanionHandler()
    let bridge = WatchPhoneBridge(bootstrap: {})
    bridge.bind(handler, accountStamp: try Self.stamp("one"), currentSelection: { nil })
    let command = try Self.command(
      stamp: Self.stamp("one"),
      selection: .nativeFeed(feedID: "7", episodeID: "episode-1"))

    let reply = try #require(await Self.receive(command, through: bridge).first)
    await waitUntil { handler.startCallCount == 1 }

    #expect(reply.status == .accepted)
    #expect(handler.lastSelection?.source.rssFeedId == 7)
    #expect(handler.lastSelection?.episodeID == "episode-1")
  }

  @Test("relative skip is source-fenced and a duplicate skips once")
  func relativeSkipDeduplication() async throws {
    let handler = FakeCompanionHandler()
    let bridge = WatchPhoneBridge(bootstrap: {})
    let selection = try Self.selection(itemID: "book-1")
    bridge.bind(handler, accountStamp: try Self.stamp("one"), currentSelection: { selection })
    let command = try WatchCommand(
      accountStamp: Self.stamp("one"),
      selection: .audiobookshelf(itemID: "book-1", episodeID: nil), action: .skip, value: 30)
    let reply = try #require(await Self.receive(command, through: bridge).first)
    await waitUntil { handler.calls.contains(.skip(30)) }
    let duplicate = try #require(await Self.receive(command, through: bridge).first)
    #expect(reply.status == .accepted)
    #expect(duplicate == reply)
    #expect(handler.calls == [.skip(30)])
  }

  @Test("same-account graph replacement retains admission deduplication")
  func sameAccountRebindingDoesNotRepeatAdmittedCommand() async throws {
    let oldHandler = FakeCompanionHandler()
    let newHandler = FakeCompanionHandler()
    let bridge = WatchPhoneBridge(bootstrap: {})
    let stamp = try Self.stamp("one")
    bridge.bind(oldHandler, accountStamp: stamp, currentSelection: { nil })
    let command = try Self.command(stamp: stamp)
    let first = try #require(await Self.receive(command, through: bridge).first)
    #expect(await waitUntil("first command execution") { oldHandler.startCallCount == 1 })
    bridge.unbind()
    bridge.bind(newHandler, accountStamp: stamp, currentSelection: { nil })
    let replay = try #require(await Self.receive(command, through: bridge).first)
    #expect(replay == first)
    #expect(newHandler.calls.isEmpty)
  }

  @Test("control characters in a wire identifier never reach the handler")
  func malformedIdentifierRejected() async throws {
    let handler = FakeCompanionHandler()
    let bridge = WatchPhoneBridge(bootstrap: {})
    bridge.bind(handler, accountStamp: try Self.stamp("one"), currentSelection: { nil })
    let command = try Self.command(stamp: Self.stamp("one"))
    let encoded = try WatchWireCodec.encode(command)
    let text = try #require(String(data: encoded, encoding: .utf8))
    let malformed = text.replacingOccurrences(of: "book-1", with: "book\\u0000-1")
    var replies: [[String: Any]] = []
    bridge.receive(message: [WatchPhoneBridge.payloadKey: Data(malformed.utf8)]) { replies.append($0) }
    await waitUntil { !replies.isEmpty }
    #expect(replies.count == 1)
    #expect(replies.first?.isEmpty == true)
    #expect(handler.calls.isEmpty)
  }

  private final class SelectionBox {
    var value: CompanionSelection?
  }

  private final class ReplyBox {
    var replies: [WatchReply] = []
  }

  /// Sends without waiting for the reply, for commands whose reply is held back on purpose.
  private static func send(_ command: WatchCommand, through bridge: WatchPhoneBridge) -> ReplyBox {
    let box = ReplyBox()
    let data = try! WatchWireCodec.encode(command)
    bridge.receive(message: [WatchPhoneBridge.payloadKey: data]) { message in
      guard let data = message[WatchPhoneBridge.payloadKey] as? Data,
        let reply = try? WatchWireCodec.decode(WatchReply.self, from: data)
      else { return }
      box.replies.append(reply)
    }
    return box
  }

  private final class DatabaseAvailability {
    var value = false
  }

  private final class Probe {
    var value = 0
  }

  private final class FakeCompanionHandler: CompanionPlaybackActionHandling {
    enum Call: Equatable {
      case start(CompanionSelection)
      case pause
      case resume
      case seek(Double)
      case rate(Double)
      case skip(Double)
    }

    var calls: [Call] = []
    var holdStarts = false
    var startCallCount: Int { calls.reduce(into: 0) { if case .start = $1 { $0 += 1 } } }
    var lastSelection: CompanionSelection? {
      calls.reversed().compactMap {
        if case .start(let selection) = $0 { return selection }
        return nil
      }.first
    }
    private var startContinuation: CheckedContinuation<CompanionPlaybackActionResult, Never>?

    func start(
      source: PodcastSourceIdentity, episodeID: String?
    ) async -> CompanionPlaybackActionResult {
      let selection = CompanionSelection(source: source, episodeID: episodeID)
      calls.append(.start(selection))
      guard holdStarts else { return .accepted }
      return await withCheckedContinuation { continuation in
        startContinuation = continuation
      }
    }

    func start(_ selection: CompanionSelection) async -> CompanionPlaybackActionResult {
      await start(source: selection.source, episodeID: selection.episodeID)
    }

    func pause() -> CompanionPlaybackActionResult {
      calls.append(.pause)
      return .accepted
    }

    func resume() -> CompanionPlaybackActionResult {
      calls.append(.resume)
      return .accepted
    }

    func seek(toGlobalOffset offset: Double) -> CompanionPlaybackActionResult {
      calls.append(.seek(offset))
      return .accepted
    }

    func skip(by seconds: Double) -> CompanionPlaybackActionResult {
      calls.append(.skip(seconds))
      return .accepted
    }

    func setRate(_ rate: Double) -> CompanionPlaybackActionResult {
      calls.append(.rate(rate))
      return .accepted
    }

    func releaseStart(with result: CompanionPlaybackActionResult) {
      holdStarts = false
      startContinuation?.resume(returning: result)
      startContinuation = nil
    }
  }

  private static func stamp(_ suffix: String) throws -> WatchAccountStamp {
    try WatchAccountStamp(
      accountIdentityHash: "account-\(suffix)", serverIdentityHash: "server-\(suffix)")
  }

  private static func selection(itemID: String) throws -> CompanionSelection {
    try CompanionSelection(
      source: #require(PodcastSourceIdentity.abs(itemId: itemID)))
  }

  private static func command(
    stamp: WatchAccountStamp,
    selection: WatchSelection = .audiobookshelf(itemID: "book-1", episodeID: nil),
    action: WatchCommandAction = .play,
    value: Double? = nil
  ) throws -> WatchCommand {
    try WatchCommand(
      accountStamp: stamp, selection: selection, action: action, value: value)
  }

  private static func nativeProgress(
    install: String, sequence: UInt64, position: Double
  ) throws -> Data {
    let entry = try WatchNativeProgressEntry(
      selection: try WatchNativeSelection(feedID: "7", episodeID: "e1"),
      position: position, lastListenedAt: Date(timeIntervalSinceReferenceDate: 900_000_000),
      isFinished: false, duration: nil)
    let report = try WatchNativeProgressReport(
      watchInstallID: install, sequence: sequence, entries: [entry])
    return try WatchWireCodec.encode(report)
  }

  private static func receive(
    _ command: WatchCommand, through bridge: WatchPhoneBridge
  ) async -> [WatchReply] {
    let data = try! WatchWireCodec.encode(command)
    var replies: [WatchReply] = []
    bridge.receive(message: [WatchPhoneBridge.payloadKey: data]) { message in
      guard let data = message[WatchPhoneBridge.payloadKey] as? Data,
        let reply = try? WatchWireCodec.decode(WatchReply.self, from: data)
      else { return }
      replies.append(reply)
    }
    await waitUntil { replies.isEmpty == false }
    return replies
  }

}

@MainActor
@Suite("Watch phone browse routing", .serialized)
struct WatchPhoneBrowseRoutingTests {
  @Test("browse request is routed through its dedicated bounded transport key")
  func routesBrowseRequest() async throws {
    let bridge = WatchPhoneBridge(bootstrap: {})
    let stamp = try WatchAccountStamp(accountIdentityHash: "account", serverIdentityHash: "server")
    let request = try WatchBrowseRequest(accountStamp: stamp, scope: .shows, pageSize: 10)
    let payload = try WatchWireCodec.encode(request)
    var received: WatchBrowseRequest?
    let page = try WatchBrowsePage(page: 0, pageSize: 10, rows: [], nextPage: nil, isComplete: true, generation: 1)
    let expected = try WatchBrowseReply(request: request, status: .accepted, page: page)
    let endpoint = WatchPhoneBrowseEndpoint(
      currentStamp: { stamp }, isAvailable: { true },
      load: { request in
        received = request
        return expected
      })
    bridge.browseEndpoint = { endpoint }
    var response: WatchBrowseReply?

    bridge.receive(message: [WatchBrowseTransportKey.request: payload]) { reply in
      if let data = reply[WatchTransportKey.browseReply] as? Data {
        response = try? WatchWireCodec.decode(WatchBrowseReply.self, from: data)
      }
    }
    #expect(await waitUntil("browse request routed") { received != nil && response != nil })
    #expect(received == request)
    #expect(response == expected)
  }

  @Test("oversized browse requests are rejected before the app handler runs")
  func boundsBeforeHandler() async throws {
    let bridge = WatchPhoneBridge(bootstrap: {})
    var called = false
    bridge.browseEndpoint = {
      called = true
      return nil
    }
    bridge.receive(
      message: [WatchBrowseTransportKey.request: Data(repeating: 0, count: WatchBrowseLimits.maxWireBytes + 1)]
    ) { _ in }
    #expect(await awaitQuiescence("oversized request stays rejected", stableFor: 10) { String(called) }.isObserved)
    #expect(called == false)
  }
}

@MainActor
@Suite("Watch phone handoff and playing-report routing", .serialized)
struct WatchPhoneHandoffRoutingTests {
  private let stamp = try! WatchAccountStamp(accountIdentityHash: "account", serverIdentityHash: "server")

  private func endpoint(pauses: @escaping @MainActor () -> Void = {}) -> WatchPhoneHandoffEndpoint {
    WatchPhoneHandoffEndpoint(
      authenticatedStamp: { stamp },
      peer: WatchPhoneHandoffEndpoint.Peer(
        state: { nil },
        pause: {
          pauses()
          return nil
        }, flush: {}))
  }

  @Test("a handoff request is routed to its endpoint under the v2 key and answered under it")
  func routesHandoffRequest() async throws {
    let bridge = WatchPhoneBridge(bootstrap: {}, isDatabaseAvailable: { true })
    var pauses = 0
    let phone = endpoint { pauses += 1 }
    bridge.handoffEndpoint = { phone }
    let request = try WatchHandoffRequest(accountStamp: stamp, selection: nil)
    var reply: WatchHandoffReply?

    bridge.receive(message: [WatchHandoffRequest.transportKey: try WatchWireCodec.encode(request)]) { message in
      if let data = message[WatchHandoffRequest.transportKey] as? Data {
        reply = try? WatchWireCodec.decode(WatchHandoffReply.self, from: data)
      }
    }

    #expect(await awaitCondition("the handoff to be answered", until: { reply != nil }).isObserved)
    #expect(reply == .idle(request))
    #expect(pauses == 1)
  }

  @Test("an oversized handoff request or one with no bound endpoint gets an empty reply")
  func unroutableHandoffRequestGetsAnEmptyReply() async throws {
    let bridge = WatchPhoneBridge(bootstrap: {}, isDatabaseAvailable: { true })
    var replies: [[String: Any]] = []
    bridge.receive(
      message: [WatchHandoffRequest.transportKey: Data(repeating: 0, count: WatchHandoffRequest.maxWireBytes + 1)]
    ) { replies.append($0) }
    let request = try WatchHandoffRequest(accountStamp: stamp, selection: nil)
    bridge.receive(message: [WatchHandoffRequest.transportKey: try WatchWireCodec.encode(request)]) {
      replies.append($0)
    }

    #expect(
      await awaitCondition(
        "both requests to be answered", observing: { "\(replies.count) replies" },
        until: { replies.count == 2 }
      ).isObserved)
    #expect(replies.allSatisfy { $0.isEmpty })
  }

  @Test("the retired ownership keys are no longer routed")
  func retiredKeysAreDropped() async {
    let bridge = WatchPhoneBridge(bootstrap: {}, isDatabaseAvailable: { true })
    var replies: [[String: Any]] = []
    for key in ["whirr.watch.ownership.query.v1", "whirr.watch.ownership.advertisement.v1"] {
      bridge.receive(message: [key: Data("{}".utf8)]) { replies.append($0) }
    }
    #expect(
      await awaitCondition(
        "both retired keys to be answered", observing: { "\(replies.count) replies" },
        until: { replies.count == 2 }
      ).isObserved)
    #expect(replies.allSatisfy { $0.isEmpty })
  }

  @Test("a playing report from the Watch's application context reaches the runtime for the bound account")
  func storesAReportForTheBoundAccount() async throws {
    let bridge = WatchPhoneBridge(bootstrap: {}, isDatabaseAvailable: { true })
    bridge.authenticatedStamp = { stamp }
    var stored: [WatchPlayingReport] = []
    bridge.storePlayingReport = { stored.append($0) }
    let report = try WatchPlayingReport(
      accountStamp: stamp, selection: WatchABSSelection(itemID: "book", episodeID: nil), playing: true,
      observedAt: Date(timeIntervalSinceReferenceDate: 100))

    bridge.receive(message: [WatchPlayingReport.transportKey: try WatchWireCodec.encode(report)]) { _ in }

    #expect(
      await awaitCondition(
        "the report to be stored", observing: { "\(stored.count) stored" },
        until: { stored.count == 1 }
      ).isObserved)
    #expect(stored.first == report)
    #expect(bridge.hasBootstrapped)
  }

  @Test("a report for another account, an oversized one and a malformed one are dropped")
  func dropsUnacceptableReports() async throws {
    let bridge = WatchPhoneBridge(bootstrap: {}, isDatabaseAvailable: { true })
    bridge.authenticatedStamp = { stamp }
    var stored = 0
    bridge.storePlayingReport = { _ in stored += 1 }
    let other = try WatchAccountStamp(accountIdentityHash: "other", serverIdentityHash: "server")
    let foreign = try WatchPlayingReport(
      accountStamp: other, selection: nil, playing: false, observedAt: Date(timeIntervalSinceReferenceDate: 100))
    let key = WatchPlayingReport.transportKey

    bridge.receive(message: [key: try WatchWireCodec.encode(foreign)]) { _ in }
    bridge.receive(message: [key: Data(repeating: 0, count: WatchPlayingReport.maxWireBytes + 1)]) { _ in }
    bridge.receive(message: [key: Data("nonsense".utf8)]) { _ in }

    #expect(await awaitQuiescence("reports stay dropped", stableFor: 10) { String(stored) }.isObserved)
    #expect(stored == 0)
  }

  @Test("one application context carrying both reports reaches both handlers")
  func routesPlayingAndStatusReportsTogether() async throws {
    let bridge = WatchPhoneBridge(bootstrap: {}, isDatabaseAvailable: { true })
    bridge.authenticatedStamp = { stamp }
    var playingStored: [WatchPlayingReport] = []
    var statusStored: [WatchStatusReport] = []
    bridge.storePlayingReport = { playingStored.append($0) }
    bridge.storeStatusReport = { statusStored.append($0) }
    let checkedAt = Date(timeIntervalSinceReferenceDate: 100)
    let playing = try WatchPlayingReport(
      accountStamp: stamp, selection: nil, playing: false, observedAt: checkedAt)
    let status = try WatchStatusReport(
      accountStamp: stamp, health: .healthy, checkedAt: checkedAt, reportedAt: checkedAt)

    bridge.receive(message: [
      WatchPlayingReport.transportKey: try WatchWireCodec.encode(playing),
      WatchStatusReport.transportKey: try WatchWireCodec.encode(status),
    ]) { _ in }

    #expect(
      await awaitCondition(
        "both reports to be stored", observing: { "\(playingStored.count)/\(statusStored.count)" },
        until: { playingStored.count == 1 && statusStored.count == 1 }
      ).isObserved)
    #expect(playingStored.first == playing)
    #expect(statusStored.first == status)
  }

  @Test("a status report reaches the setup model only for the bound account")
  func routesAStatusReportForTheBoundAccount() async throws {
    let bridge = WatchPhoneBridge(bootstrap: {}, isDatabaseAvailable: { true })
    bridge.authenticatedStamp = { stamp }
    var stored: [WatchStatusReport] = []
    bridge.storeStatusReport = { stored.append($0) }
    let checkedAt = Date(timeIntervalSinceReferenceDate: 200)
    let report = try WatchStatusReport(
      accountStamp: stamp, health: .serverUnreachable, checkedAt: checkedAt, reportedAt: checkedAt)

    bridge.receive(message: [WatchStatusReport.transportKey: try WatchWireCodec.encode(report)]) { _ in }

    #expect(
      await awaitCondition(
        "the status report to be stored", observing: { "\(stored.count) stored" },
        until: { stored.count == 1 }
      ).isObserved)
    #expect(stored.first == report)
  }

  @Test("a status report for another account, an oversized one and a malformed one are dropped")
  func dropsUnacceptableStatusReports() async throws {
    let bridge = WatchPhoneBridge(bootstrap: {}, isDatabaseAvailable: { true })
    bridge.authenticatedStamp = { stamp }
    var stored = 0
    bridge.storeStatusReport = { _ in stored += 1 }
    let other = try WatchAccountStamp(accountIdentityHash: "other", serverIdentityHash: "server")
    let foreign = try WatchStatusReport(accountStamp: other, reportedAt: Date(timeIntervalSinceReferenceDate: 300))
    let signedOut = try WatchStatusReport(accountStamp: nil, reportedAt: Date(timeIntervalSinceReferenceDate: 300))
    let key = WatchStatusReport.transportKey

    bridge.receive(message: [key: try WatchWireCodec.encode(foreign)]) { _ in }
    bridge.receive(message: [key: try WatchWireCodec.encode(signedOut)]) { _ in }
    bridge.receive(message: [key: Data(repeating: 0, count: WatchStatusReport.maxWireBytes + 1)]) { _ in }
    bridge.receive(message: [key: Data("nonsense".utf8)]) { _ in }

    #expect(await awaitQuiescence("status reports stay dropped", stableFor: 10) { String(stored) }.isObserved)
    #expect(stored == 0)
  }
}
