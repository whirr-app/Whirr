import Foundation
import Persistence
import SyncEngine
import Testing

@testable import AppModel

/// ADR 0017: the editor an account that may save to the server sees instead of the read-only rows.
@Suite struct PodcastServerSettingsEditorTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  private func editor(
    downloads: Bool? = true, schedule: String? = "0 0 * * *", limit: Int? = 3, keep: Int? = 10,
    lastCheck: Date? = nil
  ) -> PodcastServerSettingsEditor? {
    PodcastServerSettingsPresentation.editor(
      diagnostics: PodcastShowDiagnostics(
        autoDownloadEpisodes: downloads, autoDownloadSchedule: schedule,
        lastEpisodeCheck: lastCheck, maxEpisodesToKeep: keep, maxNewEpisodesToDownload: limit),
      now: now)
  }

  @Test func downloadsOnOffersEveryControlWithTheStoredValuesSelected() throws {
    let editor = try #require(editor())

    #expect(editor.downloadsNewEpisodes == true)
    #expect(editor.schedule?.label == "Checks")
    #expect(editor.schedule?.selection == .preset(.daily))
    #expect(editor.newEpisodeLimit?.label == "Downloads at Most")
    #expect(editor.newEpisodeLimit?.selection == 3)
    #expect(editor.retention?.label == "Keeps")
    #expect(editor.retention?.selection == 10)
  }

  @Test func presetChoicesKeepTodaysLabelsInPresetOrder() throws {
    let choices = try #require(editor()?.schedule?.choices)

    #expect(
      choices.map(\.label) == [
        "Every hour", "Every 6 hours", "Every 12 hours", "Every day", "Every week",
      ])
    #expect(
      choices.map(\.value) == PodcastAutomationSchedulePreset.allCases.map { .preset($0) })
    // One source of truth: the editor's label is the read-only value's label.
    for preset in PodcastAutomationSchedulePreset.allCases {
      #expect(
        PodcastServerSettingsPresentation.scheduleValue(preset.cronExpression)
          == PodcastServerSettingsPresentation.scheduleLabel(preset))
    }
  }

  @Test func downloadsOffHidesChecksAndDownloadsAtMostButKeepsKeeps() throws {
    let editor = try #require(editor(downloads: false))

    #expect(editor.downloadsNewEpisodes == false)
    #expect(editor.schedule == nil)
    #expect(editor.newEpisodeLimit == nil)
    #expect(editor.retention?.selection == 10)
  }

  @Test func aFieldTheServerDidNotSupplyIsNeverOffered() throws {
    let noToggle = try #require(editor(downloads: nil, schedule: nil, limit: nil, keep: 5))
    #expect(noToggle.downloadsNewEpisodes == nil)
    #expect(noToggle.schedule == nil)
    #expect(noToggle.newEpisodeLimit == nil)
    #expect(noToggle.retention?.selection == 5)

    let noKeep = try #require(editor(keep: nil))
    #expect(noKeep.retention == nil)
    #expect(noKeep.newEpisodeLimit != nil)

    let noLimit = try #require(editor(limit: nil))
    #expect(noLimit.newEpisodeLimit == nil)

    #expect(editor(downloads: nil, schedule: nil, limit: nil, keep: nil) == nil)
    #expect(editor(downloads: nil, schedule: "0 0 * * *", limit: 3, keep: nil) == nil)
  }

  @Test func aCustomScheduleIsTheCurrentNonPresetChoiceUntilAPresetReplacesIt() throws {
    let custom = try #require(editor(schedule: "17 3 * * 2")?.schedule)

    #expect(custom.selection == .stored("17 3 * * 2"))
    #expect(custom.choices.count == 6)
    #expect(custom.choices.last == .init(value: .stored("17 3 * * 2"), label: "17 3 * * 2"))
    #expect(
      Array(custom.choices.dropLast().map(\.value))
        == PodcastAutomationSchedulePreset.allCases.map { .preset($0) })

    let replaced = try #require(editor(schedule: "0 * * * *")?.schedule)
    #expect(replaced.selection == .preset(.hourly))
    #expect(replaced.choices.count == 5)
  }

  @Test func aNullOrBlankScheduleLeavesNothingSelected() throws {
    for stored in [nil, "", "   "] as [String?] {
      let schedule = try #require(editor(schedule: stored)?.schedule)
      #expect(schedule.selection == nil)
      #expect(schedule.choices.count == 5)
    }
  }

  @Test func aPaddedPresetIsStillThePreset() throws {
    #expect(try #require(editor(schedule: "  0 0 * * *  ")?.schedule).selection == .preset(.daily))
  }

  @Test func fixedCountChoicesAreOffered() throws {
    let editor = try #require(editor())

    #expect(editor.newEpisodeLimit?.choices.map(\.value) == [1, 2, 3, 5, 10])
    #expect(
      editor.newEpisodeLimit?.choices.map(\.label) == [
        "1 episode", "2 episodes", "3 episodes", "5 episodes", "10 episodes",
      ])
    #expect(editor.retention?.choices.map(\.value) == [0, 1, 2, 3, 5, 10, 25, 50])
    #expect(editor.retention?.choices.first?.label == "All episodes")
    #expect(editor.retention?.choices.map(\.label).last == "50 episodes")
  }

  @Test func noLimitIsNeverOfferedAsAChoiceButShowsWhenStored() throws {
    let offered = try #require(editor(limit: 3)?.newEpisodeLimit)
    #expect(offered.choices.map(\.value).contains(0) == false)

    let stored = try #require(editor(limit: 0)?.newEpisodeLimit)
    #expect(stored.selection == 0)
    #expect(stored.choices.map(\.value) == [0, 1, 2, 3, 5, 10])
    #expect(stored.choices.first?.label == "No limit")
  }

  @Test func outOfListValuesAppearAsTheCurrentChoiceInOrderAndCarryTodaysLabel() throws {
    let limit = try #require(editor(limit: 4)?.newEpisodeLimit)
    #expect(limit.choices.map(\.value) == [1, 2, 3, 4, 5, 10])
    #expect(limit.selection == 4)
    #expect(limit.choices.first { $0.value == 4 }?.label == "4 episodes")

    let keep = try #require(editor(keep: 1_000)?.retention)
    #expect(keep.choices.map(\.value) == [0, 1, 2, 3, 5, 10, 25, 50, 1_000])
    #expect(keep.choices.last?.label == "1000 episodes")

    let negative = try #require(editor(limit: -2, keep: -5))
    #expect(negative.newEpisodeLimit?.choices.first?.value == -2)
    #expect(negative.newEpisodeLimit?.choices.first?.label == "No limit")
    #expect(negative.retention?.choices.first?.value == -5)
    #expect(negative.retention?.choices.first?.label == "All episodes")

    let huge = try #require(editor(limit: Int.max)?.newEpisodeLimit)
    #expect(huge.choices.last?.value == Int.max)
    #expect(huge.selection == Int.max)

    // Replaced by a listed value, the extra choice is gone.
    #expect(try #require(editor(limit: 5)?.newEpisodeLimit).choices.count == 5)
  }

  @Test func footerWithoutALastCheckNeverNamesTheWebApp() throws {
    let footer = try #require(editor()).footer
    #expect(
      footer
        == "Changes apply on the server, for everyone who uses it. A Keeps limit also removes episodes saved by hand."
    )
    #expect(footer.contains("web app") == false)
    #expect(footer.contains("Audiobookshelf") == false)
  }

  @Test func footerLeadsWithTheLastCheckWhenKnown() throws {
    let footer = try #require(editor(lastCheck: now.addingTimeInterval(-3_600 * 2))).footer
    #expect(
      footer
        == "Last checked 2 hours ago. Changes apply on the server, for everyone who uses it. A Keeps limit also removes episodes saved by hand."
    )
  }

  @Test func noDiagnosticsOrNothingToEditHasNoEditor() {
    #expect(PodcastServerSettingsPresentation.editor(diagnostics: nil, now: now) == nil)
    #expect(
      PodcastServerSettingsPresentation.editor(
        diagnostics: PodcastShowDiagnostics(
          autoDownloadEpisodes: nil, lastEpisodeCheck: now.addingTimeInterval(-60)),
        now: now) == nil)
  }

  /// The read-only section is what an account that cannot save sees, so building an editor must
  /// not have changed one byte of it, in any value state.
  @Test(
    arguments: [
      (true as Bool?, "0 0 * * *" as String?, 3 as Int?, 10 as Int?),
      (false, "17 3 * * 2", 3, 0),
      (nil, nil, nil, nil),
      (true, nil, 0, nil),
      (true, "", 7, -1),
    ])
  func theReadOnlySectionIsUnchanged(
    downloads: Bool?, schedule: String?, limit: Int?, keep: Int?
  ) {
    let lastCheck = now.addingTimeInterval(-3_600 * 2)
    let diagnostics = PodcastShowDiagnostics(
      autoDownloadEpisodes: downloads, autoDownloadSchedule: schedule, lastEpisodeCheck: lastCheck,
      maxEpisodesToKeep: keep, maxNewEpisodesToDownload: limit)
    let section = PodcastServerSettingsPresentation.section(diagnostics: diagnostics, now: now)
    let rows = PodcastServerSettingsPresentation.rows(
      autoDownloadEpisodes: downloads, autoDownloadSchedule: schedule,
      maxNewEpisodesToDownload: limit, maxEpisodesToKeep: keep)

    #expect(section?.rows == rows)
    #expect(
      section?.footer == "Last checked 2 hours ago. Change these in the Audiobookshelf web app.")
  }

  @Test func theReadOnlyRowsKeepTodaysExactValues() {
    let rows = PodcastServerSettingsPresentation.rows(
      autoDownloadEpisodes: true, autoDownloadSchedule: "17 3 * * 2",
      maxNewEpisodesToDownload: 0, maxEpisodesToKeep: 0)
    #expect(rows.map(\.label) == ["Downloads New Episodes", "Checks", "Downloads at Most", "Keeps"])
    #expect(rows.map(\.value) == ["On", "17 3 * * 2", "No limit", "All episodes"])
    #expect(
      PodcastServerSettingsPresentation.rows(
        autoDownloadEpisodes: false, autoDownloadSchedule: "0 * * * *",
        maxNewEpisodesToDownload: 3, maxEpisodesToKeep: 1
      ).map(\.value) == ["Off", "Off", "1 episode"])
  }
}
