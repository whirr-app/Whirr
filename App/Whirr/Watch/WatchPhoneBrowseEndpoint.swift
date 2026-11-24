import Foundation
import WatchProtocol

/// Transport envelopes for the account-scoped persisted browse model.
@MainActor
final class WatchPhoneBrowseEndpoint {
  private let load: @MainActor (WatchBrowseRequest) async -> WatchBrowseReply
  private let currentStamp: @MainActor () -> WatchAccountStamp?
  private let isAvailable: @MainActor () -> Bool

  convenience init(
    model: WatchPhoneBrowseModel,
    currentStamp: @escaping @MainActor () -> WatchAccountStamp?,
    isAvailable: @escaping @MainActor () -> Bool
  ) {
    self.init(currentStamp: currentStamp, isAvailable: isAvailable, load: { await model.reply(for: $0) })
  }

  init(
    currentStamp: @escaping @MainActor () -> WatchAccountStamp?,
    isAvailable: @escaping @MainActor () -> Bool,
    load: @escaping @MainActor (WatchBrowseRequest) async -> WatchBrowseReply
  ) {
    self.load = load
    self.currentStamp = currentStamp
    self.isAvailable = isAvailable
  }

  func receive(_ data: Data, replyHandler: @escaping WatchPhoneBridge.ReplyHandler) async {
    let reply = await WatchPhoneRequestRunner.run(
      WatchBrowseRequest.self, data: data, replyKey: WatchTransportKey.browseReply,
      currentStamp: currentStamp, requestStamp: { $0.accountStamp },
      rejection: { _, _ -> WatchBrowseReply? in nil },
      action: { request in
        // Preserve the post-admission hop and availability check before loading persisted data.
        await Task { @MainActor in
          guard self.isAvailable() else { return nil as WatchBrowseReply? }
          return await self.load(request)
        }.value
      })
    replyHandler(reply)
  }
}
