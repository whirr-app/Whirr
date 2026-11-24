/// The one chapter a queued audiobook row may carry: a snapshot of its bounds and title taken
/// when it was queued. There is no server chapter id, because item detail has none and the stored
/// `itemChapter` rows may not exist; the bounds are therefore never checked against them.
public struct ListeningQueueChapter: Sendable, Hashable {
  /// Two snapshots whose starts are this close are the same chapter.
  static let sameChapterTolerance: Double = 0.5

  public let start: Double
  public let end: Double
  public let title: String?

  public init(start: Double, end: Double, title: String?) {
    self.start = start
    self.end = end
    self.title = title
  }

  public func isSameChapter(as other: ListeningQueueChapter) -> Bool {
    abs(start - other.start) <= Self.sameChapterTolerance
  }

  /// The table cannot carry a `CHECK` added by `ALTER`, so the store enforces the shape: only an
  /// audiobook row takes a chapter, and its bounds are finite, non-negative and ordered.
  func validate(for identity: ListeningIdentity) throws {
    guard case .audiobook = identity.source else {
      throw ListeningQueueStoreError.chapterNotAllowed
    }
    guard start.isFinite, end.isFinite, start >= 0, end > start else {
      throw ListeningQueueStoreError.chapterInvalid
    }
  }
}

extension ListeningQueueEntryRecord {
  var chapter: ListeningQueueChapter? {
    get {
      guard let chapterStart, let chapterEnd else { return nil }
      return ListeningQueueChapter(start: chapterStart, end: chapterEnd, title: chapterTitle)
    }
    set {
      chapterStart = newValue?.start
      chapterEnd = newValue?.end
      chapterTitle = newValue?.title
    }
  }
}
