import Foundation
import Persistence

public enum PodcastShowRecoveryPresentation {
  public static let title = "Needs attention"
  public static let retryPasswordLabel = "Retry password"
  public static let removeFeedLabel = "Remove feed"
}

/// AppModel-owned item actions, the one vocabulary for an episode's and a book's menu. The App target
/// maps these closed values onto DesignSystem context actions and forwards them to the owning
/// model; no view derives an action from a persistence status or invents download copy.
public enum MediaItemAction: Sendable, Equatable, Hashable, CaseIterable {
  /// Start this episode, or pause it when it is the one already playing.
  case playPause
  case playNext
  case addToUpNext
  /// Save this episode for later. This and `.removeFromSaved` are a stateful pair: current
  /// membership decides which of the two the menu offers, never both.
  case saveForLater
  /// Remove this episode from Saved for Later; offered only while the episode is saved.
  case removeFromSaved
  case download
  case pauseDownload
  case resumeDownload
  case removeDownload
  case markAsFinished
  case resetProgress
  case removeFromContinueListening
  case saveToServer
  case removeFromServer
  /// Navigate to the episode's show. Meaningless on the show screen itself, which is the only
  /// surface that suppresses it.
  case openShow
  /// Search for everything else by this podcast's creator. The view omits it for an episode whose
  /// creator is unknown. That is a property of the data, not of the surface, so it stays in the
  /// canonical list.
  case moreFromCreator
  /// Open the episode's on-device transcript. Offered only for a downloaded episode whose caller
  /// says it can be transcribed (`offersTranscript`), since transcription reads the local file.
  case transcript
  /// Send this native-RSS episode's phone file to the active Apple Watch. Never in the download
  /// control's set: the Watch copy is its own entry.
  case sendToWatch
  /// Ask the Watch to drop its copy of this episode.
  case removeFromWatch

  // Book entries. No episode surface offers these; `BookMenuPresentation` does.

  /// Open the reader. An ebook's opening entry, after any playback entries of a mixed item.
  case read
  /// The author and narrator links, behind one "More from…" submenu when both apply. The episode
  /// counterpart is `.moreFromCreator`, a single row.
  case moreFrom
  /// Send the ebook to an e-reader: one row for one device, a submenu for several.
  case sendToEreader
  /// The item's own page, for the document Whirr cannot open (`.unsupportedDocument`).
  case viewDetails
}

extension MediaItemAction {
  /// The progress policy's entry in the item vocabulary, so books and episodes map it one way.
  public init(_ progress: MediaProgressAction) {
    switch progress {
    case .markAsFinished: self = .markAsFinished
    case .resetProgress: self = .resetProgress
    case .removeFromContinueListening: self = .removeFromContinueListening
    }
  }
}

/// The App's projection of the phone's desired Watch set for one episode, passed into the canonical
/// episode menu. `nil` hides both Watch entries: there is no Watch app, the episode is not a
/// native-RSS episode, or its identity cannot cross the wire. AppModel has no WatchConnectivity or
/// `WatchProtocol` edge, so the App target resolves this value from `rssWatchCopy`.
public enum PodcastEpisodeWatchCopy: Sendable, Equatable {
  /// No copy is on the Watch (never sent, removed, declined or failed): the menu offers Send.
  case notOnWatch
  /// A copy is owed, transferring or delivered: the menu offers Remove.
  case onWatch
}

public struct MediaItemActionSection: Sendable, Equatable {
  public let kind: MediaItemMenuSection
  public let actions: [MediaItemAction]

  public init(kind: MediaItemMenuSection, actions: [MediaItemAction]) {
    self.kind = kind
    self.actions = actions
  }
}

/// Where an episode menu is being raised. Surfaces differ only in which entries are meaningless
/// there; `episodeMenuIsIdenticalAcrossSurfacesExceptSuppressedEntries` guards against divergence.
///
/// The player's queue sheet is not a surface here: it raises
/// `ListeningQueueViewPresentation.contextActions`, a media-neutral Play Now / Open pair, as a
/// queue row may be an audiobook.
public enum PodcastMenuSurface: Sendable, Equatable, CaseIterable {
  /// An episode row on its own show's screen.
  case show
  /// An episode row in a list that spans shows (Home's new episodes, search results, library
  /// browse).
  case episodeList
  /// A Home or Podcasts-tab carousel card.
  case card
  /// The episode's own detail card: the sheet with the play capsule, the bookmark, the
  /// download control and the tappable show line.
  case episodeDetail
}

public enum PodcastServerAvailabilityPresentation: Sendable, Equatable {
  case available
  case unavailable
}

public struct PodcastEpisodeRowPresentation: Sendable, Equatable {
  public let episode: PodcastEpisodePresentation
  /// The one line of prose under the title, or `nil` when the feed supplied none. `subtitle` is the
  /// server's short form and wins; the episode description (raw feed HTML) is the fallback.
  public let synopsis: String?
  public let serverAvailability: PodcastServerAvailabilityPresentation
  public let serverAvailabilityText: String
  public let deviceDownloadStatus: ItemDownloadStatus
  public let isDownloadSizeKnown: Bool
  public let deviceDownloadText: String
  public let contextActions: [MediaItemAction]
  /// What a tap on the row's trailing download control does. `nil` renders the glyph inert; see
  /// `PodcastShowPresentation.primaryDeviceAction`.
  public let primaryDeviceAction: MediaItemAction?
}

/// Pure show/episode presentation policy shared by the SwiftUI composition. All copy lives in
/// AppModel and every function is deterministic from caller-supplied values.
public enum PodcastShowPresentation {
  /// The two diagnostic facts are independent: each known half renders alone, and the line
  /// disappears only when the payload supplied neither. A show imported but never
  /// scheduled-checked (`autoDownloadEpisodes: false`, `lastEpisodeCheck: null`) is the "why isn't
  /// this updating?" case this answers.
  ///
  /// `effective` is the show's already-resolved device-side auto-download settings, never
  /// rederived here. Its `PodcastDownloadCopy` state hint joins the server facts when the show
  /// resolves on, and adds nothing when off or omitted.
  public static func diagnosticText(
    diagnostics: PodcastShowDiagnostics?,
    effective: PodcastEffectiveSettings? = nil,
    now: Date
  ) -> String? {
    var parts: [String] = []
    if let autoDownloadEpisodes = diagnostics?.autoDownloadEpisodes {
      parts.append(autoDownloadEpisodes ? PodcastCopy.autoDownloadOn : PodcastCopy.autoDownloadOff)
    }
    if let lastEpisodeCheck = diagnostics?.lastEpisodeCheck {
      parts.append(PodcastCopy.lastCheckedSentence(lastEpisodeCheck, now: now))
    }
    if let effective, effective.isEnabled {
      parts.append(PodcastDownloadCopy.keepLatestStateHint(count: effective.keepLatestCount))
    }
    guard parts.isEmpty == false else { return nil }
    return parts.joined(separator: ". ")
  }

  /// Turns a feed blurb into the plain text the header renders. Feeds send HTML (Audiobookshelf
  /// stores `metadata.description` verbatim), and SwiftUI's `Text` shows markup literally rather
  /// than rendering it, so the tags come out here rather than at the view.
  ///
  /// The episode synopsis gets the same treatment, so both go through `FeedHTML`.
  public static func synopsis(from html: String?) -> String? {
    FeedHTML.plainText(html)
  }

  public static func episode(
    _ episode: PodcastEpisodeSummary,
    surface: PodcastMenuSurface,
    isSaved: Bool? = nil,
    serverSave: NativeEpisodeServerSaveAvailability = .hidden,
    serverRemove: NativeEpisodeServerSaveAvailability = .hidden,
    watchCopy: PodcastEpisodeWatchCopy? = nil
  ) -> PodcastEpisodeRowPresentation {
    let availability: PodcastServerAvailabilityPresentation =
      episode.isAvailableOnServer ? .available : .unavailable
    let actions = episodeActions(
      status: episode.downloadStatus,
      isAvailableOnServer: episode.isAvailableOnServer,
      surface: surface,
      isSaved: isSaved,
      playbackStatus: MediaProgressActionPolicy.playbackStatus(
        progressSeconds: episode.progressSeconds, isFinished: episode.isFinished),
      serverSave: serverSave,
      serverRemove: serverRemove,
      watchCopy: watchCopy)
    return PodcastEpisodeRowPresentation(
      episode: PodcastEpisodePresentation(episode: episode),
      // A stored line is already plain text; stripping it again would decode entities twice.
      synopsis: episode.synopsisLine
        ?? synopsis(from: episode.subtitle) ?? synopsis(from: episode.episodeDescription),
      serverAvailability: availability,
      serverAvailabilityText: episode.isAvailableOnServer
        ? PodcastCopy.availableOnServer
        : PodcastCopy.unavailableOnServer,
      deviceDownloadStatus: episode.downloadStatus,
      isDownloadSizeKnown: episode.isDownloadSizeKnown,
      deviceDownloadText: ItemDownloadCopy.text(
        for: episode.downloadStatus, isDownloadSizeKnown: episode.isDownloadSizeKnown),
      contextActions: actions,
      primaryDeviceAction: primaryDeviceAction(
        status: episode.downloadStatus,
        isAvailableOnServer: episode.isAvailableOnServer))
  }

  /// The single action the row's trailing download control performs on tap, always drawn from
  /// `deviceActions` for the same state so the button never offers what the long-press menu
  /// withholds.
  ///
  /// Three states answer no tap: `.deleting` is mid-purge; `.completed`'s only action is
  /// destructive and stays behind the ellipsis; `.pausedAuth` is fixed by signing in.
  public static func primaryDeviceAction(
    status: ItemDownloadStatus,
    isAvailableOnServer: Bool
  ) -> MediaItemAction? {
    switch status {
    case .notDownloaded: isAvailableOnServer ? .download : nil
    case .waitingForWiFi, .queued: .removeDownload
    case .downloading: .pauseDownload
    case .paused, .interrupted, .failed: .resumeDownload
    case .pausedAuth, .deleting, .completed: nil
    }
  }

  /// The one sectioned episode menu, for every surface. Section order mirrors the book menu:
  /// playback/queue, saved, navigation, device download, progress, server, then the removals. Surfaces subtract from it,
  /// never add or reorder, so a long press means the same everywhere.
  ///
  /// The device portion depends on the episode's download state. `DownloadStatusStore` is coarse,
  /// so a caller holding only an `ItemDownloadPresence` cannot tell a paused transfer from a
  /// queued one; callers with the real status get the real set.
  ///
  /// Progress actions come from `MediaProgressActionPolicy`, as for every book menu, episode swipe
  /// and player overflow. `nil` is the durable untouched state, not an unknown one.
  public static func episodeActionSections(
    status: ItemDownloadStatus,
    isAvailableOnServer: Bool,
    surface: PodcastMenuSurface,
    isSaved: Bool? = nil,
    playbackStatus: ItemPlaybackStatus? = nil,
    isCurrentlyPlaying: Bool = false,
    isHidden: Bool = false,
    serverSave: NativeEpisodeServerSaveAvailability = .hidden,
    serverRemove: NativeEpisodeServerSaveAvailability = .hidden,
    offersTranscript: Bool = false,
    watchCopy: PodcastEpisodeWatchCopy? = nil
  ) -> [MediaItemActionSection] {
    let suppressed = suppressedActions(on: surface)
    return MediaItemMenuSection.allCases.compactMap { kind in
      let candidates: [MediaItemAction] =
        switch kind {
        case .primary: [.playPause, .playNext, .addToUpNext]
        case .saved:
          switch isSaved {
          case nil: []
          case false: [.saveForLater]
          case true: [.removeFromSaved]
          }
        // The show is the meaningful podcast discovery destination. Publisher metadata is often
        // an imprint or network rather than something listeners browse.
        case .navigation:
          [.openShow] + (offersTranscript && status == .completed ? [.transcript] : [])
        case .download:
          deviceActions(status: status, isAvailableOnServer: isAvailableOnServer)
            .filter { $0 != .removeDownload } + watchActions(watchCopy)
        case .progress:
          episodeProgressActions(
            playbackStatus: playbackStatus,
            isCurrentlyPlaying: isCurrentlyPlaying,
            isHidden: isHidden)
        case .server:
          serverAction(.saveToServer, availability: serverSave).map { [$0] } ?? []
        case .destructive:
          deviceActions(status: status, isAvailableOnServer: isAvailableOnServer)
            .filter { $0 == .removeDownload }
            + (serverAction(.removeFromServer, availability: serverRemove).map { [$0] } ?? [])
        }
      let actions = candidates.filter { entry in
        suppressed.contains(entry) == false
      }
      return actions.isEmpty ? nil : MediaItemActionSection(kind: kind, actions: actions)
    }
  }

  /// The flattened form consumed by rows and cards. It derives from the sectioned form so visual
  /// grouping and action order cannot become two competing policies.
  public static func episodeActions(
    status: ItemDownloadStatus,
    isAvailableOnServer: Bool,
    surface: PodcastMenuSurface,
    isSaved: Bool? = nil,
    playbackStatus: ItemPlaybackStatus? = nil,
    isCurrentlyPlaying: Bool = false,
    isHidden: Bool = false,
    serverSave: NativeEpisodeServerSaveAvailability = .hidden,
    serverRemove: NativeEpisodeServerSaveAvailability = .hidden,
    offersTranscript: Bool = false,
    watchCopy: PodcastEpisodeWatchCopy? = nil
  ) -> [MediaItemAction] {
    episodeActionSections(
      status: status,
      isAvailableOnServer: isAvailableOnServer,
      surface: surface,
      isSaved: isSaved,
      playbackStatus: playbackStatus,
      isCurrentlyPlaying: isCurrentlyPlaying,
      isHidden: isHidden,
      serverSave: serverSave,
      serverRemove: serverRemove,
      offersTranscript: offersTranscript,
      watchCopy: watchCopy
    ).flatMap(\.actions)
  }

  /// The only differences between surfaces.
  ///
  /// Suppress what the surface already presents as its own control; keep what it only mentions.
  /// A card or list row has no controls but its swipe actions, so it suppresses almost nothing. The
  /// episode card raises this menu from an ellipsis beside a play capsule, bookmark and download
  /// control under a tappable show line, so repeating those would fill the menu with duplicates.
  public static func suppressedActions(on surface: PodcastMenuSurface) -> Set<MediaItemAction> {
    switch surface {
    // You are already looking at the show.
    case .show: [.openShow]
    case .episodeList, .card: [.saveToServer, .removeFromServer]
    case .episodeDetail:
      [
        // The play capsule.
        .playPause,
        // The bookmark.
        .saveForLater, .removeFromSaved,
        // The download control, which carries every one of these states itself.
        .download, .removeDownload, .pauseDownload, .resumeDownload,
        // The show line under the artwork, which is a link and not merely a caption.
        .openShow,
      ]
    }
  }

  private static func deviceActions(
    status: ItemDownloadStatus,
    isAvailableOnServer: Bool
  ) -> [MediaItemAction] {
    switch status {
    case .notDownloaded:
      return isAvailableOnServer ? [.download] : []
    case .waitingForWiFi, .queued:
      return [.removeDownload]
    case .downloading:
      return [.pauseDownload, .removeDownload]
    case .paused, .interrupted, .failed:
      return [.resumeDownload, .removeDownload]
    case .pausedAuth:
      return [.removeDownload]
    case .deleting:
      return []
    case .completed:
      return [.removeDownload]
    }
  }

  private static func serverAction(
    _ action: MediaItemAction,
    availability: NativeEpisodeServerSaveAvailability
  ) -> MediaItemAction? {
    availability == .hidden ? nil : action
  }

  /// The Watch pair at the end of the device section, which is what makes them per-episode entries
  /// rather than part of the download control's set. No surface suppresses them.
  static func watchActions(_ copy: PodcastEpisodeWatchCopy?) -> [MediaItemAction] {
    switch copy {
    case nil: []
    case .notOnWatch: [.sendToWatch]
    case .onWatch: [.removeFromWatch]
    }
  }

  private static func episodeProgressActions(
    playbackStatus: ItemPlaybackStatus?,
    isCurrentlyPlaying: Bool,
    isHidden: Bool
  ) -> [MediaItemAction] {
    MediaProgressActionPolicy.actions(
      for: playbackStatus, isHidden: isHidden, isCurrentlyPlaying: isCurrentlyPlaying
    ).map(MediaItemAction.init)
  }
}
