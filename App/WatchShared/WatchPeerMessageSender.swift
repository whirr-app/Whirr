import Foundation
import WatchConnectivity
import WatchProtocol

/// One companion request/reply: send bounded bytes under one transport key, wait a bounded time for
/// a bounded reply under another, and report which of `reply`/`failed`/`timedOut` happened. The
/// caller keeps admission, fences and outcome mapping, which is what actually differs per endpoint.
///
/// `cancel()` resolves the request as `.failed`, for an account change or another command replacing
/// this one. A request is never retried with a new id here: an unanswerable request is unresolved.
@MainActor
final class CompanionRequest {
  enum Outcome: Sendable, Equatable {
    case reply(Data)
    case failed
    case timedOut
  }

  private let gate = WatchReplyGate<Outcome>()
  private let cancelsOnTaskCancellation: Bool
  private var timeout: Task<Void, Never>?

  /// `cancelsOnTaskCancellation` resolves the request as `.failed` when the calling task is
  /// cancelled. The command and browse paths deliberately do not: their caller may outlive the
  /// view that started it, and an uncertain delivery must stay unresolved rather than retry.
  init(cancelsOnTaskCancellation: Bool = false) {
    self.cancelsOnTaskCancellation = cancelsOnTaskCancellation
  }

  func cancel() {
    timeout?.cancel()
    gate.finish(.failed)
  }

  func send(
    _ data: Data, key: String, replyKey: String, limit: Int, timeout wait: Duration,
    in session: WCSession
  ) async -> Outcome {
    let gate = self.gate
    let timeout = Task {
      try? await Task.sleep(for: wait)
      if !Task.isCancelled { gate.finish(.timedOut) }
    }
    self.timeout = timeout
    defer {
      timeout.cancel()
      self.timeout = nil
    }
    session.sendMessage(
      [key: data],
      replyHandler: { reply in
        guard let payload = reply[replyKey] as? Data, payload.count <= limit else {
          gate.finish(.failed)
          return
        }
        gate.finish(.reply(payload))
      }, errorHandler: { _ in gate.finish(.failed) })
    if cancelsOnTaskCancellation {
      return await withTaskCancellationHandler {
        await gate.wait() ?? .timedOut
      } onCancel: {
        gate.finish(.failed)
      }
    }
    return await gate.wait() ?? .timedOut
  }
}

@MainActor
enum WatchPeerMessageSender {
  static func send(
    _ data: Data, key: String = WatchHandoffRequest.transportKey,
    replyLimit: Int = WatchHandoffLimits.maxWireBytes, timeout wait: Duration = .seconds(8)
  ) async -> Data? {
    let session = WCSession.default
    guard data.count <= WatchHandoffLimits.maxWireBytes,
      session.activationState == .activated, session.isReachable
    else { return nil }
    let request = CompanionRequest(cancelsOnTaskCancellation: true)
    guard
      case .reply(let payload) = await request.send(
        data, key: key, replyKey: key, limit: replyLimit, timeout: wait, in: session)
    else { return nil }
    return payload
  }
}
