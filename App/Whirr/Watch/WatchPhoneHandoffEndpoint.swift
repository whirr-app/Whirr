import AppModel
import Foundation
import Persistence
import WatchProtocol

/// Answers the Watch's request to pause: the phone and Watch are peers, so this holds no
/// lease and writes no journal. It pauses whatever is loaded, keeps it loaded, replies with where
/// it was, and only then flushes progress through the existing sync route.
@MainActor
final class WatchPhoneHandoffEndpoint {
  nonisolated static let payloadKey = WatchHandoffRequest.transportKey
  typealias ReplyHandler = ([String: Any]) -> Void

  struct Peer {
    /// The loaded title and position without pausing, for a repeated request.
    var state: @MainActor () -> CompanionPlaybackPeerState?
    /// Pauses the loaded title and keeps it loaded.
    var pause: @MainActor () -> CompanionPlaybackPeerState?
    var flush: @MainActor () async -> Void
  }

  private let authenticatedStamp: @MainActor () -> WatchAccountStamp?
  private let peer: Peer
  private let clock: @MainActor () -> Date
  private var responder = WatchHandoffResponder()
  private var responderStamp: WatchAccountStamp?

  init(
    authenticatedStamp: @escaping @MainActor () -> WatchAccountStamp?, peer: Peer,
    clock: @escaping @MainActor () -> Date = { Date() }
  ) {
    self.authenticatedStamp = authenticatedStamp
    self.peer = peer
    self.clock = clock
  }

  /// An account change forgets every admitted request.
  func reset() {
    responder.reset()
    responderStamp = nil
  }

  /// The bridge bounds the payload's size; a malformed one gets an empty reply, which the Watch
  /// treats as no answer.
  func admit(data: Data, replyHandler: @escaping ReplyHandler) async {
    guard let request = WatchPhoneRequestRunner.decode(WatchHandoffRequest.self, from: data) else {
      replyHandler([:])
      return
    }
    let stamp = authenticatedStamp()
    if stamp != responderStamp {
      responder.reset()
      responderStamp = stamp
    }
    switch responder.admit(request, authenticatedAccountStamp: stamp, now: clock()) {
    case .reject(let reply):
      send(reply, to: replyHandler)
    case .report(let request):
      send(Self.reply(to: request, state: peer.state(), now: clock()), to: replyHandler)
    case .pause(let request):
      let state = peer.pause()
      send(Self.reply(to: request, state: state, now: clock()), to: replyHandler)
      // After the reply, so the Watch's 3 s wait never includes a network round trip.
      if state != nil { await peer.flush() }
    }
  }

  /// A native feed title cannot be named on the wire, so it replies with no selection (which still
  /// tells the Watch the phone paused). `lastListenedAt` is stamped only when the title was
  /// playing at the request, so a title that was already paused cannot outrank a later listen.
  static func reply(
    to request: WatchHandoffRequest, state: CompanionPlaybackPeerState?, now: Date
  ) -> WatchHandoffReply {
    guard let state else { return .idle(request) }
    let reply = try? WatchHandoffReply.paused(
      request, selection: WatchPhoneHandoffAsker.wireSelection(state.selection),
      position: state.positionSeconds, lastListenedAt: state.wasPlaying ? now : nil)
    return reply ?? .idle(request)
  }

  private func send(_ reply: WatchHandoffReply, to replyHandler: ReplyHandler) {
    replyHandler(WatchPhoneRequestRunner.reply(reply, key: Self.payloadKey))
  }
}
