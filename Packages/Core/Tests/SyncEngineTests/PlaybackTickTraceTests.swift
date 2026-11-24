import Foundation
import Testing

@testable import SyncEngine

/// The tick trace's record shape and rendering. The `NSLog` itself is DEBUG-only and untestable.
/// These tests own which records are worth a line, and that a line carries no identifier beyond
/// the item/episode ids (SECURITY.md §7).
@Suite struct PlaybackTickTraceTests {

  private func record(
    outcome: PlaybackTickTrace.Outcome,
    failedRoutes: [PlaybackTickTrace.Route] = [],
    itemID: String = "item-1",
    episodeID: String? = nil,
    position: Double = 123.45
  ) -> PlaybackTickTrace.Record {
    PlaybackTickTrace.Record(
      outcome: outcome, failedRoutes: failedRoutes, itemID: itemID, episodeID: episodeID,
      position: position)
  }

  // MARK: - What is worth a line

  /// The ordinary case is a tick every 15 s for the whole listen. A line for each would bury the
  /// ones that matter and cost energy in DEBUG builds.
  @Test func aTickThatPersistedFirstTimeSaysNothing() {
    #expect(record(outcome: .persisted(.cachedOnline)).isNoteworthy == false)
    #expect(record(outcome: .persisted(.local)).isNoteworthy == false)
    #expect(record(outcome: .persisted(.online)).isNoteworthy == false)
    #expect(record(outcome: .persisted(.displaced)).isNoteworthy == false)
  }

  /// Reaching the sessionless net at all means a session died underneath live audio.
  @Test func reachingTheSessionlessNetIsAlwaysWorthALine() {
    #expect(record(outcome: .persisted(.sessionless)).isNoteworthy)
  }

  /// A write that threw is worth reporting: the tick was rescued, but a branch that should have
  /// handled it did not.
  @Test func aRescuedTickStillReportsTheBranchThatFailed() {
    #expect(record(outcome: .persisted(.online), failedRoutes: [.local]).isNoteworthy)
  }

  @Test func everyDroppedTickIsWorthALine() {
    for reason in [
      PlaybackTickTrace.DropReason.noAccountRow, .noItemRow, .noEpisodeRow, .everyWriteFailed,
      .notPlayingThisItem, .suppressedByVariant,
    ] {
      #expect(record(outcome: .dropped(reason)).isNoteworthy, "\(reason) must be visible")
    }
  }

  // MARK: - The rendered line

  @Test func aPersistedLineNamesTheRouteThatTookIt() {
    #expect(
      PlaybackTickTrace.line(record(outcome: .persisted(.sessionless), position: 400))
        == "WHIRRSYNC tick outcome=persisted route=sessionless failed=none item=item-1 episode=none position=400.0"
    )
  }

  @Test func aDisplacedPersistedLineNamesTheNormalSwitchStragglerRoute() {
    #expect(
      PlaybackTickTrace.line(record(outcome: .persisted(.displaced), position: 400))
        == "WHIRRSYNC tick outcome=persisted route=displaced failed=none item=item-1 episode=none position=400.0"
    )
  }

  @Test func aDroppedLineNamesWhyRatherThanWhere() {
    #expect(
      PlaybackTickTrace.line(record(outcome: .dropped(.noItemRow), position: 12))
        == "WHIRRSYNC tick outcome=dropped reason=no-item-row failed=none item=item-1 episode=none position=12.0"
    )
  }

  /// One line must show both that the local write threw and that the net caught it.
  @Test func everyFailedBranchIsListedInTheOrderItWasTried() {
    #expect(
      PlaybackTickTrace.line(
        record(
          outcome: .persisted(.sessionless), failedRoutes: [.cachedOnline, .local, .online],
          episodeID: "ep-9", position: 88.26)
      )
        == "WHIRRSYNC tick outcome=persisted route=sessionless failed=cached-online,local,online item=item-1 episode=ep-9 position=88.3"
    )
  }

  /// SECURITY.md §7: the record has nowhere to put a token, URL or header. The rendered field set
  /// is pinned so a new field cannot be added without this failing first.
  @Test func theRecordHasNowhereToPutACredential() {
    let fields = PlaybackTickTrace.line(record(outcome: .persisted(.sessionless)))
      .split(separator: " ").dropFirst(2).map { String($0.split(separator: "=")[0]) }

    #expect(Set(fields) == ["outcome", "route", "failed", "item", "episode", "position"])
  }
}
