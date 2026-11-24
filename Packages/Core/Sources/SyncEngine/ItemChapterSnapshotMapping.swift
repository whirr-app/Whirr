import ABSApi
import Persistence

/// Resolves optional item-detail boundaries once while retaining the server identity needed to
/// rebuild `PreparedPlaybackChapter` for a local session.
func storedItemChapters(
  from chapters: [Chapter], duration: Double?
) -> [StoredItemChapter] {
  let identified = chapters.filter { $0.start != nil }
  let resolved = ItemDetailExtras.makeChapters(from: chapters, duration: duration)

  return zip(identified, resolved).enumerated().compactMap { position, pair in
    let (chapter, info) = pair
    guard
      info.start.isFinite,
      info.end.isFinite,
      info.start >= 0,
      info.end > info.start
    else { return nil }
    return StoredItemChapter(
      serverChapterId: chapter.id,
      position: position,
      start: info.start,
      end: info.end,
      title: info.title)
  }
}
