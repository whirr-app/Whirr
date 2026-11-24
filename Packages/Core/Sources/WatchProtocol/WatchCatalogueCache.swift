import Foundation

public enum WatchCatalogueCacheError: Error, Codable, Sendable, Equatable {
  case invalidContext
  case foreignAccount
  case missingAccount
  case staleContext
  case accountResetRequired
}

public enum WatchCatalogueCacheUpdate: Sendable, Equatable {
  case accepted(WatchCatalogueCache)
  case rejected(WatchCatalogueCacheError)
  case cleared(WatchCatalogueCache)
}

/// A pure value holding the last accepted phone catalogue. Account changes are explicit: a
/// signed-out context clears this value, and a caller must then use `resetAccount(to:)` before a
/// new signed-in context can establish a new identity stamp.
public struct WatchCatalogueCache: WatchWireValue, Equatable {
  public let expectedAccountStamp: WatchAccountStamp?
  public let snapshot: WatchCatalogueSnapshot?
  /// Monotonic context watermark retained after signed-out clearing and account reset.
  public let lastContextDate: Date?

  public init(
    expectedAccountStamp: WatchAccountStamp? = nil,
    snapshot: WatchCatalogueSnapshot? = nil,
    lastContextDate: Date? = nil
  ) throws {
    try expectedAccountStamp?.validate()
    let watermark = lastContextDate ?? snapshot?.generatedAt
    if let watermark, watermark.timeIntervalSinceReferenceDate.isFinite == false {
      throw WatchCatalogueCacheError.invalidContext
    }
    if let snapshot {
      guard let expectedAccountStamp, snapshot.accountStamp == expectedAccountStamp else {
        throw WatchCatalogueCacheError.invalidContext
      }
      guard let watermark, snapshot.generatedAt <= watermark else {
        throw WatchCatalogueCacheError.invalidContext
      }
      _ = try WatchWireCodec.encode(snapshot)
    }
    self.expectedAccountStamp = expectedAccountStamp
    self.snapshot = snapshot
    self.lastContextDate = watermark
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      expectedAccountStamp: container.decodeIfPresent(WatchAccountStamp.self, forKey: .expectedAccountStamp),
      snapshot: container.decodeIfPresent(WatchCatalogueSnapshot.self, forKey: .snapshot),
      lastContextDate: container.decodeIfPresent(Date.self, forKey: .lastContextDate))
  }

  /// Apply a latest-only context. A signed-out context is the only incoming payload allowed to
  /// omit an account stamp; it clears the cache and permits a later explicit reset.
  public func applying(_ context: WatchCatalogueSnapshot, now: Date = Date()) -> WatchCatalogueCacheUpdate {
    guard now.timeIntervalSinceReferenceDate.isFinite else { return .rejected(.invalidContext) }
    guard context.generatedAt.timeIntervalSince(now) <= WatchProtocolVersion.commandFutureSkewTolerance else {
      return .rejected(.invalidContext)
    }
    guard (try? context.validate()) != nil, (try? WatchWireCodec.encode(context)) != nil else {
      return .rejected(.invalidContext)
    }
    if let lastContextDate, context.generatedAt <= lastContextDate {
      return .rejected(.staleContext)
    }
    if context.isSignedOut {
      return .cleared(
        try! WatchCatalogueCache(
          expectedAccountStamp: nil, snapshot: nil, lastContextDate: context.generatedAt))
    }
    guard let incoming = context.accountStamp else { return .rejected(.missingAccount) }
    guard let expected = expectedAccountStamp else { return .rejected(.accountResetRequired) }
    guard incoming == expected else { return .rejected(.foreignAccount) }
    return .accepted(
      try! WatchCatalogueCache(
        expectedAccountStamp: expected, snapshot: context, lastContextDate: context.generatedAt))
  }

  /// Use only for a fresh, authoritative context received from the paired companion. This is the
  /// explicit escape hatch for a coalesced logout/login where the empty signed-out context was not
  /// delivered separately.
  public func resetAndApplyAuthoritative(
    _ context: WatchCatalogueSnapshot,
    now: Date = Date()
  ) -> WatchCatalogueCacheUpdate {
    guard now.timeIntervalSinceReferenceDate.isFinite,
      context.generatedAt.timeIntervalSinceReferenceDate.isFinite,
      context.generatedAt.timeIntervalSince(now) <= WatchProtocolVersion.commandFutureSkewTolerance,
      (try? context.validate()) != nil,
      (try? WatchWireCodec.encode(context)) != nil
    else { return .rejected(.invalidContext) }
    guard let stamp = context.accountStamp, !context.isSignedOut else {
      return .rejected(.missingAccount)
    }
    return resetAccount(to: stamp).applying(context, now: now)
  }

  /// Establishes a new account identity after logout or an explicit owner decision.
  /// Existing catalogue rows are discarded immediately.
  public func resetAccount(to stamp: WatchAccountStamp) -> WatchCatalogueCache {
    try! WatchCatalogueCache(
      expectedAccountStamp: stamp, snapshot: nil, lastContextDate: lastContextDate)
  }

  public func signedOut() -> WatchCatalogueCache {
    try! WatchCatalogueCache(
      expectedAccountStamp: nil, snapshot: nil, lastContextDate: lastContextDate)
  }

  private enum CodingKeys: String, CodingKey { case expectedAccountStamp, snapshot, lastContextDate }
  public static let maxWireBytes = 64 * 1024
  public func validate() throws {
    _ = try Self(expectedAccountStamp: expectedAccountStamp, snapshot: snapshot, lastContextDate: lastContextDate)
  }
}
