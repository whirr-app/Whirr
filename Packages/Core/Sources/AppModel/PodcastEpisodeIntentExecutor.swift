import Persistence

/// The result delivered by a successful episode intent action.
public enum PodcastEpisodeActionOutcome: Sendable, Equatable {
  case completed
  case saved(SavedShelfSaveOutcome)
}

/// The one AppModel-owned route from a canonical episode action to the injected episode intents.
///
/// The caller supplies the item and episode identity, plus the episode's duration when needed. The
/// current-item check lives here because an intent can finish after the screen has moved to
/// another item, when neither success nor failure belongs on the new screen.
@MainActor
public final class PodcastEpisodeIntentExecutor {
  private let intents: any PodcastEpisodeIntents

  public init(intents: any PodcastEpisodeIntents) {
    self.intents = intents
  }

  /// Executes an intent action and reports only results that still belong to `itemID`.
  /// Navigation-only actions and the transcript produce no callback; their owning view keeps those
  /// concerns out of the intent router.
  public func execute(
    action: MediaItemAction,
    itemID: String,
    episodeID: String,
    duration: Double?,
    currentItemID: @escaping @MainActor () -> String?,
    onSuccess: @escaping @MainActor (PodcastEpisodeActionOutcome) -> Void,
    onFailure: @escaping @MainActor (String) -> Void
  ) async {
    switch action {
    case .openShow, .moreFromCreator, .saveToServer, .removeFromServer, .transcript,
      .sendToWatch, .removeFromWatch, .read, .moreFrom, .sendToEreader, .viewDetails:
      return
    default:
      break
    }

    do {
      let outcome: PodcastEpisodeActionOutcome
      switch action {
      case .playPause:
        try await intents.play(itemID: itemID, episodeID: episodeID)
        outcome = .completed
      case .playNext:
        try await intents.playNext(itemID: itemID, episodeID: episodeID)
        outcome = .completed
      case .addToUpNext:
        try await intents.addToUpNext(itemID: itemID, episodeID: episodeID)
        outcome = .completed
      case .saveForLater:
        let saveOutcome = try await intents.saveForLater(itemID: itemID, episodeID: episodeID)
        outcome = .saved(saveOutcome)
      case .removeFromSaved:
        try await intents.removeFromSaved(itemID: itemID, episodeID: episodeID)
        outcome = .completed
      case .download:
        try await intents.download(itemID: itemID, episodeID: episodeID)
        outcome = .completed
      case .pauseDownload:
        try await intents.pauseDownload(itemID: itemID, episodeID: episodeID)
        outcome = .completed
      case .resumeDownload:
        try await intents.resumeDownload(itemID: itemID, episodeID: episodeID)
        outcome = .completed
      case .removeDownload:
        try await intents.removeDownload(itemID: itemID, episodeID: episodeID)
        outcome = .completed
      case .markAsFinished:
        try await intents.markAsFinished(
          itemID: itemID, episodeID: episodeID, duration: duration)
        outcome = .completed
      case .resetProgress:
        try await intents.resetProgress(itemID: itemID, episodeID: episodeID)
        outcome = .completed
      case .removeFromContinueListening:
        try await intents.removeFromContinueListening(itemID: itemID, episodeID: episodeID)
        outcome = .completed
      case .openShow, .moreFromCreator, .saveToServer, .removeFromServer, .transcript,
        .sendToWatch, .removeFromWatch, .read, .moreFrom, .sendToEreader, .viewDetails:
        return
      }
      guard currentItemID() == itemID else { return }
      onSuccess(outcome)
    } catch {
      guard currentItemID() == itemID else { return }
      onFailure(Self.errorMessage(for: error))
    }
  }

  /// The only error mapping for an episode intent: an intent may provide user-ready copy, and
  /// every other failure uses the podcast action fallback.
  public static func errorMessage(for error: any Error) -> String {
    (error as? PodcastEpisodeIntentFailure)?.message ?? PodcastCopy.actionFailed
  }
}

/// Maps the App target's stable context-action IDs onto the Core action vocabulary. Keeping this
/// adapter beside the executor lets the show view forward an action without recreating its route
/// switch; navigation actions remain available for the view to handle or ignore.
extension MediaItemAction {
  public init?(actionID: String) {
    switch actionID {
    case "play-pause": self = .playPause
    case "play-next": self = .playNext
    case "add-up-next": self = .addToUpNext
    case "save-for-later": self = .saveForLater
    case "remove-from-saved": self = .removeFromSaved
    case "download": self = .download
    case "pause-download": self = .pauseDownload
    case "resume-download": self = .resumeDownload
    case "remove-download": self = .removeDownload
    case "mark-as-finished": self = .markAsFinished
    case "reset-progress": self = .resetProgress
    case "remove-from-continue-listening": self = .removeFromContinueListening
    case "save-to-server": self = .saveToServer
    case "remove-from-server": self = .removeFromServer
    case "open-show": self = .openShow
    case "more-from-creator": self = .moreFromCreator
    case "transcript": self = .transcript
    case "send-to-watch": self = .sendToWatch
    case "remove-from-watch": self = .removeFromWatch
    case "read": self = .read
    case "more-from": self = .moreFrom
    case "send-to-ereader": self = .sendToEreader
    case "view-details": self = .viewDetails
    default: return nil
    }
  }

  /// The inverse of `init?(actionID:)`, so a menu row's id and its dispatch cannot disagree.
  public var actionID: String {
    switch self {
    case .playPause: "play-pause"
    case .playNext: "play-next"
    case .addToUpNext: "add-up-next"
    case .saveForLater: "save-for-later"
    case .removeFromSaved: "remove-from-saved"
    case .download: "download"
    case .pauseDownload: "pause-download"
    case .resumeDownload: "resume-download"
    case .removeDownload: "remove-download"
    case .markAsFinished: "mark-as-finished"
    case .resetProgress: "reset-progress"
    case .removeFromContinueListening: "remove-from-continue-listening"
    case .saveToServer: "save-to-server"
    case .removeFromServer: "remove-from-server"
    case .openShow: "open-show"
    case .moreFromCreator: "more-from-creator"
    case .transcript: "transcript"
    case .sendToWatch: "send-to-watch"
    case .removeFromWatch: "remove-from-watch"
    case .read: "read"
    case .moreFrom: "more-from"
    case .sendToEreader: "send-to-ereader"
    case .viewDetails: "view-details"
    }
  }
}
