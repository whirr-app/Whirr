import Foundation

/// Which Podcast Data rows Settings > Podcasts shows. Rows for unfinished destinations are omitted
/// rather than disabled.
public enum PodcastDataSettingsPresentation {
  public enum Row: Equatable, CaseIterable, Sendable {
    case iCloudSync
    case backups
  }

  public static func visibleRows(
    iCloudSyncReady: Bool = PodcastDataSettingsReadiness.iCloudSync,
    backupsReady: Bool = PodcastDataSettingsReadiness.backups
  ) -> [Row] {
    var rows: [Row] = []
    if iCloudSyncReady { rows.append(.iCloudSync) }
    if backupsReady { rows.append(.backups) }
    return rows
  }

  public static func iCloudSyncRowValue(isEnabled: Bool) -> String {
    isEnabled ? PodcastDataSettingsCopy.on : PodcastDataSettingsCopy.off
  }
}

/// Copy for the Podcast Data section and the iCloud Sync destination.
public enum PodcastDataSettingsCopy {
  public static let sectionHeader = "Podcast Data"
  public static let sectionFooter =
    "For podcasts followed directly in Whirr. Audiobookshelf data continues to use your server."
  public static let iCloudSyncRowTitle = "iCloud Sync"
  public static let backupsRowTitle = "Backups"
  public static let on = "On"
  public static let off = "Off"

  public static let syncToggleTitle = "Sync Podcasts with iCloud"
  public static let syncDescription = "Keep shows, progress and settings in sync across your devices."
  public static let syncOffNote = "Sync is off on this device. Podcasts here and in iCloud are kept."
  public static let whatGetsSyncedTitle = "What Gets Synced"

  public static let statusTitle = "Status"
  public static let statusUpToDate = "Up to Date"
  public static let statusSyncing = "Syncing"
  public static let statusWaiting = "Waiting for iCloud — Whirr will keep trying"
  public static let statusSignIn = "Sign in to iCloud to sync"
  public static let statusStorageFull = "iCloud storage is full"
  public static let statusNeedsAttention = "Sync needs attention"
  public static let statusInterruptedNote =
    "Some changes haven’t synced yet. Whirr will keep trying."
  public static let statusHeldNote = "Some podcast data couldn’t be synced. It’s kept on this device."
  public static func lastSynced(_ relative: String) -> String { "Last synced \(relative)" }
  public static let tryAgain = "Try Again"
  public static let syncingNow = "Syncing…"
  public static let syncNowFailed = "Sync didn’t finish. Your changes are kept on this device and will sync later."

  public static let recreateZone = "Set Up iCloud Sync Again"
  public static let recreateZoneConfirmTitle = "Set Up iCloud Sync Again?"
  public static let recreateZoneConfirmMessage =
    "Whirr’s podcast data is no longer in this iCloud account. This creates it again and resumes syncing from this device."
  public static let recreateZoneConfirmAction = "Set Up Again"
  public static let recoveryFailed = "Sync couldn’t be restored. Podcasts on this device are kept. Try again later."
  public static func recoveryTitle(for recovery: PodcastCloudSyncStatusPresentation.Recovery) -> String {
    switch recovery {
    case .recreateZone: recreateZone
    case .repairClock: tryAgain
    }
  }

  public static let deleteCloudDataExplanation = "Removes the copy in iCloud. Podcasts on this device aren’t affected."
  public static let deleteCloudData = "Delete Podcast Data from iCloud"
  public static let deleteConfirmTitle = "Delete Podcast Data from iCloud?"
  public static let deleteConfirmMessage =
    "This removes Whirr’s podcast data from this iCloud account. Other devices using iCloud Podcast Sync will stop syncing until you set it up again. Podcasts on this device and backup files you exported are kept."
  public static let deleteConfirmAction = "Delete from iCloud"
  public static let deleting = "Deleting…"
  public static let deleteSucceeded = "Podcast sync data was deleted from iCloud. Sync is off on this device."
  public static let deleteFailed =
    "Whirr couldn’t confirm the deletion. Your iCloud data may still be there. Try again when you’re online."

  public static let consentTitle = "Enable iCloud Podcast Sync?"
  public static let consentMessage =
    "Whirr will send your podcast addresses, listening state and podcast settings to Apple’s iCloud. Existing iCloud podcast data will be merged with this device.\n\nDownloaded audio, feed passwords and Audiobookshelf server data are excluded."
  public static let consentEnable = "Enable Sync"
  public static let consentCancel = "Cancel"
  public static let enableFailedTitle = "Couldn’t Enable Sync"
  public static let enableFailedMessage =
    "Whirr could not create the device record that keeps this choice on this iPhone. Sync stays off. Try again later."

  public static let syncedItems: [String] = [
    "Followed shows and their addresses",
    "Podcast settings, including per-show settings",
    "Show order",
    "Saved for Later",
    "Episode progress and played state",
    "The last episode you played",
  ]
  public static let notSyncedItems: [String] = [
    "Up Next order",
    "Downloaded audio",
    "Feed passwords",
    "Audiobookshelf accounts and library data",
  ]
  public static let encryptionNote =
    "Stored encrypted in Apple’s iCloud. With Advanced Data Protection on, only your trusted devices can read it."
}
