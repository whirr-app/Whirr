import Foundation
import WatchProtocol

/// Shared bounded envelope work; endpoint actions retain their own admission and lifetime fences.
@MainActor
enum WatchPhoneRequestRunner {
  enum Failure {
    case decode, accountUnavailable, action, encode
  }

  static func decode<Request: WatchWireValue>(_ type: Request.Type, from data: Data) -> Request? {
    try? WatchWireCodec.decode(type, from: data)
  }

  static func reply<Reply: WatchWireValue>(_ value: Reply, key: String) -> [String: Any] {
    guard let data = try? WatchWireCodec.encode(value) else { return [:] }
    return [key: data]
  }

  static func run<Request: WatchWireValue, Reply: WatchWireValue>(
    _ type: Request.Type,
    data: Data,
    replyKey: String,
    currentStamp: @MainActor () -> WatchAccountStamp?,
    requestStamp: @MainActor (Request) -> WatchAccountStamp,
    rejection: @MainActor (Request?, Failure) -> Reply?,
    action: @MainActor (Request) async throws -> Reply?
  ) async -> [String: Any] {
    func reject(_ request: Request?, _ failure: Failure) -> [String: Any] {
      guard let value = rejection(request, failure) else { return [:] }
      return Self.reply(value, key: replyKey)
    }

    guard let request = decode(type, from: data) else { return reject(nil, .decode) }
    guard let stamp = currentStamp(), requestStamp(request) == stamp else {
      return reject(request, .accountUnavailable)
    }
    let reply: Reply
    do {
      guard let value = try await action(request) else { return reject(request, .action) }
      reply = value
    } catch {
      return reject(request, .action)
    }
    guard let encoded = try? WatchWireCodec.encode(reply) else { return reject(request, .encode) }
    return [replyKey: encoded]
  }
}
