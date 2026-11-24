import GRDB

/// A narrow device-owned projection for feeds whose credential setup did not finish.
public protocol NativeFeedRecoveryReading: Sendable {
  func observeRecoveryFeedIDs() -> AsyncStream<Set<Int64>>
  func recoveryRequired(feedID: Int64) async throws -> Bool
}

public struct NoOpNativeFeedRecoveryReading: NativeFeedRecoveryReading {
  public init() {}

  public func observeRecoveryFeedIDs() -> AsyncStream<Set<Int64>> {
    AsyncStream { continuation in
      continuation.yield([])
      continuation.finish()
    }
  }

  public func recoveryRequired(feedID _: Int64) async throws -> Bool { false }
}

extension RSSFeedStore: NativeFeedRecoveryReading {
  public func observeRecoveryFeedIDs() -> AsyncStream<Set<Int64>> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      Set(try Int64.fetchAll(db, sql: "SELECT feedId FROM rssFeedRecovery"))
    }
  }

  public func recoveryRequired(feedID: Int64) async throws -> Bool {
    try await database.readAsync { db in
      try Bool.fetchOne(
        db,
        sql: "SELECT EXISTS (SELECT 1 FROM rssFeedRecovery WHERE feedId = ?)",
        arguments: [feedID]) ?? false
    }
  }
}
