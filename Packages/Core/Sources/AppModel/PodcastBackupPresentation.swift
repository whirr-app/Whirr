import Foundation
import Persistence
import SyncEngine

/// Copy for Settings > Podcasts > Backups.
public enum PodcastBackupPresentation {
  public static let createBackup = "Create Backup…"
  public static let preparingBackup = "Preparing Backup…"
  public static let createFailed = "Whirr couldn’t prepare a backup. Try again later."
  public static let restoreBackup = "Restore Backup…"
  public static let readingBackup = "Reading Backup…"
  public static let restoring = "Restoring…"
  /// Private feed addresses can themselves be sensitive, so the files are never described as
  /// anonymous or safe to share.
  public static let footer =
    "Backups include podcast addresses, listening state and the ads Whirr has learned to skip, but not downloaded audio, transcripts or passwords. Files are stored wherever you choose. Shows that need a password won’t update until you enter it again."

  public static let automaticHeader = "Automatic Backups"
  public static let automaticToggle = "Back Up Automatically"
  public static let automaticFolder = "Folder"
  public static let automaticLastBackup = "Last Backup"
  public static let automaticNever = "Never"
  public static let automaticRunning = "Backing Up…"
  public static let automaticFooter =
    "When you open Whirr, it backs up to your chosen folder at most once a day and keeps the 3 most recent backups. Other files in the folder aren’t touched."
  public static let automaticChoiceFailed =
    "Whirr couldn’t save a backup to that folder. Choose another folder or try again."

  public static let automaticChoiceKeptExistingBackups =
    "That folder already has backups, and there are no podcasts on this device to back up. Restore a backup first, then choose the folder again."

  public static func automaticFailureMessage(_ failure: PodcastAutoBackupFailure) -> String {
    switch failure {
    case .folderUnavailable: "Whirr can’t reach the backup folder. Tap Folder to choose it again."
    case .writeFailed: "The last backup didn’t finish. Whirr will try again next time you open it."
    case .nothingToBackUp:
      "There are no podcasts on this device to back up, so the backups already in the folder were kept."
    }
  }

  public static let previewTitle = "Restore This Backup?"
  public static let previewConfirm = "Merge Backup"
  public static let nothingToRestoreTitle = "Already Up to Date"
  public static let nothingToRestoreMessage = "This device already has everything in this backup."
  public static let finishedTitle = "Backup Restored"
  public static let failedTitle = "Couldn’t Restore Backup"

  public static func failureMessage(_ failure: PodcastBackupRestoreModel.Failure) -> String {
    switch failure {
    case .unreadable: "This file isn’t a Whirr podcast backup, or it’s damaged."
    case .newerVersion: "This backup was made by a newer version of Whirr. Update Whirr to restore it."
    case .syncNotReady:
      "iCloud Sync couldn’t finish, so nothing was restored. Try again when you’re online and sync is up to date."
    case .couldNotRestore: "Whirr couldn’t restore this backup. Nothing on this device was changed."
    }
  }

  public static func exportSummary(_ export: PodcastBackupExport) -> String {
    var text = "\(count(export.showCount, "show")) and \(count(export.episodeCount, "episode"))."
    if export.skippedShows > 0 {
      text += " \(count(export.skippedShows, "show")) with addresses Whirr can’t back up "
      text += export.skippedShows == 1 ? "is left out." : "are left out."
    }
    if export.skippedEpisodes > 0 {
      text += " \(count(export.skippedEpisodes, "episode")) that can’t be backed up "
      text += export.skippedEpisodes == 1 ? "is left out." : "are left out."
    }
    if export.learnedAdCount > 0 { text += " Includes \(count(export.learnedAdCount, "learned ad"))." }
    return text
  }

  public static func hasChanges(_ outcome: NativePodcastRestoreOutcome) -> Bool {
    outcome.showsAdded > 0 || outcome.statesApplied > 0 || outcome.savesAdded > 0 || outcome.bookmarkApplied
      || outcome.globalSettingsApplied || outcome.learnedAdsAdded > 0
  }

  public static func previewMessage(
    _ outcome: NativePodcastRestoreOutcome, syncOn: Bool, smartLists: Int = 0
  ) -> String {
    var text = describe(
      outcome, added: "Adds", restored: "Restores", restoredAfterAdds: "restores", smartLists: smartLists)
    text += " Newer progress on this device is kept, and nothing is removed."
    if syncOn { text += " iCloud Sync runs first, and restored podcasts then sync to your other devices." }
    return text
  }

  public static func finishedMessage(
    _ outcome: NativePodcastRestoreOutcome, smartLists: PodcastSmartListsSnapshotCodec.RestoreOutcome? = nil,
    smartListsFailed: Bool = false
  ) -> String {
    let lists = smartListsFailed ? smartListsFailedLine : smartLists.flatMap(smartListsLine)
    guard hasChanges(outcome) else {
      var text = outcome.episodesUnmatched > 0 ? unmatched(outcome.episodesUnmatched) : "Nothing needed restoring."
      if let lists { text = outcome.episodesUnmatched > 0 ? text + " " + lists : lists }
      return text
    }
    var text = describe(outcome, added: "Added", restored: "Restored", restoredAfterAdds: "restored")
    if outcome.showsAdded > 0 { text += " New shows fill in their episodes as they refresh." }
    if outcome.episodesUnmatched > 0 { text += " " + unmatched(outcome.episodesUnmatched) }
    if let lists { text += " " + lists }
    return text
  }

  /// The podcast state restored; only the lists did not.
  public static let smartListsFailedLine = "Smart lists couldn’t be restored."

  /// Nil unless a list was added, skipped or dropped.
  public static func smartListsLine(_ outcome: PodcastSmartListsSnapshotCodec.RestoreOutcome) -> String? {
    var parts: [String] = []
    if outcome.listsAdded > 0 { parts.append("Added \(count(outcome.listsAdded, "smart list")).") }
    if outcome.listsSkippedExisting > 0 {
      parts.append("\(count(outcome.listsSkippedExisting, "smart list")) already on this device was kept.")
    }
    if outcome.listsDroppedOverLimit > 0 {
      parts.append(
        "\(count(outcome.listsDroppedOverLimit, "smart list")) couldn’t be added past the limit of \(PodcastSmartListsSnapshotCodec.maxLists)."
      )
    }
    if outcome.listsSkippedInvalid > 0 {
      parts.append("\(count(outcome.listsSkippedInvalid, "smart list")) couldn’t be read.")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }

  // MARK: - Helpers

  private static func describe(
    _ outcome: NativePodcastRestoreOutcome, added: String, restored: String, restoredAfterAdds: String,
    smartLists: Int = 0
  ) -> String {
    var additions: [String] = []
    if outcome.showsAdded > 0 { additions.append(count(outcome.showsAdded, "show")) }
    if outcome.statesApplied > 0 { additions.append("progress for \(count(outcome.statesApplied, "episode"))") }
    if outcome.savesAdded > 0 { additions.append(count(outcome.savesAdded, "saved episode")) }
    if outcome.learnedAdsAdded > 0 { additions.append(count(outcome.learnedAdsAdded, "learned ad")) }
    if smartLists > 0 { additions.append(count(smartLists, "smart list")) }
    var restorations: [String] = []
    if outcome.globalSettingsApplied { restorations.append("podcast settings") }
    if outcome.bookmarkApplied { restorations.append("the last episode you played") }

    switch (additions.isEmpty, restorations.isEmpty) {
    case (false, true): return "\(added) \(list(additions))."
    case (true, false): return "\(restored) \(list(restorations))."
    case (false, false): return "\(added) \(list(additions)), and \(restoredAfterAdds) \(list(restorations))."
    case (true, true): return ""
    }
  }

  private static func unmatched(_ episodes: Int) -> String {
    "\(count(episodes, "episode")) couldn’t be matched."
  }

  static func count(_ value: Int, _ noun: String) -> String {
    "\(value) \(noun)\(value == 1 ? "" : "s")"
  }

  private static func list(_ items: [String]) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
  }
}
