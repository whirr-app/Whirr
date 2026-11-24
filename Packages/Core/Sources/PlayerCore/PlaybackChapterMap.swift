/// One chapter marker on the same global book timeline `PlaybackTimeline` maps tracks onto
/// (ARCHITECTURE.md §4). Chapters are optional book metadata. Unlike a track's duration, which
/// is required to build a timeline at all, a malformed chapter is dropped rather than failing
/// the whole map (see `PlaybackChapterMap`).
public struct PlaybackChapter: Codable, Sendable, Equatable {
  public let id: String?
  public let title: String?
  /// Inclusive global start position.
  public let start: Double
  /// Inclusive global end position. For the last chapter in a book this equals the book's
  /// `PlaybackTimeline.totalDuration`.
  public let end: Double

  public init(id: String? = nil, title: String? = nil, start: Double, end: Double) {
    self.id = id
    self.title = title
    self.start = start
    self.end = end
  }
}

/// A book's chapter list, addressable by global timeline position. Construction silently drops
/// any chapter with a non-finite or negative `start`, a non-finite `end`, or `end <= start`
/// (the lenient treatment ARCHITECTURE.md §7 gives optional metadata), then stable-sorts by
/// `start`. Overlaps and gaps are not malformed; the lookup rules below handle them.
public struct PlaybackChapterMap: Sendable, Equatable {
  /// Valid chapters, sorted ascending by `start`.
  public let chapters: [PlaybackChapter]

  public init(chapters: [PlaybackChapter]) {
    let valid = chapters.filter {
      $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start
    }
    self.chapters =
      valid
      .enumerated()
      .sorted { lhs, rhs in
        lhs.element.start == rhs.element.start
          ? lhs.offset < rhs.offset
          : lhs.element.start < rhs.element.start
      }
      .map(\.element)
  }

  /// The chapter that owns `position`: the last chapter (by start, after sorting) whose closed
  /// range `[start, end]` contains `position`. A shared boundary between two adjacent chapters
  /// resolves to the later-starting one, as `PlaybackTimeline` does at track boundaries. A chapter
  /// ending exactly at the book's end still owns that final position, as no later chapter takes
  /// it. A position in a gap covered by no chapter returns nil.
  public func currentChapter(at position: Double) -> PlaybackChapter? {
    chapters.last { $0.start <= position && position <= $0.end }
  }

  /// The owning chapter's title, if there is one worth showing. Nil when the book has no
  /// chapters, when `position` falls in a gap, or when the chapter's title is missing or blank,
  /// so a caller can fall back to the book's own title rather than an empty string.
  public func currentChapterTitle(at position: Double) -> String? {
    guard let title = currentChapter(at: position)?.title else { return nil }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// The chapter immediately before the current one in start order. If `position` is not
  /// covered by any chapter (a gap, or before the first/after the last chapter), this is the
  /// closest chapter that starts at or before `position`.
  public func previousChapter(before position: Double) -> PlaybackChapter? {
    if let index = currentIndex(at: position) {
      return index > 0 ? chapters[index - 1] : nil
    }
    return chapters.last { $0.start <= position }
  }

  /// The chapter immediately after the current one in start order. If `position` is not
  /// covered by any chapter (a gap, or before the first/after the last chapter), this is the
  /// closest upcoming chapter that starts after `position`.
  public func nextChapter(after position: Double) -> PlaybackChapter? {
    if let index = currentIndex(at: position) {
      return index < chapters.count - 1 ? chapters[index + 1] : nil
    }
    return chapters.first { $0.start > position }
  }

  private func currentIndex(at position: Double) -> Int? {
    var result: Int?
    for (index, chapter) in chapters.enumerated()
    where chapter.start <= position && position <= chapter.end {
      result = index
    }
    return result
  }
}
