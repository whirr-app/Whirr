import ABSApi
import Foundation
import WatchProtocol

/// Builds `WatchResumePosition`'s inputs for a start or a resume. The shared candidate comes
/// from the server's full progress snapshot, not from the Continue list, which drops finished and
/// hidden titles and keeps only ten; a title finished elsewhere therefore replays from 0 too.
///
/// The comparison keeps `WatchResumePosition`'s rule and adopts only the upload rule's future-date
/// allowance. It does not adopt the upload rule's 60 s tie window: that lets the further
/// position win, which would refuse a backward catch-up to newer listening elsewhere.
public enum WatchResumeCandidates {
  /// A position the Watch retained outside its progress rows.
  public struct Bookmark: Sendable, Equatable {
    public let selection: WatchSelection
    public let position: Double
    public let listenedAt: Date?

    public init(selection: WatchSelection, position: Double, listenedAt: Date?) {
      self.selection = selection
      self.position = position
      self.listenedAt = listenedAt
    }
  }

  /// The server's newest row for `selection` that carries a position and a date. A row missing
  /// either is no candidate.
  public static func row(for selection: WatchSelection, in rows: [MediaProgress]) -> MediaProgress? {
    guard case .audiobookshelf(let itemID, let episodeID) = selection else { return nil }
    return
      rows
      .filter { row in
        guard row.libraryItemID == itemID, row.episodeID == episodeID, let position = row.currentTime else {
          return false
        }
        return position.isFinite && position >= 0 && row.lastUpdate != nil
      }
      .max { ($0.lastUpdate ?? .distantPast) < ($1.lastUpdate ?? .distantPast) }
  }

  /// The shared candidate for `selection`. A date further ahead than `futureClockAllowance` comes
  /// from a fast clock: the row still supplies a position when the Watch has none, but undated it
  /// cannot supersede the Watch's own.
  public static func shared(
    for selection: WatchSelection, in rows: [MediaProgress], now: Date
  ) -> WatchResumePosition.Candidate? {
    guard let row = row(for: selection, in: rows), let position = row.currentTime, let date = row.lastUpdate
    else { return nil }
    let horizon = now.addingTimeInterval(WatchOfflineConflictPolicy.futureClockAllowance)
    return .init(position: position, listenedAt: date > horizon ? nil : date, finished: row.isFinished)
  }

  /// The Watch's own positions for `selection`: its retained progress rows and the bookmark.
  public static func local(
    for selection: WatchSelection, rows: [WatchOfflineProgressSession], bookmark: Bookmark?
  ) -> [WatchResumePosition.Candidate] {
    var candidates = rows.filter { $0.selection == selection }.map {
      WatchResumePosition.Candidate(
        position: $0.currentPosition, listenedAt: $0.effectiveLastListenedAt, finished: $0.isFinished)
    }
    if let bookmark, bookmark.selection == selection {
      candidates.append(.init(position: bookmark.position, listenedAt: bookmark.listenedAt))
    }
    return candidates
  }

  public static func start(
    for selection: WatchSelection, handoff: Double?, rows: [WatchOfflineProgressSession],
    bookmark: Bookmark?, serverRows: [MediaProgress], now: Date
  ) -> Double {
    WatchResumePosition.start(
      handoff: handoff, local: local(for: selection, rows: rows, bookmark: bookmark),
      shared: shared(for: selection, in: serverRows, now: now))
  }
}
