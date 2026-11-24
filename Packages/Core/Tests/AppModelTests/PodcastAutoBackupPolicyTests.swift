import Foundation
import Testing

@testable import AppModel

@Suite struct PodcastAutoBackupPolicyTests {
  private let now = Date(timeIntervalSince1970: 1_790_000_000)
  private let hour: TimeInterval = 3_600

  @Test func dueWhenNeverBackedUpAndNothingFailed() {
    #expect(PodcastAutoBackupPolicy.isDue(now: now, lastSuccess: nil, lastFailure: nil))
  }

  @Test func dueOnlyOnceADayHasPassedSinceTheLastSuccess() {
    #expect(PodcastAutoBackupPolicy.isDue(now: now, lastSuccess: now - 23 * hour, lastFailure: nil) == false)
    #expect(PodcastAutoBackupPolicy.isDue(now: now, lastSuccess: now - 24 * hour, lastFailure: nil))
  }

  @Test func aFailureWaitsAnHourBeforeTheNextAttempt() {
    #expect(PodcastAutoBackupPolicy.isDue(now: now, lastSuccess: nil, lastFailure: now - 59 * 60) == false)
    #expect(PodcastAutoBackupPolicy.isDue(now: now, lastSuccess: nil, lastFailure: now - hour))
  }

  @Test func aClockSetBackDoesNotBlockBackupsUntilItCatchesUp() {
    #expect(PodcastAutoBackupPolicy.isDue(now: now, lastSuccess: now + 48 * hour, lastFailure: nil))
    #expect(PodcastAutoBackupPolicy.isDue(now: now, lastSuccess: nil, lastFailure: now + hour))
  }

  @Test func filenameUsesTheCalendarDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    let date = ISO8601DateFormatter().date(from: "2026-09-25T23:30:00Z")!
    #expect(
      PodcastAutoBackupPolicy.filename(for: date, calendar: calendar)
        == "Whirr Podcasts 2026-09-26.whirrpodcasts.json")
  }

  @Test func onlyExactBackupNamesAreRecognised() {
    #expect(PodcastAutoBackupPolicy.isBackupFilename("Whirr Podcasts 2026-09-25.whirrpodcasts.json"))
    for name in [
      "Whirr Podcasts 2026-09-25.whirrpodcasts.json.tmp",
      "Whirr Podcasts 2026-09-25 2.whirrpodcasts.json",
      "Whirr Podcasts 2026-9-25.whirrpodcasts.json",
      "whirr podcasts 2026-09-25.whirrpodcasts.json",
      "Whirr Podcasts 2026-09-25.json",
      "Notes.txt",
      "Whirr Podcasts ２０２６-09-25.whirrpodcasts.json",
    ] {
      #expect(PodcastAutoBackupPolicy.isBackupFilename(name) == false, "\(name)")
    }
  }

  @Test func keepsTheThreeNewestBackupsAndIgnoresOtherFiles() {
    let names = [
      "Whirr Podcasts 2026-09-21.whirrpodcasts.json",
      "Whirr Podcasts 2026-09-25.whirrpodcasts.json",
      "Notes.txt",
      "Whirr Podcasts 2026-09-23.whirrpodcasts.json",
      "Whirr Podcasts 2026-09-22.whirrpodcasts.json",
      "Whirr Podcasts 2026-09-24 copy.whirrpodcasts.json",
    ]
    #expect(
      PodcastAutoBackupPolicy.filesToDelete(among: names, justWritten: "Whirr Podcasts 2026-09-25.whirrpodcasts.json")
        == ["Whirr Podcasts 2026-09-21.whirrpodcasts.json"])
  }

  @Test func deletesNothingWithThreeOrFewer() {
    let names = [
      "Whirr Podcasts 2026-09-23.whirrpodcasts.json",
      "Whirr Podcasts 2026-09-24.whirrpodcasts.json",
      "Whirr Podcasts 2026-09-25.whirrpodcasts.json",
    ]
    #expect(PodcastAutoBackupPolicy.filesToDelete(among: names, justWritten: names[2]).isEmpty)
    #expect(PodcastAutoBackupPolicy.filesToDelete(among: [names[2]], justWritten: names[2]).isEmpty)
  }

  @Test func neverDeletesTheFileJustWrittenEvenIfOthersLookNewer() {
    // A clock set back writes a file older-dated than ones already in the folder.
    let names = [
      "Whirr Podcasts 2026-09-20.whirrpodcasts.json",
      "Whirr Podcasts 2026-09-26.whirrpodcasts.json",
      "Whirr Podcasts 2026-09-27.whirrpodcasts.json",
      "Whirr Podcasts 2026-09-28.whirrpodcasts.json",
    ]
    let deleted = PodcastAutoBackupPolicy.filesToDelete(among: names, justWritten: names[0])
    #expect(deleted == ["Whirr Podcasts 2026-09-26.whirrpodcasts.json"])
  }
}
