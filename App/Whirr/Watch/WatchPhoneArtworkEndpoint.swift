import ABSApi
import Foundation
import WatchProtocol

/// Artwork is optional, independently bounded, and re-admitted after every asynchronous load.
@MainActor
final class WatchPhoneArtworkEndpoint {
  /// Inside the Watch's 8 s reply timeout, so a request that gets no slot is refused before the
  /// Watch gives up on it rather than loaded for nobody.
  /// `nonisolated` because a default argument is evaluated outside the initialiser's isolation.
  nonisolated static let defaultSlotWait: Duration = .seconds(6)
  private let currentStamp: @MainActor () -> WatchAccountStamp?
  private let load: @MainActor (WatchArtworkRequest) async -> Data?
  private let slotWait: Duration
  private let gate = ServerRequestGate(maximumConcurrent: 2)

  init(
    currentStamp: @escaping @MainActor () -> WatchAccountStamp?,
    load: @escaping @MainActor (WatchArtworkRequest) async -> Data?,
    slotWait: Duration = WatchPhoneArtworkEndpoint.defaultSlotWait
  ) {
    self.currentStamp = currentStamp
    self.load = load
    self.slotWait = slotWait
  }

  func receive(_ data: Data, replyHandler: @escaping WatchPhoneBridge.ReplyHandler) async {
    guard let request = try? WatchWireCodec.decode(WatchArtworkRequest.self, from: data),
      currentStamp() == request.accountStamp
    else {
      replyHandler([:])
      return
    }
    // A load the Watch abandoned keeps its slot until it finishes, so wait for one briefly
    // instead of refusing outright.
    let gate = gate
    let acquiring = Task { try await gate.acquire() }
    let wait = slotWait
    let deadline = Task {
      try? await Task.sleep(for: wait)
      acquiring.cancel()
    }
    let permit = try? await acquiring.value
    deadline.cancel()
    guard let permit, currentStamp() == request.accountStamp else {
      await permit?.release()
      replyHandler([:])
      return
    }
    let image = await load(request)
    await permit.release()
    guard !Task.isCancelled, currentStamp() == request.accountStamp,
      let encoded = try? WatchWireCodec.encode(WatchArtworkReply(request: request, imageData: image))
    else {
      replyHandler([:])
      return
    }
    replyHandler([WatchTransportKey.artworkReply: encoded])
  }
}
