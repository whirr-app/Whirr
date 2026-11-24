import Persistence
import SyncEngine

/// User-facing copy and small display mappings for the Server & Account Settings destination.
public enum ServerAccountSettingsCopy {
  public static let destinationTitle = "Server & Account"
  public static let destinationDetail = "Connection, account and libraries"

  public static let loading = "Loading saved account details…"
  public static let failedTitle = "Account details unavailable"
  public static let failedMessage =
    "The saved account details could not be read. Try again when the account is available."
  public static let tryAgain = "Try Again"

  public static let serverHeader = "Server"
  public static let serverVersion = "Server Version"
  public static let accountHeader = "Account"
  public static let username = "Username"
  public static let accountType = "Type / Role"
  public static let connectionHeader = "Connection"
  public static let liveProfile = "Live account details"
  public static let checking = "Checking…"
  public static let available = "Available"
  public static let unavailable = "Unavailable"
  public static let profileUnavailableMessage =
    "Saved server and library details are shown; live details are unavailable."
  public static let librarySync = "Library sync"
  public static let syncInProgress = "Syncing"
  public static let syncIncomplete = "Last run incomplete"
  public static let syncReady = "Ready"
  public static let syncNotCompleted = "No completed sync"
  public static let oldestLibraryCompletion = "Oldest library completion"
  public static let noCompletedLibrary = "Not yet"
  public static let syncFooter = "Shows the oldest completed library sync."

  public static let headersHeader = "Custom Headers"
  public static let headersInPlay = "Headers in play"
  public static let noHeaders = "None"
  public static let headersFooter = "Header values are never displayed."

  public static func syncStatus(for status: LibrarySyncStatus) -> String {
    if status.isRunning { return syncInProgress }
    if status.lastRunIncomplete { return syncIncomplete }
    return status.lastCompletedAt == nil ? syncNotCompleted : syncReady
  }

  public static func profileStatus(for state: ServerAccountSettingsModel.ProfileState) -> String {
    switch state {
    case .loading: return checking
    case .available: return available
    case .unavailable: return unavailable
    }
  }
}
