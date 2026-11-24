import AppModel
import DesignSystem
import SwiftUI

/// View-adapter policy for `PodcastEpisodeCardView`. Reuses `PodcastShowViewPresentation`'s
/// label/hint/glyph mapping for every action and device-transfer state, so the card and the show
/// row share one source of truth rather than two divergent vocabularies.
enum PodcastEpisodeCardViewPresentation {
  nonisolated enum Motion: Equatable {
    case animated
    case reduced

    var controlAnimation: Animation? {
      switch self {
      case .animated: .snappy(duration: 0.28)
      case .reduced: nil
      }
    }

    var textTransition: ContentTransition {
      switch self {
      case .animated: .interpolate
      case .reduced: .identity
      }
    }

    var symbolTransition: ContentTransition {
      switch self {
      case .animated: .symbolEffect(.replace)
      case .reduced: .identity
      }
    }
  }

  nonisolated static func motion(reduceMotion: Bool) -> Motion {
    reduceMotion ? .reduced : .animated
  }

  /// The sheet's `itemID` is the owning show, not the episode id.
  static func washKey(for itemID: String) -> String { itemID }

  enum PlayAccentSource: Equatable {
    case wash
    case appChrome
  }

  /// The sheet is keyed by its show's id, so a resolved wash accents the primary action; neutral
  /// and unavailable washes retain the app chrome tint.
  static func playAccentSource(for wash: CoverWash) -> PlayAccentSource {
    wash.accentColor == nil ? .appChrome : .wash
  }

  /// Ink for the card's secondary copy: the date line, the notes and their labels.
  enum SecondaryInk: Equatable {
    /// `WhirrColorToken.textSecondary`: a fixed grey solved against the opaque grounds the app
    /// paints. On the system's glass it measured 1.9:1 over a bright cover (ADR 0012).
    case token
    /// The system's hierarchical `.primary`, which the system draws against the glass rather than
    /// as one fixed colour. Hierarchy then rests on size and weight alone. Not `.secondary`: that
    /// tops out near 3.4:1 on white, and the half sheet is opaque at `.large`.
    case hierarchicalPrimary

    var style: AnyShapeStyle {
      switch self {
      case .token: AnyShapeStyle(WhirrColorToken.textSecondary.color)
      case .hierarchicalPrimary: AnyShapeStyle(HierarchicalShapeStyle.primary)
      }
    }
  }

  /// Only the compact half sheet sits on the system glass; every other host is opaque.
  static func secondaryInk(onSystemGlass: Bool) -> SecondaryInk {
    onSystemGlass ? .hierarchicalPrimary : .token
  }

  /// The metadata line as VoiceOver reads it. The Watch mark is its own phrase after the metadata,
  /// as the show row's value carries it, never folded into the date or duration.
  static func metadataAccessibilityLabel(
    _ metadata: String, watchMark: PodcastEpisodeWatchMark?
  ) -> String {
    guard let watchMark else { return metadata }
    return "\(metadata). \(watchMark.accessibilityText)"
  }

  /// The chapters-sheet idiom (`ExpandedPlayerView.themedSheet`'s `[.medium]`), widened to `.large`
  /// because full show notes want more room. Medium answers "what is this episode?"; large is for
  /// reading.
  static let detents: Set<PresentationDetent> = [.medium, .large]

  /// The card's own layout constants, differing from the show row's because the card is a sheet:
  /// a grab indicator, much rounder corners, artwork several times a thumbnail's size. Values a row
  /// already gets right (hit targets, spacing) come from `WhirrSpacing`/`WhirrMetric`.
  enum Metric {
    /// Upper bound for the regular-width card surface. A cap leaves the sheet responsive to its
    /// local pane while keeping the card from becoming a full-canvas reading surface.
    static let cardMaxWidth: CGFloat = 720
    /// Shared prose measure for notes. This remains an upper bound so Dynamic Type can still wrap
    /// within the card rather than being forced into a fixed-width text column.
    static let notesReadingMeasure = AdaptiveLayoutPresentation.readingMeasure

    /// Small enough that the title gets the width to wrap at two lines rather than three. The card
    /// re-shows the artwork the user just tapped, so it identifies rather than heroes.
    static let coverSize: CGFloat = 72
    /// The card draws at 72 points but requests the 56-point key the episode rows use, as
    /// `PodcastShowView` does for its header. The cover byte cache is keyed by URL width, so a size
    /// unique to this sheet always misses, and offline that miss cannot recover.
    static let artworkDisplaySize = PodcastEpisodeCardRowMetrics.coverSize
    /// `CoverImageView`'s default `WhirrSpacing.xxSmall` is a row-thumbnail radius; at this size,
    /// against the sheet's own corners, it reads as a hard square. Scales with the tile.
    static let coverCornerRadius: CGFloat = 14
    /// Item detail's 28-point mark scaled to this smaller tile, and inset by the smaller step so
    /// it clears the 14-point corner radius without crowding the artwork's centre.
    static let finishedBadgeSize: CGFloat = 22
    static let finishedBadgeInset: CGFloat = WhirrSpacing.xxSmall

    /// Not uniform: the grab indicator already occupies the space a symmetric top inset would give
    /// the artwork, so the top edge is the roomiest of the three.
    static let topPadding: CGFloat = WhirrSpacing.large + WhirrSpacing.xxSmall
    static let horizontalPadding: CGFloat = WhirrSpacing.medium + WhirrSpacing.xxSmall
    static let bottomPadding: CGFloat = WhirrSpacing.medium

    /// One height across the whole control row so it reads as a single cluster. The trailing
    /// controls are circles of this diameter rather than bare glyphs, which disappear beside a
    /// filled capsule.
    static let controlDiameter: CGFloat = 46
    static let playButtonMinHeight: CGFloat = controlDiameter
    /// The ring draws its own track, so it sits inside the control's circle rather than filling it,
    /// matching the glyph the other nine states show at the same place.
    static let progressRingSize: CGFloat = 22
  }

  /// One canonical-menu entry, paired with the raw `AppModel` action so the view can dispatch it
  /// (`.openShow`/`.moreFromCreator` are intercepted by the view) without a string round trip.
  /// `Equatable` because `PodcastEpisodeCardActionMenu` compares section lists of these to decide
  /// whether a presented menu may be rebuilt.
  struct ActionRow: Identifiable, Equatable {
    let action: AppModel.MediaItemAction
    let display: MediaContextAction
    var id: String { display.id }
  }

  /// The trailing download control's rendered state and what a tap on it does.
  struct DownloadControl: Equatable {
    let deviceStatus: PodcastEpisodeDeviceDownloadStatus
    /// `nil` for the states that answer no tap; the glyph still renders
    /// (`deviceStatus.systemImage`), as in the show row's inert states. In `.failed` this is the
    /// explain-first control the show row draws (`PodcastDownloadFailurePresentation`).
    let action: MediaContextAction?
    /// The raw action behind `action`, so the view dispatches the episode's own status-derived
    /// action through the model. The card re-reads its episode, not the show row, because this
    /// control diverges from the row for one state. In `.failed` it is the retry the alert's Try
    /// Again dispatches, never what the tap itself performs.
    let episodeAction: AppModel.MediaItemAction?
    /// What to draw inside the card's own circular control: the bare detail-control vocabulary, not
    /// the row glyph's enclosure inside another circle.
    let systemImage: String
  }

  /// Every section the card's ellipsis/long-press menu offers, in canonical order, less what
  /// `.episodeDetail` suppresses (`PodcastShowPresentation.suppressedActions`: play capsule,
  /// bookmark, download and show link, which the card draws itself). Section boundaries come from
  /// AppModel so no entry point flattens the list and loses its separators. `isSaved` comes from
  /// the card model at render time so a save/remove can't leave a stale menu; copy uses the show
  /// row's mapping, and an entry with no data (`.moreFromCreator`, no known creator) is dropped.
  /// `queueAvailability` is the `ListeningQueueActionPolicy` answer, so menu and row agree.
  /// `offersTranscript` is whether the transcript coordinator can transcribe this episode.
  static func actionSections(
    for presentation: PodcastEpisodeCardPresentation,
    queueAvailability: ListeningQueueActionAvailability,
    isSaved: Bool? = nil,
    isCurrentlyPlaying: Bool = false,
    isHidden: Bool = false,
    serverSave: NativeEpisodeServerSaveAvailability = .hidden,
    serverRemove: NativeEpisodeServerSaveAvailability = .hidden,
    offersTranscript: Bool = false,
    watchCopy: PodcastEpisodeWatchCopy? = nil
  ) -> [[ActionRow]] {
    PodcastShowPresentation.episodeActionSections(
      status: presentation.deviceDownloadStatus,
      isAvailableOnServer: presentation.isAvailableOnServer,
      surface: .episodeDetail,
      isSaved: isSaved,
      playbackStatus: presentation.playbackStatus,
      isCurrentlyPlaying: isCurrentlyPlaying,
      isHidden: isHidden,
      serverSave: serverSave,
      serverRemove: serverRemove,
      offersTranscript: offersTranscript,
      watchCopy: watchCopy
    ).compactMap { section in
      let rows: [ActionRow] = ListeningQueueActionPolicy.apply(
        queueAvailability, to: section.actions
      ).compactMap { action -> ActionRow? in
        guard
          let display = PodcastShowViewPresentation.contextAction(
            action,
            creator: presentation.showAuthor,
            availability: action == .saveToServer
              ? serverSave
              : action == .removeFromServer ? serverRemove : nil)
        else { return nil }
        return ActionRow(action: action, display: display)
      }
      return rows.isEmpty ? nil : rows
    }
  }

  /// The rows the menu draws, with `MediaItemMenuLayout`'s submenus folded in. `actionSections`
  /// stays flat, so the menu dispatches a submenu's choice by the same row id.
  static func menuRows(_ sections: [[ActionRow]]) -> [[MediaContextAction]] {
    sections.map { section in
      ItemContextMenuPresentation.foldedRows(section.map { ($0.action, $0.display) })
    }
  }

  /// Compatibility projection for policy consumers that need canonical order but draw no menu.
  /// It derives from `actionSections`, so it cannot become a competing ordering policy.
  static func actionRows(
    for presentation: PodcastEpisodeCardPresentation,
    queueAvailability: ListeningQueueActionAvailability,
    isSaved: Bool? = nil,
    serverSave: NativeEpisodeServerSaveAvailability = .hidden,
    serverRemove: NativeEpisodeServerSaveAvailability = .hidden
  ) -> [ActionRow] {
    actionSections(
      for: presentation,
      queueAvailability: queueAvailability,
      isSaved: isSaved,
      serverSave: serverSave,
      serverRemove: serverRemove
    ).flatMap { $0 }
  }

  /// Whether tapping the trailing control in this device state should ask before acting. Delegated
  /// to `ItemDetailDownloadBubblePresentation` ("which states destroy something the user waited
  /// for") so two surfaces deleting the same kind of file can't disagree. Only the confirming state
  /// diverges; every other state keeps the immediate tap, not the bubble's menu behaviour.
  static func requiresDeleteConfirmation(for kind: DownloadControlKind) -> Bool {
    ItemDetailDownloadBubblePresentation.tapBehavior(for: kind) == .confirm
  }

  /// What a tap on the card's trailing control does: `PodcastShowPresentation`'s row mapping in
  /// nine of ten states. The row withholds a tap on a completed download, whose only action is
  /// destructive, guarding a control the thumb passes while scrolling; on the card the
  /// confirmation dialog is that second gesture (`requiresDeleteConfirmation`), so the tap is
  /// offered. Still sourced from the canonical menu: one withholding `.removeDownload` gets no
  /// tap. `contextActions` must be the unsuppressed set (`deviceActions(for:)`), as the card's
  /// `.episodeDetail` menu drops every download entry and would leave the completed state empty.
  static func primaryDeviceAction(
    kind: DownloadControlKind,
    rowAction: AppModel.MediaItemAction?,
    contextActions: [AppModel.MediaItemAction]
  ) -> AppModel.MediaItemAction? {
    guard requiresDeleteConfirmation(for: kind) else { return rowAction }
    return contextActions.contains(.removeDownload) ? .removeDownload : rowAction
  }

  /// The glyph the card's trailing control draws. The card supplies circular chrome, so the row's
  /// enclosed glyphs would draw two rings. The audiobook detail control shares the constraint
  /// (Liquid Glass encloses its glyph), and reusing its mapping keeps semantics honest: a completed
  /// copy draws trash because tapping removes it, while the unchromed row keeps its status mark.
  static func systemImage(for kind: DownloadControlKind) -> String {
    guard let systemImage = ItemDetailDownloadBubblePresentation.systemImage(for: kind) else {
      assertionFailure("Every download control kind must provide a sheet glyph.")
      return "arrow.down"
    }
    return systemImage
  }

  /// The canonical device actions for this episode's transfer state, read from a surface that
  /// suppresses no device entry (`.card` hides only the server-save pair). `contextActions` can't
  /// answer: the `.episodeDetail` menu suppresses every download entry, so "may I offer remove?"
  /// always says no and a completed download would draw a trash glyph with no button.
  static func deviceActions(
    for presentation: PodcastEpisodeCardPresentation
  ) -> [AppModel.MediaItemAction] {
    PodcastShowPresentation.episodeActions(
      status: presentation.deviceDownloadStatus,
      isAvailableOnServer: presentation.isAvailableOnServer,
      surface: .card)
  }

  /// The trailing download control, drawn from the raw device-transfer status so every one of the
  /// row's ten states gets its own glyph, not just the four that also answer a tap.
  static func downloadControl(
    for presentation: PodcastEpisodeCardPresentation
  ) -> DownloadControl {
    let deviceStatus = PodcastShowViewPresentation.deviceStatus(
      for: presentation.deviceDownloadStatus,
      isDownloadSizeKnown: presentation.isDownloadSizeKnown)
    let episodeAction = primaryDeviceAction(
      kind: deviceStatus.kind,
      rowAction: presentation.primaryDeviceAction,
      contextActions: deviceActions(for: presentation))
    return DownloadControl(
      deviceStatus: deviceStatus,
      action: PodcastDownloadFailurePresentation.control(for: presentation.deviceDownloadStatus)
        ?? episodeAction.flatMap {
          PodcastShowViewPresentation.contextAction($0, creator: presentation.showAuthor)
        },
      episodeAction: episodeAction,
      systemImage: systemImage(for: deviceStatus.kind))
  }
}
