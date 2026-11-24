import ReaderCore

/// The AppModel-facing progress seam. Its production implementation is composed from the
/// ebook-safe Persistence DAO; the model never imports GRDB or a record type.
public protocol ReaderProgressAccessing: Sendable {
  func fetchRestoreTarget(itemID: String) async throws -> ReaderRestoreTarget?
  func write(position: ReadingPosition, itemID: String) async throws
  func markEbookAsFinished(itemID: String) async throws
  /// Requests an outbox drain and waits for it. The reader calls this when it goes to the
  /// background, after flushing its position, so the send runs while the process is still alive.
  func requestSync() async
}

extension ReaderProgressAccessing {
  /// Conformers with nothing to send leave this as a no-op.
  public func requestSync() async {}
}

public struct NoOpReaderProgressAccess: ReaderProgressAccessing, Sendable {
  public init() {}
  public func fetchRestoreTarget(itemID: String) async throws -> ReaderRestoreTarget? { nil }
  public func write(position: ReadingPosition, itemID: String) async throws {}
  public func markEbookAsFinished(itemID: String) async throws {}
}
