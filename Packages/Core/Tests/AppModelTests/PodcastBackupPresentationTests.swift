import Foundation
import Persistence
import Testing

@testable import AppModel
@testable import SyncEngine

@Suite struct PodcastBackupPresentationTests {
  @Test func exportSummaryCountsAndMentionsWhatWasLeftOut() {
    #expect(
      PodcastBackupPresentation.exportSummary(PodcastBackupExport(data: Data(), showCount: 1, episodeCount: 1))
        == "1 show and 1 episode.")
    #expect(
      PodcastBackupPresentation.exportSummary(
        PodcastBackupExport(data: Data(), showCount: 12, episodeCount: 340, skippedShows: 2, skippedEpisodes: 0))
        == "12 shows and 340 episodes. 2 shows with addresses Whirr can’t back up are left out.")
  }

  @Test func previewDescribesOnlyWhatWouldChange() {
    var outcome = NativePodcastRestoreOutcome()
    outcome.showsAdded = 3
    outcome.statesApplied = 1
    outcome.statesKeptLocal = 4
    #expect(
      PodcastBackupPresentation.previewMessage(outcome, syncOn: false)
        == "Adds 3 shows and progress for 1 episode. Newer progress on this device is kept, and nothing is removed.")
    #expect(PodcastBackupPresentation.hasChanges(outcome))
    #expect(PodcastBackupPresentation.hasChanges(NativePodcastRestoreOutcome()) == false)
  }

  @Test func previewWithSyncOnSaysSyncRunsFirst() {
    var outcome = NativePodcastRestoreOutcome()
    outcome.savesAdded = 2
    #expect(
      PodcastBackupPresentation.previewMessage(outcome, syncOn: true)
        == "Adds 2 saved episodes. Newer progress on this device is kept, and nothing is removed."
        + " iCloud Sync runs first, and restored podcasts then sync to your other devices.")
  }

  @Test func settingsAndBookmarkAloneStillCountAsChanges() {
    var outcome = NativePodcastRestoreOutcome()
    outcome.globalSettingsApplied = true
    #expect(PodcastBackupPresentation.hasChanges(outcome))
    #expect(
      PodcastBackupPresentation.previewMessage(outcome, syncOn: false)
        == "Restores podcast settings. Newer progress on this device is kept, and nothing is removed.")
  }

  @Test func automaticFailuresSayWhatToDo() {
    #expect(PodcastBackupPresentation.automaticFailureMessage(.folderUnavailable).contains("Tap Folder"))
    #expect(PodcastBackupPresentation.automaticFailureMessage(.writeFailed).contains("try again next time"))
    #expect(PodcastBackupPresentation.automaticFailureMessage(.nothingToBackUp).contains("were kept"))
  }

  @Test func finishedMessageNotesRefreshAndUnmatchedEpisodes() {
    var outcome = NativePodcastRestoreOutcome()
    outcome.showsAdded = 1
    outcome.episodesUnmatched = 2
    #expect(
      PodcastBackupPresentation.finishedMessage(outcome)
        == "Added 1 show. New shows fill in their episodes as they refresh. 2 episodes couldn’t be matched.")
    #expect(PodcastBackupPresentation.finishedMessage(NativePodcastRestoreOutcome()) == "Nothing needed restoring.")
  }

  @Test func learnedAdsAreCountedInTheSummaryAndTheRestore() {
    #expect(
      PodcastBackupPresentation.exportSummary(
        PodcastBackupExport(data: Data(), showCount: 2, episodeCount: 5, learnedAdCount: 631))
        == "2 shows and 5 episodes. Includes 631 learned ads.")
    var outcome = NativePodcastRestoreOutcome()
    outcome.learnedAdsAdded = 1
    #expect(PodcastBackupPresentation.hasChanges(outcome))
    #expect(PodcastBackupPresentation.finishedMessage(outcome) == "Added 1 learned ad.")
    outcome.showsAdded = 2
    #expect(
      PodcastBackupPresentation.previewMessage(outcome, syncOn: false)
        == "Adds 2 shows and 1 learned ad. Newer progress on this device is kept, and nothing is removed.")
  }

  @Test func smartListLineAppearsOnlyWhenListsWereAddedSkippedOrDropped() {
    var outcome = PodcastSmartListsSnapshotCodec.RestoreOutcome()
    #expect(PodcastBackupPresentation.smartListsLine(outcome) == nil)
    outcome.showsNotOnDevice = 3
    #expect(PodcastBackupPresentation.smartListsLine(outcome) == nil)
    outcome.listsAdded = 2
    outcome.listsDroppedOverLimit = 1
    #expect(
      PodcastBackupPresentation.smartListsLine(outcome)
        == "Added 2 smart lists. 1 smart list couldn’t be added past the limit of 50.")
    #expect(
      PodcastBackupPresentation.finishedMessage(NativePodcastRestoreOutcome(), smartLists: outcome)
        == "Added 2 smart lists. 1 smart list couldn’t be added past the limit of 50.")
    #expect(
      PodcastBackupPresentation.previewMessage(NativePodcastRestoreOutcome(), syncOn: false, smartLists: 2)
        == "Adds 2 smart lists. Newer progress on this device is kept, and nothing is removed.")
  }

  @Test func aFailedSmartListRestoreSaysSoAfterTheRestoredState() {
    #expect(
      PodcastBackupPresentation.finishedMessage(NativePodcastRestoreOutcome(), smartListsFailed: true)
        == "Smart lists couldn’t be restored.")
  }
}
