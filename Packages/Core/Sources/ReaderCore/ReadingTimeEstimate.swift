import Foundation

public struct ReadingTimeEstimate: Equatable, Sendable {
  /// Seconds of reading left before the current chapter ends, or nil when the chapter's end
  /// cannot be located.
  public let chapterSeconds: Double?
  /// Seconds of reading left before the publication ends.
  public let bookSeconds: Double?

  public init(chapterSeconds: Double?, bookSeconds: Double?) {
    self.chapterSeconds = chapterSeconds
    self.bookSeconds = bookSeconds
  }
}

public enum ReadingTime {
  /// 1024 bytes of XHTML, less about a third for markup, is about 660 characters of prose, or
  /// about 120 words at 5.5 characters each. A deflated entry packs roughly 2.5x as much source
  /// into 1024 bytes, so a position covers about 300 words. 200 is the midpoint, and a parameter
  /// because it is this soft. Readium derives its position count from
  /// `archiveEntryLength(pageLength: 1024)`, and `entryLength` might be a compressed length.
  public static let defaultWordsPerPosition: Double = 200
  public static let defaultWordsPerMinute: Double = 240

  /// Where the entry at `currentIndex` ends, on `TOCEntry.startProgression`'s 0-1 scale.
  public static func chapterEndProgression(in toc: [TOCEntry], currentIndex: Int) -> Double? {
    guard toc.indices.contains(currentIndex), let currentStart = toc[currentIndex].startProgression
    else { return nil }

    return toc.dropFirst(currentIndex + 1)
      .compactMap(\.startProgression)
      .first(where: { $0 > currentStart })
  }

  public static func estimate(
    totalProgression: Double,
    chapterEndProgression: Double?,
    positionCount: Int,
    wordsPerPosition: Double = defaultWordsPerPosition,
    wordsPerMinute: Double = defaultWordsPerMinute
  ) -> ReadingTimeEstimate {
    guard positionCount > 0 else {
      return ReadingTimeEstimate(chapterSeconds: nil, bookSeconds: nil)
    }

    let secondsPerProgression =
      Double(positionCount) * wordsPerPosition / wordsPerMinute * 60
    let bookFraction = max(1 - totalProgression, 0)
    let chapterSeconds = chapterEndProgression.map { end in
      max(end - totalProgression, 0) * secondsPerProgression
    }

    return ReadingTimeEstimate(
      chapterSeconds: chapterSeconds,
      bookSeconds: bookFraction * secondsPerProgression)
  }
}
