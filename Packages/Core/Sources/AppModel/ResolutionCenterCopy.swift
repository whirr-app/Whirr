import SyncEngine

/// User-facing copy for `ResolutionCenterModel`, owned and tested in AppModel like `StorageCopy`
/// and `ItemDownloadCopy`. The skew keep-local action carries an explicit overwrite warning, never
/// a bare "Are you sure?".
public enum ResolutionCenterCopy {
  public static let loading = "Loading your unresolved items…"
  public static let fetchErrorTitle = "Couldn't Load Resolution Center"
  public static let fetchErrorMessage =
    "We couldn't reach the server to load your unresolved items. Check your connection and try again."
  public static let retry = "Retry"
  public static let actionErrorTitle = "Resolution Failed"
  public static let actionFailed = "Couldn't resolve this issue. Try again."
  public static let dismiss = "OK"

  public static let emptyStateTitle = "All Caught Up"
  public static let emptyStateMessage = "Nothing needs your attention right now."

  public static let cancel = "Cancel"

  // MARK: - Progress conflict

  public static func progressConflictTitle(itemTitle: String) -> String {
    "Which progress is right for \"\(itemTitle)\"?"
  }
  public static let progressConflictMessage =
    "This device and the server disagree about how far you got in this book. Choose which progress to keep."
  public static let keepLocalProgress = "Keep This Device's Progress"
  public static let takeServerProgress = "Use the Server's Progress"

  // MARK: - Progress conflict: bulk "use server for all"

  public static let takeServerForAllProgressConflicts = "Use Server Progress for All"
  public static let takeServerForAllProgressConflictsConfirmationTitle =
    "Use the Server's Progress for Everything?"
  public static let takeServerForAllProgressConflictsConfirmationMessage =
    "This replaces this device's progress with the server's for every conflicting item listed here. Each item's local progress is discarded and can't be recovered."
  public static let confirmTakeServerForAllProgressConflicts = "Use Server Progress"
  public static func takeServerForAllProgressConflictsPartialFailureMessage(failedCount: Int) -> String {
    failedCount == 1
      ? "Used the server's progress for the rest, but 1 item couldn't be resolved. Try it again from that item."
      : "Used the server's progress for the rest, but \(failedCount) items couldn't be resolved. Try them again individually."
  }

  // MARK: - Skew confirmation

  public static func skewConfirmationTitle(itemTitle: String) -> String {
    "Confirm Offline Listening for \"\(itemTitle)\""
  }
  public static let skewConfirmationMessage =
    "Some offline listening for this book was recorded further ahead than expected. Choose which progress should count."
  public static let keepLocalSkew = "Keep This Device's Progress"
  public static let takeServerSkew = "Use the Server's Progress Instead"

  public static func keepLocalSkewOverwriteWarningTitle(itemTitle: String) -> String {
    "Overwrite the Server's Progress for \"\(itemTitle)\"?"
  }
  public static let keepLocalSkewOverwriteWarningMessage =
    "This device's recorded listening time is ahead of what the server's clock expects. Keeping it overwrites whatever progress the server currently has."
  public static let confirmOverwrite = "Overwrite"

  // MARK: - Dead letter

  public static func deadLetterTitle(itemTitle: String) -> String {
    "Couldn't Sync \"\(itemTitle)\""
  }
  public static func deadLetterMessage(reason: String?) -> String {
    guard let reason, reason.isEmpty == false else {
      return "This change couldn't be sent to the server. Discard it, or try refreshing first."
    }
    return "This change couldn't be sent to the server (\(reason)). Discard it, or try refreshing first."
  }
  public static let discardDeadLetter = "Discard"
  public static let refreshMetadata = "Refresh and Retry"

  // MARK: - Paused-auth download

  public static func pausedAuthTitle(itemTitle: String) -> String {
    "\"\(itemTitle)\" Is Paused"
  }
  public static let pausedAuthMessage =
    "This download paused because you're signed out. Sign in again to continue."
  public static let reAuthenticate = "Sign In Again"

  // MARK: - Per-kind dispatch

  /// One action a resolution item's kind offers. `ResolutionCenterModel`'s method of the same
  /// name performs it.
  public enum Action: Sendable, Equatable {
    case keepLocalProgress
    case takeServerProgress
    case keepLocalSkew
    case takeServerSkew
    case discardDeadLetter
    case refreshMetadata
    case reAuthenticate
  }

  /// The ordered action set for `kind`.
  public static func actions(for kind: ResolutionOpenItem.Kind) -> [Action] {
    switch kind {
    case .progressConflict: return [.keepLocalProgress, .takeServerProgress]
    case .skewConfirmation: return [.keepLocalSkew, .takeServerSkew]
    case .deadLetter: return [.discardDeadLetter, .refreshMetadata]
    case .pausedAuthDownload: return [.reAuthenticate]
    }
  }

  public static func label(for action: Action) -> String {
    switch action {
    case .keepLocalProgress: return keepLocalProgress
    case .takeServerProgress: return takeServerProgress
    case .keepLocalSkew: return keepLocalSkew
    case .takeServerSkew: return takeServerSkew
    case .discardDeadLetter: return discardDeadLetter
    case .refreshMetadata: return refreshMetadata
    case .reAuthenticate: return reAuthenticate
    }
  }

  public static func title(for kind: ResolutionOpenItem.Kind, itemTitle: String) -> String {
    switch kind {
    case .progressConflict: return progressConflictTitle(itemTitle: itemTitle)
    case .skewConfirmation: return skewConfirmationTitle(itemTitle: itemTitle)
    case .deadLetter: return deadLetterTitle(itemTitle: itemTitle)
    case .pausedAuthDownload: return pausedAuthTitle(itemTitle: itemTitle)
    }
  }

  public static func message(for kind: ResolutionOpenItem.Kind) -> String {
    switch kind {
    case .progressConflict: return progressConflictMessage
    case .skewConfirmation: return skewConfirmationMessage
    case .deadLetter(_, let reason): return deadLetterMessage(reason: reason)
    case .pausedAuthDownload: return pausedAuthMessage
    }
  }
}
