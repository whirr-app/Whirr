import AdSkip
import Persistence

/// The skips playback will make from a served row set, in the player's own view of the ranges:
/// pre-roll snapped, sorted, and joined within `PlayerReducer.skipJoinGap`. The episode card and
/// the coordinator's break count share this so neither can disagree with what plays.
public struct AdSkipBreaks: Sendable, Equatable {
  /// One skip the player makes: consecutive ranges joined as it joins them.
  public struct Break: Sendable, Equatable {
    public let start: Double
    public let end: Double
    /// No speech follows, so skipping this break finishes the item.
    public let endsItem: Bool

    public init(start: Double, end: Double, endsItem: Bool) {
      self.start = start
      self.end = end
      self.endsItem = endsItem
    }
  }

  /// Sorted and joined as the player joins them.
  public let breaks: [Break]

  /// As given, for tests and App fixtures.
  public init(breaks: [Break]) {
    self.breaks = breaks
  }

  /// The player's view of already-served rows. Mirrors `PlayerReducer.handleSetSkipRanges` and
  /// `joining(from:)`: invalid rows are dropped, each start is snapped to the item start, rows are
  /// sorted, and a row joins the one before it while it starts within the player's join gap.
  init(servedRows: [AdSkipRange]) {
    struct Row {
      let start: Double
      let end: Double
      let endsItem: Bool
    }
    var sorted: [Row] = []
    sorted.reserveCapacity(servedRows.count)
    for row in servedRows {
      guard row.startTime.isFinite, row.endTime.isFinite, row.startTime < row.endTime else {
        continue
      }
      sorted.append(
        Row(
          start: PlaybackEdges.start(atItemStartFor: row.startTime), end: row.endTime,
          endsItem: row.endsItem))
    }
    // Two rows with the same start are not joined by the player, whose sort is not stable, so put
    // the shorter end first: never count a skip the player might not make.
    sorted.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }

    var breaks: [Break] = []
    var index = sorted.startIndex
    while index < sorted.endIndex {
      let base = sorted[index]
      var end = base.end
      var endsItem = base.endsItem
      var next = sorted.index(after: index)
      while next < sorted.endIndex {
        let row = sorted[next]
        if row.start > base.start, row.end > end {
          guard row.start - end <= PlaybackEdges.joinGapSeconds else { break }
          end = row.end
          endsItem = row.endsItem
        }
        next = sorted.index(after: next)
      }
      breaks.append(Break(start: base.start, end: end, endsItem: endsItem))
      // Every row that starts before this break ends plays inside it.
      index = sorted[next...].firstIndex { $0.start >= end } ?? sorted.endIndex
    }
    self.breaks = breaks
  }

  public var count: Int { breaks.count }

  /// Seconds after `position`, up to `duration`, that playback will skip when it resumes there.
  /// A break the playhead is inside plays on resume: the player only skips a range playback
  /// entered. Each counted break contributes its own length, or everything to the item's end for
  /// one that ends the item, and the total never exceeds the media left.
  public func skippedSeconds(resumingAt position: Double, duration: Double) -> Double {
    guard position.isFinite, duration.isFinite, duration > 0 else { return 0 }
    var skipped = 0.0
    for line in breaks where line.start >= position {
      if line.endsItem {
        skipped += max(0, duration - line.start)
      } else {
        skipped += max(0, min(line.end, duration) - line.start)
      }
    }
    return min(skipped, max(0, duration - position))
  }
}
