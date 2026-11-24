import Persistence
import SyncEngine

public enum NativeEpisodeServerSaveCopy {
  public static let none = "Not saved on server"
  public static let preparing = "Preparing"
  public static let requested = "Requested on server"
  public static let saved = "Saved on server"
  public static let removing = "Removing"
  public static let removed = "Removed from server"

  public static let saveAction = MediaActionCopy.saveToServer.title
  public static let removeAction = MediaActionCopy.removeFromServer.title
  public static let saveHint = "Copies this episode to the Audiobookshelf server."
  public static let removeHint =
    "Removes this episode from Audiobookshelf for everyone on the server."
  public static let saveSystemImage = MediaActionCopy.saveToServer.systemImage
  public static let removeSystemImage = MediaActionCopy.removeFromServer.systemImage

  // Save has no consequence confirmation: the menu tap saves. Removal keeps one because it
  // deletes the server's record for everyone. The destination sheet below is not a confirmation
  // of the save; it appears only when the coordinator has no show to save into yet.

  public static let createShowAndSaveAction = "Create show and save episode"
  public static func createShowAndSaveAction(episodeCount: Int = 1) -> String {
    episodeCount == 1 ? createShowAndSaveAction : "Create show and save \(episodeCount) episodes"
  }
  public static let futureEpisodesHint =
    "Future episodes from this podcast will save there directly."
  public static let chooseDestinationExplanation =
    "No matching show exists on Audiobookshelf. Choose where to create this podcast. Each library "
    + "lists the folders configured for it on the server, and Whirr creates the podcast inside the "
    + "folder you choose."
  public static let chooseExistingShowExplanation =
    "More than one show on Audiobookshelf uses this podcast\u{2019}s feed. Choose the existing "
    + "show to save this episode to."
  public static func chooseExistingShowExplanation(episodeCount: Int = 1) -> String {
    episodeCount == 1
      ? chooseExistingShowExplanation
      : "More than one show on Audiobookshelf uses this podcast\u{2019}s feed. Choose the existing "
        + "show to save these \(episodeCount) episodes to."
  }
  public static let existingShowHint = "Saves this episode to this existing Audiobookshelf show."
  public static func existingShowHint(episodeCount: Int = 1) -> String {
    episodeCount == 1
      ? existingShowHint
      : "Saves these \(episodeCount) episodes to this existing Audiobookshelf show."
  }
  public static let noExistingShowExplanation =
    "The matching show on Audiobookshelf is no longer available. Try saving again."

  /// "Podcasts" for the Docker default, where the library and its one folder share a name;
  /// otherwise both names, in the order Audiobookshelf nests them.
  public static func destinationName(library: String, folder: String) -> String {
    library.compare(folder, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
      ? library
      : "\(library) \u{203A} \(folder)"
  }

  public static func destinationPreview(
    library: String,
    folder: String,
    podcastName: String?
  ) -> String {
    let destination = "\(library) \u{203A} \(folder)"
    guard let podcastName else { return destination }
    return "\(destination) \u{203A} \(podcastName)"
  }

  /// One run of the sole-destination sentence. The sheet draws `emphasised` runs in bold so the
  /// two things the user is committing to, the show and where it goes, stand out from the prose;
  /// VoiceOver reads the joined sentence unchanged.
  public enum TextRun: Sendable, Equatable {
    case plain(String)
    case emphasised(String)

    public var text: String {
      switch self {
      case .plain(let text), .emphasised(let text): return text
      }
    }
  }

  /// "Create 'Night Vale' in Podcasts and save this episode." as runs; the follow-up about
  /// future episodes is `createInSoleDestinationFooter`.
  public static func createInSoleDestinationRuns(
    podcastName: String?,
    destinationName: String,
    episodeCount: Int = 1
  ) -> [TextRun] {
    let episodeText =
      episodeCount == 1
      ? " and save this episode."
      : " and save these \(episodeCount) episodes."
    guard let podcastName else {
      return [
        .plain("This will create this podcast in "),
        .emphasised(destinationName),
        .plain(episodeText),
      ]
    }
    return [
      .plain("Create "),
      .emphasised("\u{2018}\(podcastName)\u{2019}"),
      .plain(" in "),
      .emphasised(destinationName),
      .plain(episodeText),
    ]
  }

  public static func createInSoleDestinationFooter(podcastName: String?) -> String {
    podcastName == nil
      ? "Future episodes from the same podcast will save there directly."
      : futureEpisodesHint
  }

  /// The whole explanation as one plain sentence pair, for VoiceOver and for tests.
  public static func createInSoleDestinationExplanation(
    podcastName: String?,
    destinationName: String,
    episodeCount: Int = 1
  ) -> String {
    createInSoleDestinationRuns(
      podcastName: podcastName, destinationName: destinationName, episodeCount: episodeCount
    )
    .map(\.text).joined()
      + " " + createInSoleDestinationFooter(podcastName: podcastName)
  }

  /// A full spoken sentence for the confirming control and for each picker row, so VoiceOver
  /// says what will be created and where before the user commits.
  public static func createAccessibilityLabel(
    podcastName: String?,
    destinationName: String,
    episodeCount: Int = 1
  ) -> String {
    let episodeText =
      episodeCount == 1
      ? "and save this episode"
      : "and save these \(episodeCount) episodes"
    guard let podcastName else {
      return "Create this podcast in \(destinationName) \(episodeText)"
    }
    return "Create \u{2018}\(podcastName)\u{2019} in \(destinationName) \(episodeText)"
  }

  public static func existingShowAccessibilityLabel(
    showName: String,
    episodeCount: Int = 1
  ) -> String {
    episodeCount == 1
      ? "Save this episode to the existing show \u{2018}\(showName)\u{2019}"
      : "Save these \(episodeCount) episodes to the existing show \u{2018}\(showName)\u{2019}"
  }

  /// Shown instead of a picker when no library offers a configured folder. Names the libraries
  /// when there are any, so the fix is clear: the folder is added on the server, not in Whirr.
  public static func noDestinationExplanation(libraryNames: [String]) -> String {
    switch libraryNames.count {
    case 0:
      return "Audiobookshelf has no podcast library this account can save to. Add a podcast "
        + "library with a folder on the server, then try again."
    case 1:
      return "\(libraryNames[0]) has no folder configured on Audiobookshelf. Add a folder to the "
        + "library on the server, then try again."
    default:
      return "None of the podcast libraries on Audiobookshelf has a folder configured. Add a "
        + "folder to a library on the server, then try again."
    }
  }

  /// The second sentence is required by the NP12 plan, not optional politeness: removal deletes
  /// the server's episode record, and whether the underlying file's storage is ever reclaimed was
  /// never established by live evidence. Claiming reclaimed space would be an unproven promise.
  public static let removeConsequence =
    "Removing this episode removes the episode, its progress, and its playlist references for "
    + "everyone on the server. Whether storage on the server is reclaimed is not known."

  public static let saveUncertain =
    "The save outcome is unknown. Whirr will check the server."
  public static let removeUncertain =
    "The removal outcome is unknown. Whirr will check the server."

  /// The uncertainty message for the half of the lifecycle the attempt actually stalled in.
  public static func uncertain(phase: NativeEpisodeServerSavePhase) -> String {
    switch phase {
    case .save: return saveUncertain
    case .remove: return removeUncertain
    }
  }

  public static func disabledReason(_ reason: NativeEpisodeServerSaveDisabledReason) -> String {
    switch reason {
    case .permissionChanged:
      return "Saving or removing on the server is no longer permitted."
    case .invalidDestination:
      return "This episode cannot be saved because the server destination is no longer valid."
    case .credentialedFeed:
      return "Episodes from private feeds cannot be saved to the server."
    case .unsubscribed:
      return "This feed is no longer subscribed."
    case .missingEpisode:
      return "This episode is no longer available."
    case .unavailable:
      return "Saving or removing on the server is unavailable right now."
    case .uncertainOutcome:
      return "The server operation has an unknown outcome and must be checked before continuing."
    case .removalInProgress:
      return "Removal is already in progress."
    }
  }

  public static func disabledReason(for category: NativeEpisodeServerSaveErrorCategory)
    -> String
  {
    switch category {
    case .permissionChanged, .accountReplaced:
      return disabledReason(.permissionChanged)
    case .invalidDestination, .staleIdentity, .incompleteEpisodeList, .malformedResponse:
      return disabledReason(.invalidDestination)
    case .credentialedFeed:
      return disabledReason(.credentialedFeed)
    case .unsubscribed:
      return disabledReason(.unsubscribed)
    case .missingEpisode:
      return disabledReason(.missingEpisode)
    case .transport, .serverFailure, .cancelled, .localPersistence, .unknown:
      return disabledReason(.unavailable)
    }
  }

  /// A complete spoken sentence for each presentation state; visual labels stay short.
  public static func accessibilityLabel(for status: NativeEpisodeServerSaveStatus) -> String {
    switch status {
    case .none:
      return "This episode is not saved on the server."
    case .preparing:
      return "Whirr is preparing to save this episode on the server."
    case .requested:
      return "The server accepted the save request but has not confirmed this episode yet."
    case .saved:
      return "This episode is saved on the server."
    case .removing:
      return "Whirr is removing this episode from the server."
    case .removed:
      return "This episode was removed from Audiobookshelf."
    case .uncertain(_, .save):
      return "The save outcome is unknown. Whirr will check the server."
    case .uncertain(_, .remove):
      return "The removal outcome is unknown. Whirr will check the server."
    case .failed(_, .save):
      return "Saving this episode on the server failed and needs attention."
    case .failed(_, .remove):
      return "Removing this episode from the server failed and needs attention."
    }
  }

  public static func text(for status: NativeEpisodeServerSaveStatus) -> String {
    switch status {
    case .none: return none
    case .preparing: return preparing
    case .requested: return requested
    case .saved: return saved
    case .removing: return removing
    case .removed: return removed
    case .uncertain(let category, let phase):
      _ = category
      return uncertain(phase: phase)
    case .failed(let category, _):
      return disabledReason(for: category)
    }
  }
}
