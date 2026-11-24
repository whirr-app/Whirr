import Persistence
import Testing

@testable import AppModel

@Suite("Smart list rule summary")
struct SmartListRuleSummaryTests {
  @Test("a plain list says the defaults in one line")
  func defaultRules() {
    #expect(SmartListRuleSummary.text(for: .default) == "All shows, newest first")
  }

  @Test("each rule that differs from the default is named once, in a fixed order")
  func nonDefaultRules() {
    let rules = SmartListRules(
      showScope: .only, includeUnplayed: true, includeInProgress: false, includePlayed: false,
      includeDownloaded: true, includeNotDownloaded: false, savedOnly: true,
      releaseWindow: .week, durationFilter: true, longerThanMinutes: 0, shorterThanMinutes: 20,
      sortOrder: .shortest)

    #expect(
      SmartListRuleSummary.text(for: rules)
        == "Chosen shows, unplayed, downloaded, saved for later, from the last week, under 20 min, shortest first"
    )
  }

  @Test("a duration range names both bounds")
  func durationRange() {
    let rules = SmartListRules(
      durationFilter: true, longerThanMinutes: 20, shorterThanMinutes: 40)

    #expect(SmartListRuleSummary.text(for: rules).contains("20 to 40 min"))
  }

  @Test("played episodes are named because they are not the default")
  func playedIsNamed() {
    let rules = SmartListRules(includePlayed: true)

    #expect(SmartListRuleSummary.text(for: rules).contains("unplayed, in progress and played"))
  }

  @Test("the summary is one phrase, with no separator dots")
  func noSeparatorDots() {
    let rules = SmartListRules(showScope: .allExcept, releaseWindow: .twoWeeks)

    #expect(
      SmartListRuleSummary.text(for: rules)
        == "All shows except some, from the last 2 weeks, newest first")
  }

  @Test("the parts are the summary's phrases, one per rule, in the same order")
  func partsMatchText() {
    let rules = SmartListRules(
      includeDownloaded: true, includeNotDownloaded: false, sortOrder: .oldest)

    #expect(SmartListRuleSummary.parts(for: rules) == ["All shows", "downloaded", "oldest first"])
    #expect(
      SmartListRuleSummary.text(for: rules)
        == SmartListRuleSummary.parts(for: rules).joined(separator: ", "))
  }

  @Test("the status phrase stays one part, however many statuses it names")
  func statusIsOnePart() {
    let rules = SmartListRules(includePlayed: true)

    #expect(SmartListRuleSummary.parts(for: rules).contains("unplayed, in progress and played"))
  }
}
