import Persistence
import SyncEngine

/// User-facing copy for `ItemDownloadModel`, owned and tested in AppModel like `SetupFlowCopy`
/// and `PlaybackCopy`: a screen never hardcodes its own download-state strings. Every
/// `ItemDownloadStatus` case has one distinct message here.
public enum ItemDownloadCopy {
  public static let notDownloaded = "Not downloaded"
  /// The cellular-opt-in explanation: says why the download is held and where to change that
  /// default. The toggle itself belongs to `SettingsModel`.
  public static let waitingForWiFi =
    "Waiting for Wi-Fi. Downloads only use Wi-Fi unless you turn on cellular downloads in Settings."
  public static let queued = "Queued to download"
  public static let paused = "Download paused"
  public static let pausedAuth = "Download paused. Sign in again to continue."
  public static let interrupted = "Download interrupted. It will retry automatically."
  public static let deleting = "Removing download…"
  public static let completed = "Downloaded"
  public static let downloadingIndeterminate = "Downloading…"

  /// The three explicit format choices' menu titles, shared by the detail screen's download bubble
  /// and the row long-press menu's download submenu so the two surfaces name each intent the same.
  ///
  /// "eBook" matches the spelling of every other media label (`HomeRowPresentation.badgeLabel`,
  /// `MediaFilterCopy`).
  public static func formatLabel(for format: ItemDownloadFormat) -> String {
    switch format {
    case .audio: return "Download Audiobook"
    case .ebook: return "Download eBook"
    case .both: return "Download Both"
    }
  }

  public static func downloading(progressFraction: Double) -> String {
    let percent = Int((progressFraction * 100).rounded())
    return "Downloading… \(percent)%"
  }

  /// The failure alert's title; the per-category reason below is its message, so the two never
  /// repeat each other.
  public static let failedTitle = "Download failed"

  /// One distinct, actionable message per `DownloadErrorCategory`; no two errors share a message
  /// (as in `SetupFlowCopy.recoveryMessage(for:)`).
  public static func failed(category: DownloadErrorCategory) -> String {
    "\(failedTitle). \(failureReason(category: category))"
  }

  /// The reason alone, for a surface that has already said "Download failed" in its title.
  ///
  /// `.validation` names no specific cause: it covers a non-success status, a non-audio response,
  /// an empty, oversized or truncated file, and an unsafe path, and the user can only try again.
  public static func failureReason(category: DownloadErrorCategory) -> String {
    switch category {
    case .transport:
      return "Check your connection and try again."
    case .auth:
      return "Sign in again to continue."
    case .validation:
      return "The server didn't send a valid file. Try again later."
    case .storage:
      return "The file couldn't be saved. Try again."
    case .lowDisk:
      return "This device is out of storage space."
    case .unknown:
      return "Try again."
    }
  }

  /// One user-initiated download intent, for `actionFailed(_:error:)`'s per-action copy.
  public enum Action: Sendable {
    case download
    case pause
    case resume
    case remove
  }

  /// Why an intent the user just tapped didn't take effect. Every intent is fallible (planning
  /// fetches the item detail, purging touches the filesystem), and a silent failure looks like a
  /// dead button. Each `DownloadPlanningError` case explains its own cause; everything else gets a
  /// plain per-action retry line (no two actions share one).
  public static func actionFailed(_ action: Action, error: any Error) -> String {
    if let planning = error as? DownloadPlanningError {
      switch planning {
      case .accountRemovalInProgress:
        return "Your account is being removed, so no new downloads can start."
      case .notAuthenticated:
        return "Couldn't start this download. Sign in again, then try again."
      case .unknownItem:
        return "Couldn't start this download. This title isn't in your synced library yet."
      case .unknownPodcastEpisode:
        return "Couldn't start this download. This episode isn't in your synced podcast yet."
      case .episodeUnavailable:
        return "This episode isn't available for offline download."
      case .podcastEpisodesUnsupported:
        return "Downloading podcast episodes isn't supported yet."
      case .metadataValidationFailed:
        return "Couldn't start this download. The server didn't return a usable file list for this title."
      }
    }
    // Every ebook refusal describes server state and does not clear by tapping Download again,
    // so none may fall through to the per-action retry line below. No two causes share a message.
    if let ebook = error as? EbookDownloadPlanningError {
      switch ebook {
      case .ebookFileUnavailable:
        return "Couldn't start this download. The server doesn't list an eBook file for this title."
      case .unsupportedEbookFormat:
        return "This title's eBook isn't an EPUB, so it can't be downloaded for reading here."
      case .missingExpectedSize:
        return
          "Couldn't start this download. The server didn't report a size for this eBook file. "
          + "Re-scanning the library on your server usually fixes this."
      }
    }
    switch action {
    case .download: return "Couldn't start this download. Try again."
    case .pause: return "Couldn't pause this download. Try again."
    case .resume: return "Couldn't resume this download. Try again."
    case .remove: return "Couldn't remove this download. Try again."
    }
  }

  // MARK: - Dense-row forms

  /// The row-sized form of each status. The strings above suit a detail screen with a paragraph's
  /// width; a list row has about 300 pt for three status labels, where the same sentence truncates
  /// and squeezes out its neighbours. These stay distinct per status and per
  /// `DownloadErrorCategory`, so a shorter message is never ambiguous.
  public static let shortWaitingForWiFi = "Waiting for Wi-Fi"
  public static let shortQueued = "Queued"
  public static let shortPaused = "Paused"
  public static let shortPausedAuth = "Paused, sign in"
  public static let shortInterrupted = "Retrying"
  public static let shortDeleting = "Removing"

  public static func shortFailed(category: DownloadErrorCategory) -> String {
    switch category {
    case .transport: return "Failed, no connection"
    case .auth: return "Failed, sign in"
    case .validation: return "Failed, invalid file"
    case .storage: return "Failed, not saved"
    case .lowDisk: return "Failed, no space"
    case .unknown: return "Download failed"
    }
  }

  public static func shortText(
    for status: ItemDownloadStatus, isDownloadSizeKnown: Bool = true
  ) -> String {
    switch status {
    case .notDownloaded: return notDownloaded
    case .waitingForWiFi: return shortWaitingForWiFi
    case .queued: return shortQueued
    case .downloading(let progressFraction):
      return isDownloadSizeKnown ? downloading(progressFraction: progressFraction) : downloadingIndeterminate
    case .paused: return shortPaused
    case .pausedAuth: return shortPausedAuth
    case .interrupted: return shortInterrupted
    case .deleting: return shortDeleting
    case .failed(let category): return shortFailed(category: category)
    case .completed: return completed
    }
  }

  public static func text(
    for status: ItemDownloadStatus, isDownloadSizeKnown: Bool = true
  ) -> String {
    switch status {
    case .notDownloaded: return notDownloaded
    case .waitingForWiFi: return waitingForWiFi
    case .queued: return queued
    case .downloading(let progressFraction):
      return isDownloadSizeKnown ? downloading(progressFraction: progressFraction) : downloadingIndeterminate
    case .paused: return paused
    case .pausedAuth: return pausedAuth
    case .interrupted: return interrupted
    case .deleting: return deleting
    case .failed(let category): return failed(category: category)
    case .completed: return completed
    }
  }
}
