import Foundation
import Persistence
import Testing

@testable import AppModel

/// The read-only server section's rows and footer, which an account that cannot save to the
/// server still gets byte-for-byte (ADR 0017 makes the editor an exception for accounts that can;
/// `PodcastServerSettingsEditorTests` covers that). Every case here is a server fact: nothing in
/// this suite may be satisfied by a device setting, which is why the section exists separately
/// from the override pickers above it.
@Suite struct PodcastServerSettingsPresentationTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)

  @Test func rendersEveryKnownFieldInOrder() {
    let rows = PodcastServerSettingsPresentation.rows(
      autoDownloadEpisodes: true,
      autoDownloadSchedule: "0 0 * * *",
      maxNewEpisodesToDownload: 3,
      maxEpisodesToKeep: 10)

    #expect(rows.map(\.field) == [.autoDownloadEpisodes, .schedule, .newEpisodeLimit, .retention])
    #expect(
      rows.map(\.label) == [
        "Downloads New Episodes", "Checks", "Downloads at Most", "Keeps",
      ])
    #expect(rows.map(\.value) == ["On", "Every day", "3 episodes", "10 episodes"])
  }

  /// Verb-led labels are what stop "Keeps · 10 episodes" reading as the device's own "Keep Latest"
  /// picker a few points above it. If a label ever becomes an imperative, this fails.
  @Test func labelsDescribeTheServerRatherThanInstructingThePhone() {
    let rows = PodcastServerSettingsPresentation.rows(
      autoDownloadEpisodes: false,
      autoDownloadSchedule: "0 0 * * *",
      maxNewEpisodesToDownload: 1,
      maxEpisodesToKeep: 1)
    for row in rows {
      #expect(row.label.hasPrefix("Keep Latest") == false)
      #expect(row.label.hasPrefix("Automatic Downloads") == false)
    }
  }

  @Test func autoDownloadRendersOnAndOff() {
    #expect(
      PodcastServerSettingsPresentation.rows(
        autoDownloadEpisodes: true, autoDownloadSchedule: nil, maxNewEpisodesToDownload: nil,
        maxEpisodesToKeep: nil
      ).map(\.value) == ["On"])
    #expect(
      PodcastServerSettingsPresentation.rows(
        autoDownloadEpisodes: false, autoDownloadSchedule: nil, maxNewEpisodesToDownload: nil,
        maxEpisodesToKeep: nil
      ).map(\.value) == ["Off", "Off"])
  }

  @Test func disabledAutoDownloadShowsChecksOffAndOmitsNewEpisodeLimit() {
    let rows = PodcastServerSettingsPresentation.rows(
      autoDownloadEpisodes: false,
      autoDownloadSchedule: "0 * * * *",
      maxNewEpisodesToDownload: 3,
      maxEpisodesToKeep: 0)

    #expect(rows.map(\.field) == [.autoDownloadEpisodes, .schedule, .retention])
    #expect(rows.map(\.value) == ["Off", "Off", "All episodes"])
  }

  @Test func disabledAutoDownloadWithMissingSchedulePreservesRetention() {
    let rows = PodcastServerSettingsPresentation.rows(
      autoDownloadEpisodes: false,
      autoDownloadSchedule: nil,
      maxNewEpisodesToDownload: nil,
      maxEpisodesToKeep: 10)

    #expect(rows.map(\.field) == [.autoDownloadEpisodes, .schedule, .retention])
    #expect(rows.map(\.value) == ["Off", "Off", "10 episodes"])
  }

  @Test func disabledAutoDownloadHidesAStoredCustomSchedule() {
    let rows = PodcastServerSettingsPresentation.rows(
      autoDownloadEpisodes: false,
      autoDownloadSchedule: "17 3 * * 2",
      maxNewEpisodesToDownload: 3,
      maxEpisodesToKeep: 10)

    #expect(rows.map(\.field) == [.autoDownloadEpisodes, .schedule, .retention])
    #expect(rows.map(\.value) == ["Off", "Off", "10 episodes"])
  }

  @Test(
    arguments: [
      ("0 * * * *", "Every hour"),
      ("0 */6 * * *", "Every 6 hours"),
      ("0 */12 * * *", "Every 12 hours"),
      ("0 0 * * *", "Every day"),
      ("0 0 * * 0", "Every week"),
    ])
  func mapsEveryPresetSchedule(cron: String, label: String) {
    #expect(PodcastServerSettingsPresentation.scheduleValue(cron) == label)
  }

  /// An unrecognised expression shows verbatim. "Custom" would hide the one string the user
  /// opened this screen to read.
  @Test func unknownScheduleRendersTheRawExpression() {
    #expect(PodcastServerSettingsPresentation.scheduleValue("17 3 * * 2") == "17 3 * * 2")
    #expect(PodcastServerSettingsPresentation.scheduleValue("  0 0 * * *  ") == "Every day")
  }

  /// `0` is falsy server-side and means no pruning. "Keeps 0 episodes" would claim the opposite
  /// of the truth.
  @Test func zeroMeansUnlimitedRatherThanNone() {
    let rows = PodcastServerSettingsPresentation.rows(
      autoDownloadEpisodes: nil, autoDownloadSchedule: nil, maxNewEpisodesToDownload: 0,
      maxEpisodesToKeep: 0)
    #expect(rows.map(\.value) == ["No limit", "All episodes"])
  }

  @Test func singularCountsDropThePlural() {
    let rows = PodcastServerSettingsPresentation.rows(
      autoDownloadEpisodes: nil, autoDownloadSchedule: nil, maxNewEpisodesToDownload: 1,
      maxEpisodesToKeep: 1)
    #expect(rows.map(\.value) == ["1 episode", "1 episode"])
  }

  /// Absence is not "Off", "0" or "Never" (`ItemRecord`'s house rule). A nil field takes its row
  /// with it and leaves every other row untouched.
  @Test func aNilFieldOmitsExactlyItsOwnRow() {
    #expect(
      PodcastServerSettingsPresentation.rows(
        autoDownloadEpisodes: nil, autoDownloadSchedule: "0 0 * * *", maxNewEpisodesToDownload: 3,
        maxEpisodesToKeep: 10
      ).map(\.field) == [.schedule, .newEpisodeLimit, .retention])
    #expect(
      PodcastServerSettingsPresentation.rows(
        autoDownloadEpisodes: true, autoDownloadSchedule: nil, maxNewEpisodesToDownload: 3,
        maxEpisodesToKeep: 10
      ).map(\.field) == [.autoDownloadEpisodes, .newEpisodeLimit, .retention])
    #expect(
      PodcastServerSettingsPresentation.rows(
        autoDownloadEpisodes: true, autoDownloadSchedule: "0 0 * * *", maxNewEpisodesToDownload: nil,
        maxEpisodesToKeep: 10
      ).map(\.field) == [.autoDownloadEpisodes, .schedule, .retention])
    #expect(
      PodcastServerSettingsPresentation.rows(
        autoDownloadEpisodes: true, autoDownloadSchedule: "0 0 * * *", maxNewEpisodesToDownload: 3,
        maxEpisodesToKeep: nil
      ).map(\.field) == [.autoDownloadEpisodes, .schedule, .newEpisodeLimit])
  }

  @Test func anEmptyScheduleStringIsAbsentRatherThanBlank() {
    #expect(PodcastServerSettingsPresentation.scheduleValue("") == nil)
    #expect(PodcastServerSettingsPresentation.scheduleValue("   ") == nil)
    #expect(
      PodcastServerSettingsPresentation.rows(
        autoDownloadEpisodes: nil, autoDownloadSchedule: "", maxNewEpisodesToDownload: nil,
        maxEpisodesToKeep: nil
      ).isEmpty)
  }

  @Test func allFieldsAbsentRendersNoRows() {
    #expect(
      PodcastServerSettingsPresentation.rows(
        autoDownloadEpisodes: nil, autoDownloadSchedule: nil, maxNewEpisodesToDownload: nil,
        maxEpisodesToKeep: nil
      ).isEmpty)
  }

  /// The read-only footer carries the one fact that is a timestamp rather than a setting, plus the
  /// only place an account that cannot save can change any of this. Point at the web UI, don't
  /// offer a button that pretends to fix it.
  @Test func footerNamesTheWebAppAndTheLastCheck() {
    let twoHoursAgo = now.addingTimeInterval(-3_600 * 2)
    #expect(
      PodcastServerSettingsPresentation.footer(lastEpisodeCheck: twoHoursAgo, now: now)
        == "Last checked 2 hours ago. Change these in the Audiobookshelf web app.")
  }

  @Test func footerWithoutALastCheckStillNamesTheWebApp() {
    #expect(
      PodcastServerSettingsPresentation.footer(lastEpisodeCheck: nil, now: now)
        == "Change these in the Audiobookshelf web app.")
  }

  // MARK: - The whole section

  @Test func sectionCarriesEveryRowAndTheFooter() {
    let section = PodcastServerSettingsPresentation.section(
      diagnostics: PodcastShowDiagnostics(
        autoDownloadEpisodes: true,
        autoDownloadSchedule: "0 0 * * *",
        lastEpisodeCheck: now.addingTimeInterval(-3_600 * 2),
        maxEpisodesToKeep: 10,
        maxNewEpisodesToDownload: 3),
      now: now)

    #expect(section?.rows.count == 4)
    #expect(
      section?.footer == "Last checked 2 hours ago. Change these in the Audiobookshelf web app.")
  }

  /// A show that has never been refreshed knows nothing about the server, and a header over an
  /// empty section claiming otherwise is worse than no section. Only the single diagnostic line
  /// shows.
  @Test func aShowWithNoServerFactsHasNoSection() {
    #expect(PodcastServerSettingsPresentation.section(diagnostics: nil, now: now) == nil)
    #expect(
      PodcastServerSettingsPresentation.section(
        diagnostics: PodcastShowDiagnostics(autoDownloadEpisodes: nil, lastEpisodeCheck: nil),
        now: now) == nil)
  }

  /// The last check alone is still an answer to "why isn't this updating?", so it keeps the
  /// section even when every settable field is absent.
  @Test func aLastCheckAloneKeepsTheSection() {
    let section = PodcastServerSettingsPresentation.section(
      diagnostics: PodcastShowDiagnostics(
        autoDownloadEpisodes: nil, lastEpisodeCheck: now.addingTimeInterval(-3_600 * 2)),
      now: now)

    #expect(section?.rows.isEmpty == true)
    #expect(
      section?.footer == "Last checked 2 hours ago. Change these in the Audiobookshelf web app.")
  }
}
