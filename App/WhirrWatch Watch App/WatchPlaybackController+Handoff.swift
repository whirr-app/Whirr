import ABSApi
import Foundation
import Observation
import PlayerCore
import WatchPlayback
import WatchProtocol

/// Pausing the Watch for the phone, and asking a playing phone to pause for the Watch.
extension WatchPlaybackController {
  /// The phone is starting. Whatever is loaded pauses and stays loaded, and the reply says
  /// where it was. A repeated request reports without pausing again. Returns the encoded reply.
  func answerHandoff(_ payload: Data) async -> Data? {
    guard let request = try? WatchWireCodec.decode(WatchHandoffRequest.self, from: payload) else { return nil }
    let reply: WatchHandoffReply
    switch handoffResponder.admit(request, authenticatedAccountStamp: authenticatedStamp, now: .now) {
    case .reject(let rejected):
      reply = rejected
    case .pause(let admitted):
      // Pausing also supersedes a Watch start still in flight. The phone has the listener now, so
      // the end of an interruption must not start the Watch again.
      interruptionPolicy.listenerActed()
      await send(.pause(.peer))?.value
      reply = currentHandoffState(admitted)
    case .report(let admitted):
      reply = currentHandoffState(admitted)
    }
    return try? WatchWireCodec.encode(reply)
  }
  /// An account change forgets every admitted handoff request.
  func resetHandoff() {
    handoffResponder.reset()
  }
  /// Forgets when each title was last listened to, as an account change must. An outbound
  /// handoff ask belongs to the account that sent it.
  func forgetListening() {
    cancelPeerHandoff()
    listening.reset()
    listenedRevision &+= 1
  }
  /// Sends a pause ask without waiting for the reply. The session owns the task so logout can
  /// cancel it; a newer ask supersedes the older one, as the phone reads only the newest.
  private func sendPeerHandoff(_ data: Data) {
    cancelPeerHandoff()
    model.session.lifecycle.peerHandoff = Task { _ = await WatchPeerMessageSender.send(data) }
  }
  func cancelPeerHandoff() {
    model.session.lifecycle.peerHandoff?.cancel()
    model.session.lifecycle.peerHandoff = nil
  }
  /// A Watch start asks the phone to pause only if it reports playing. For the phone's own
  /// title it waits briefly and starts where the phone was, when the phone was listening to it;
  /// for another title it does not wait. Returns the position to start from, if any.
  func askPhoneToPause(starting selection: WatchSelection) async -> Double? {
    guard let (request, data) = pauseRequest(for: selection) else { return nil }
    guard companion.currentItem?.selection == selection else {
      sendPeerHandoff(data)
      return nil
    }
    guard let payload = await WatchPeerMessageSender.send(data, timeout: Self.handoffWait),
      let reply = try? WatchWireCodec.decode(WatchHandoffReply.self, from: payload),
      reply.handoffID == request.handoffID, reply.lastListenedAt != nil
    else { return nil }
    return reply.position(for: request.selection)
  }
  /// A resume asks a playing phone to pause without waiting for it.
  func tellPhoneToPause(_ selection: WatchSelection) {
    guard let (_, data) = pauseRequest(for: selection) else { return }
    sendPeerHandoff(data)
  }
  /// The request that asks the phone to pause, and its encoding; `nil` unless the phone reports playing.
  private func pauseRequest(for selection: WatchSelection) -> (WatchHandoffRequest, Data)? {
    guard companion.phoneReportsPlaying, let stamp = authenticatedStamp,
      let request = try? WatchHandoffRequest(
        accountStamp: stamp, selection: try? WatchABSSelection(selection: selection)),
      let data = try? WatchWireCodec.encode(request)
    else { return nil }
    return (request, data)
  }
  private func currentHandoffState(_ request: WatchHandoffRequest) -> WatchHandoffReply {
    guard let selection = currentSelection else { return .idle(request) }
    let listenedAt = audio.isPlaying ? Date.now : listening.lastListened(selection)
    return
      (try? WatchHandoffReply.paused(
        request, selection: try? WatchABSSelection(selection: selection), position: audio.position,
        lastListenedAt: listenedAt)) ?? .idle(request)
  }
}
