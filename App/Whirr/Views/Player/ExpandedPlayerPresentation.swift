import ABSApi
import AppModel
import CoreGraphics
import DesignSystem
import Persistence
import PlayerCore
import SwiftUI
import SyncEngine

/// The expanded player's geometry and rendering contract, apart from SwiftUI modifiers so it is
/// testable. Presentation, gesture arbitration and dismissal belong to the UIKit transition
/// (`PlayerTransitionController`, `PlayerPresentationController`, `PlayerDismissInteractor`,
/// driven by `PlayerDismissalPolicy`). The static lets are a design record; a test asserting a
/// constant equals its own literal is a change detector, so do not add one.
enum ExpandedPlayerHostPresentation {
  nonisolated enum Extent: Equatable {
    case fullBleed
    case safeArea
  }

  nonisolated enum ScreenCoverage: Equatable {
    case insetBelowStatusBar
    case coversScreenIncludingBars
  }

  nonisolated enum BackgroundOwner: Equatable {
    case pageContent
    case presentationBackground
  }

  /// What fills the cover behind the page. The page is opaque, so this is only seen once a dismiss
  /// drag has pulled the page off the top edge. A cover's own backdrop is black there, which reads
  /// as the app having gone away. A clear presentation background keeps the presenter (the shell
  /// the user came from) visible under the whole gesture, as the system media players do.
  nonisolated enum Backdrop: Equatable {
    case opaque
    case transparentShowingPresenter
  }

  /// How far the player's dark treatment reaches.
  nonisolated enum ColorSchemeScope: Equatable {
    /// A presentation preference that would affect the whole presentation. Unused by the player,
    /// because UIKit owns the status bar for the whole presentation.
    case wholePresentation
    /// `environment(\.colorScheme, ...)`, which reaches only the player's own content and the
    /// sheets it raises.
    case pageContent
  }

  static let backgroundExtent: Extent = .fullBleed
  static let contentExtent: Extent = .safeArea
  static let screenCoverage: ScreenCoverage = .coversScreenIncludingBars
  static let backgroundOwner: BackgroundOwner = .pageContent
  static let backdrop: Backdrop = .transparentShowingPresenter
  /// The player's dark treatment reaches only its own content and the sheets it raises. The
  /// hosting controller's `preferredStatusBarStyle` owns the status bar for the whole presentation
  /// rather than a SwiftUI presentation preference.
  static let colorSchemeScope: ColorSchemeScope = .pageContent

  /// Fallback in-motion corner radius, roughly a current iPhone's. Normally measured from the
  /// window by `PlayerDisplayCornerRadius`; this applies only with no window or an unusable
  /// measurement. Transition only: at rest the bezel clips, and a radius off the device's would
  /// show wedges of the shell through the corners.
  static let inMotionCornerRadius: CGFloat = 48

  /// How far the shell behind the player is dimmed while covered. Never seen at rest; on pull-down
  /// the revealed shell starts dimmed and returns to full brightness as the page clears it. Kept
  /// subtle: a system-sheet strength dim would make the shell look disabled mid-dismiss.
  static let presenterDimOpacity: CGFloat = 0.25

  /// How long a non-interactive slide collapse takes (`NavigationModel.PlayerCollapseStyle.slide`).
  /// Close to the system media players' own, with an eased curve in `PlayerTransitionAnimator`; a
  /// shorter critically damped spring has the page off screen before the eye registers it.
  static let slideDuration: TimeInterval = 0.48

  /// How long a dissolve collapse takes (`NavigationModel.PlayerCollapseStyle.dissolve`). Shorter
  /// than the slide: nothing travels, so the same duration would read as a hang.
  static let dissolveDuration: TimeInterval = 0.30

  /// Where a dissolving page's scale ends. Small enough that the page never reads as a card
  /// floating over the shell, large enough that the fade has a direction (the page settles into
  /// the one beneath it). Reduce Motion drops the scale.
  static let dissolveEndScale: CGFloat = 0.96

  // MARK: Collapsing into the mini player (starting values, tuned on device)

  /// How long a collapse into the mini player takes when nothing is carrying it: Close, and every
  /// other non-interactive collapse. A critically damped spring, since the panel lands on a target
  /// rather than leaving through an edge. Long because such a spring covers nine tenths of its
  /// travel in the first two fifths of its time, so the length is spent on the watched settle.
  static let morphDuration: TimeInterval = 0.55
  /// How long the morph takes after a drag is released past the threshold. Shorter than a button
  /// close and slightly under-damped, so the panel reads as thrown into the bar.
  static let morphReleaseDuration: TimeInterval = 0.50
  static let morphReleaseDampingRatio: CGFloat = 0.85
  /// The release velocity is normalised to the panel's vertical travel and capped here, so a hard
  /// flick from near the bottom cannot launch the spring through the bar.
  static let morphVelocityCap: CGFloat = 6
  /// The flying cover's position is sprung more loosely than the panel, so it dips a few percent
  /// of its travel past its place in the bar and drifts back. Position only: a size sprung this
  /// loosely would shrink below the bar's cover and grow again.
  static let morphCoverDampingRatio: CGFloat = 0.7
  /// The panel's height starts this share of the morph after its top edge, so the panel reaches
  /// the bar still tall and settles onto it. That gives the cover's dip room to show; without it
  /// the cover would leave the bottom of the glass.
  static let morphHeightLagFraction: Double = 0.18
  /// The share of the morph over which the page fades to the panel's veil.
  static let morphPageFadeFraction: Double = 0.45
  /// The collapse's veil: a flat tint that lets what is behind it read through, near the bar's
  /// glass in weight so fading it out over that glass shows no step.
  static let morphCloseVeilColor = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(white: 0.5, alpha: 0.28) : UIColor(white: 0.97, alpha: 0.6)
  }
  /// The closing share of the morph over which the veil fades out over the bar's own glass.
  static let morphBarRevealFraction: Double = 0.30
  /// The bar's label rides the panel's top edge, fading in over `morphBarLabelFadeFraction` of the
  /// morph after `morphBarLabelFadeDelayFraction` has passed: late enough to clear the status bar,
  /// early enough that the panel is never blank glass.
  static let morphBarLabelFadeDelayFraction: Double = 0.10
  static let morphBarLabelFadeFraction: Double = 0.25
  /// How far from the end the carried label gives way to the bar's own content, in one step. Late,
  /// because the two match only once the spring has all but come to rest.
  static let morphBarLabelHandOffFraction: Double = 0.08
  /// The bar's anchor reports its content frame, which sits slightly outside the system's glass
  /// capsule. The panel lands this far inside it.
  static let morphBarInset: CGFloat = 1
  /// The page's cover and the bar's cover corner radii, and the bar cover's rim, which the flying
  /// cover travels between.
  static let morphPageCoverCornerRadius: CGFloat = 18
  static let morphBarCoverCornerRadius: CGFloat = 8
  static let morphBarCoverRimWidth: CGFloat = 0.5
  static let morphBarCoverRimOpacity: CGFloat = 0.14

  // MARK: Opening out of the mini player (starting values, tuned on device)

  /// How long the page takes to grow out of the bar, critically damped. The panel travels the
  /// bar's height and widens at once, so it needs longer than a slide.
  static let morphOpenDuration: TimeInterval = 0.50
  /// The page fades in over `morphOpenPageFadeDurationFraction` of the open, after
  /// `morphOpenPageFadeDelayFraction` has passed. The page's canvas is its own background, so this
  /// one fade is the cross-fade from glass to the page's colour; a later start lets the glass read
  /// as the thing growing.
  static let morphOpenPageFadeDelayFraction: Double = 0.2
  static let morphOpenPageFadeDurationFraction: Double = 0.5
  /// The dismiss handle is held back until this share of the open has passed, then fades in on
  /// its own short curve, so it never shows through the pill as a stray line.
  static let morphOpenHandleDelayFraction: Double = 0.35
  static let morphOpenHandleFadeDuration: TimeInterval = 0.25
  /// The cross-fade from the bar's thumbnail to the page's cover when it is prepared mid-flight:
  /// short enough to finish while the cover is still small, long enough not to read as a cut.
  static let morphOpenCoverSwapDuration: TimeInterval = 0.12
  /// How long the page cover's shadow takes to fade in once an open's cover has landed. The cover
  /// itself returns at once (the flying copy is the same picture in the same place); only the
  /// shadow is new.
  static let morphOpenCoverShadowFadeDuration: TimeInterval = 0.25
}

/// Pure presentation logic behind `ExpandedPlayerView`: what to render and whether a control acts,
/// depending on whether retained-projection or live-session data wins. Testable without a view.
///
/// The retained projection is `PlaybackModel.displayedItem`: the last-played item's title/author
/// from the account's bookmark row (saved position `displayedItemPositionSeconds`, printed
/// position `displayedPositionSeconds`), available before this device opens a live session or
/// after one stops. Live data comes from the item's own prepared session: the item-detail fetch,
/// `PlaybackModel.currentTime`/`activeItemID`, `PlayerState.item?.chapters`. A not-yet-active
/// retained item has the first kind only.
enum ExpandedPlayerPresentation {

  typealias MetadataProminence = WhirrMetadataProminence

  /// The cover doubles as a quiet playback-state indicator: full-size and lifted while playback
  /// is intended, slightly recessed while paused. Scale and depth change together so they read as
  /// one transition.
  nonisolated struct ArtworkEmphasis: Equatable {
    let scale: CGFloat
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    let shadowOffsetY: CGFloat
  }

  nonisolated static func artworkEmphasis(isPlaybackIntended: Bool) -> ArtworkEmphasis {
    if isPlaybackIntended {
      return ArtworkEmphasis(
        scale: 1, shadowOpacity: 0.24, shadowRadius: 28, shadowOffsetY: 18)
    }
    return ArtworkEmphasis(
      scale: 0.92, shadowOpacity: 0.12, shadowRadius: 12, shadowOffsetY: 7)
  }

  nonisolated struct RemotePlaybackPresentation: Equatable {
    let subtitle: String
    let banner: ConnectivityStatusDescription

    var systemImage: String {
      banner.systemImage
    }
  }

  nonisolated enum StatusBanner: Equatable {
    case buffering
    case offline(RemotePlaybackPresentation)
    case recoverableError(message: String)
    case unrecoverableError(message: String)
  }

  nonisolated struct MiniPlayerStatus: Equatable {
    let subtitle: String
    let systemImage: String?
  }

  /// One presentation answer for both player surfaces. `PlaybackAvailability` owns the rule;
  /// this supplies the copy.
  static func remotePlaybackPresentation(
    phase: PlaybackModel.Phase,
    isStreamingSource: Bool,
    reachability: ServerReachability,
    itemID: String? = nil
  ) -> RemotePlaybackPresentation? {
    guard
      let reason = PlaybackAvailability.unavailableReason(
        phase: phase, isStreamingSource: isStreamingSource, reachability: reachability,
        itemID: itemID)
    else { return nil }

    let banner = ConnectivityStatusCopy.status(for: reason)
    return RemotePlaybackPresentation(
      subtitle: PlaybackUnavailableCopy.subtitle(for: reason), banner: banner)
  }

  /// The mini-player's subtitle shows the author unless a remote stream is unavailable, when
  /// status outranks it because the transport is the useful fact. A `chapterTitle` (supplied only
  /// by the regular-width bar, which has room for it) leads the author in the healthy case and
  /// yields to status the same way.
  static func miniPlayerStatus(
    author: String?,
    phase: PlaybackModel.Phase,
    isStreamingSource: Bool,
    reachability: ServerReachability,
    itemID: String? = nil,
    startFailureMessage: String? = nil,
    chapterTitle: String? = nil
  ) -> MiniPlayerStatus {
    if let remotePlayback = remotePlaybackPresentation(
      phase: phase, isStreamingSource: isStreamingSource, reachability: reachability,
      itemID: itemID)
    {
      return MiniPlayerStatus(
        subtitle: remotePlayback.subtitle, systemImage: remotePlayback.systemImage)
    }
    // A failed start stops audio without any visible transport change, and the mini player is
    // what the listener looks at first. The author here would make a title that is not playing
    // look like one that is.
    if phase == .recoverableError {
      return MiniPlayerStatus(
        subtitle: startFailureMessage ?? phase.copyText,
        systemImage: "exclamationmark.triangle")
    }
    if let chapterTitle = chapterTitle.map(ChapterTitleFormatting.compact) {
      let subtitle = author.map { "\(chapterTitle) · \($0)" } ?? chapterTitle
      return MiniPlayerStatus(subtitle: subtitle, systemImage: nil)
    }
    return MiniPlayerStatus(subtitle: author ?? phase.copyText, systemImage: nil)
  }

  /// The offline result is checked before the buffering debounce. A proven unreachable server is
  /// worth naming at once, while ordinary buffering keeps its grace period so transport controls
  /// do not move during normal playback.
  static func statusBanner(
    phase: PlaybackModel.Phase,
    isStreamingSource: Bool,
    reachability: ServerReachability,
    isBufferingDebounced: Bool,
    itemID: String? = nil,
    startFailureMessage: String? = nil
  ) -> StatusBanner? {
    if let remotePlayback = remotePlaybackPresentation(
      phase: phase, isStreamingSource: isStreamingSource, reachability: reachability,
      itemID: itemID)
    {
      return .offline(remotePlayback)
    }

    switch phase {
    case .buffering where isBufferingDebounced:
      return .buffering
    case .stalled:
      // ABS stalls resolve through `remotePlaybackPresentation` above with server-specific copy.
      // A device-owned feed has no ABS reachability explanation, but the retry action is still
      // valid and must stay visible after the terminal stall has torn down its dead session.
      guard isStreamingSource, let itemID,
        PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil
      else { return nil }
      return .recoverableError(message: PlaybackCopy.nativeFeedStalled)
    case .recoverableError:
      return .recoverableError(message: startFailureMessage ?? phase.copyText)
    case .unrecoverableError:
      return .unrecoverableError(message: phase.copyText)
    default:
      return nil
    }
  }

  /// The dimmer credit rungs are too faint on the darkest extracted palettes, especially for the
  /// byline below a two-line title. The shared token, so the item-detail hero (same author) can't
  /// disagree about credit brightness.
  static let authorProminence: MetadataProminence = .playerByline

  /// The provider source and revision the page's cover is keyed by.
  nonisolated struct ArtworkIdentity: Equatable {
    let source: ArtworkSource?
    let revision: ArtworkRevision
  }

  /// The loaded item's cover identity when it exists; until then an identity-matched seed's, so
  /// the page keys its cover as the mini player does from the first frame, not `unversioned`.
  nonisolated static func artworkIdentity(
    itemID: String, episodeID: String?, live: ArtworkIdentity?,
    metadataSeed: PlayerMetadataSeed?
  ) -> ArtworkIdentity {
    if let live { return live }
    guard let metadataSeed, metadataSeed.identity.itemID == itemID,
      metadataSeed.identity.episodeID == episodeID
    else { return ArtworkIdentity(source: nil, revision: .unversioned) }
    return ArtworkIdentity(
      source: metadataSeed.artworkSource, revision: metadataSeed.artworkRevision ?? .unversioned)
  }

  nonisolated struct DisplayedMetadata: Equatable {
    let title: String
    let author: String?
  }

  /// Title and author are one spoken element, identity before position. They are separate SwiftUI
  /// elements because the overflow control sits in the author's row (a combined accessibility
  /// element spanning both would swallow the control), so the label is composed here and the
  /// author's own `Text` is hidden.
  static func metadataAccessibilityLabel(title: String, author: String?) -> String {
    guard let author, author.isEmpty == false else { return title }
    return "\(title). \(author)"
  }

  /// Title/author to render. `liveTitle` (the item-detail fetch's result, once loaded) always
  /// wins, since it reflects the library's current data rather than a snapshot from whenever the
  /// bookmark was last written. Until then, the retained projection or an identity-matched queue
  /// seed renders instead of a placeholder. The seed is display-only: it cannot make a different
  /// identity look like this screen, and a live detail result supersedes it.
  static func metadata(
    itemID: String, episodeID: String? = nil, displayedItem: PlaybackBookmark?,
    liveTitle: String?, liveAuthor: String?, metadataSeed: PlayerMetadataSeed? = nil
  ) -> DisplayedMetadata {
    let matchingSeed = metadataSeed.flatMap { seed -> PlayerMetadataSeed? in
      guard seed.identity.itemID == itemID, seed.identity.episodeID == episodeID else { return nil }
      return seed
    }

    if let episodeID {
      if let displayedItem,
        displayedItem.serverItemId == itemID,
        displayedItem.episodeID == episodeID
      {
        return DisplayedMetadata(
          title: displayedItem.episodeTitle ?? displayedItem.title,
          author: displayedItem.showTitle ?? liveTitle ?? displayedItem.author)
      }
      if let matchingSeed {
        return DisplayedMetadata(title: matchingSeed.title, author: matchingSeed.author)
      }
      return DisplayedMetadata(title: "Loading…", author: nil)
    }
    if let liveTitle {
      return DisplayedMetadata(title: liveTitle, author: liveAuthor)
    }
    if let displayedItem, displayedItem.serverItemId == itemID, displayedItem.episodeID == nil {
      return DisplayedMetadata(title: displayedItem.title, author: displayedItem.author)
    }
    if let matchingSeed {
      return DisplayedMetadata(title: matchingSeed.title, author: matchingSeed.author)
    }
    return DisplayedMetadata(title: "Loading…", author: nil)
  }

  /// Whether transport (play/pause/skip) and the scrubber should act at all. True for a live
  /// session and for a retained-but-not-yet-active item, since `PlaybackModel.play(itemID:)`,
  /// `skip(itemID:by:)` and `startOrSeek(itemID:toGlobalOffset:)` prepare a session on demand.
  static func isTransportEnabled(
    itemID: String, episodeID: String? = nil, activeItemID: String?,
    activeEpisodeID: String? = nil, loadedItemID: String?, loadedEpisodeID: String? = nil,
    displayedItem: PlaybackBookmark?
  ) -> Bool {
    if activeItemID == itemID, activeEpisodeID == episodeID {
      return loadedItemID == itemID && loadedEpisodeID == episodeID
    }
    return activeItemID == nil && displayedItem?.serverItemId == itemID
      && displayedItem?.episodeID == episodeID
  }

  /// Returns PlayerCore's item only when both identity sources agree it belongs to this screen.
  /// This keeps a previous item's duration and chapters out of a newly requested item's timeline
  /// while preparation is suspended.
  static func livePlayerItem(
    itemID: String, episodeID: String? = nil, loadedItemID: String?,
    loadedEpisodeID: String? = nil, playerItem: PlayerItem?
  ) -> PlayerItem? {
    guard
      loadedItemID == itemID,
      loadedEpisodeID == episodeID,
      playerItem?.id == itemID,
      playerItem?.episodeID == episodeID
    else { return nil }
    return playerItem
  }

  /// Resolves chapters for the item shown by the player. A matching live item is authoritative,
  /// including an empty map; until then the retained item-detail map is the fallback. The identity
  /// gate keeps a previous item's chapters out of this player's row while a new item prepares.
  static func resolvedChapterMap(
    itemID: String, episodeID: String? = nil, loadedItemID: String?,
    loadedEpisodeID: String? = nil, playerItem: PlayerItem?, fallbackChapterMap: PlaybackChapterMap?
  ) -> PlaybackChapterMap? {
    livePlayerItem(
      itemID: itemID, episodeID: episodeID, loadedItemID: loadedItemID,
      loadedEpisodeID: loadedEpisodeID, playerItem: playerItem
    )?.chapters ?? fallbackChapterMap
  }

  /// Converts the item-detail chapter projection into the player-facing map. The projection has
  /// no server chapter id, so its position in the response serves as the id; a chapter selected
  /// on cold load goes through `PlaybackModel.startOrSeek`, not a PlayerCore chapter intent.
  static func playbackChapterMap(from extras: ItemDetailExtras?) -> PlaybackChapterMap? {
    guard let extras else { return nil }
    return PlaybackChapterMap(
      chapters: extras.chapters.enumerated().map { index, chapter in
        PlayerCore.PlaybackChapter(
          id: "metadata-\(index)", title: chapter.title, start: chapter.start, end: chapter.end)
      })
  }

  /// The best whole-item duration before a live `PlayerItem` exists. Podcast episode screens must
  /// not use the parent show's item-detail duration, so only an item-level one is eligible there;
  /// the retained bookmark is the fallback for both media kinds.
  static func timelineDurationSeconds(
    itemID: String, episodeID: String? = nil, displayedItem: PlaybackBookmark?,
    itemDetailDurationSeconds: Double?
  ) -> Double? {
    if episodeID == nil, let itemDetailDurationSeconds, itemDetailDurationSeconds > 0 {
      return itemDetailDurationSeconds
    }
    guard
      let displayedItem,
      displayedItem.serverItemId == itemID,
      displayedItem.episodeID == episodeID
    else { return nil }
    return displayedItem.durationSeconds
  }

  /// The position the timeline draws. A finished retained item reads as played to its end: an
  /// episode marked finished keeps its saved position (`RSSEpisodeProgressBackend.markFinished`),
  /// so drawing that position would show a finished episode part-way through. A loaded item always
  /// shows its live playhead.
  static func timelinePositionSeconds(
    itemID: String, episodeID: String?, savedPosition: Double, displayedItem: PlaybackBookmark?,
    isLoaded: Bool, totalDuration: Double?
  ) -> Double {
    guard isLoaded == false,
      let displayedItem, displayedItem.isFinished,
      displayedItem.serverItemId == itemID, displayedItem.episodeID == episodeID,
      let totalDuration, totalDuration > 0
    else { return savedPosition }
    return totalDuration
  }

  /// Whether chapter-only affordances (the Chapters quick action, the scrubber's chapter-scoped
  /// span) should be enabled. Unlike transport, these cannot prepare a session on demand. They
  /// read `PlayerState.item?.chapters`, which is only populated once a live session exists.
  /// `chapterMap` must already be `nil` unless the live session's item matches the one displayed
  /// (the caller's job). A chapterless book's empty map is treated the same as no map.
  static func isChapterAffordanceEnabled(chapterMap: PlaybackChapterMap?) -> Bool {
    guard let chapterMap else { return false }
    return chapterMap.chapters.isEmpty == false
  }

  /// Whether the loaded item exposes chapter navigation, resolved from PlayerCore's quiet item
  /// projection rather than `PlayerState.item`. The projection excludes the playhead, so the
  /// chapter stepper can judge availability without observing position ticks.
  static func hasLiveChapters(
    itemID: String, episodeID: String? = nil, loadedItemID: String?,
    loadedEpisodeID: String? = nil, quickActionsItem: PlayerQuickActionsItem?
  ) -> Bool {
    liveQuickActionsItem(
      itemID: itemID, episodeID: episodeID, loadedItemID: loadedItemID,
      loadedEpisodeID: loadedEpisodeID, quickActionsItem: quickActionsItem
    )?.hasChapters == true
  }

  /// Returns PlayerCore's low-frequency item projection only when both identity sources agree it
  /// belongs to this screen. Like `livePlayerItem` but without the position, so it does not
  /// invalidate readers on every engine tick.
  static func liveQuickActionsItem(
    itemID: String, episodeID: String? = nil, loadedItemID: String?,
    loadedEpisodeID: String? = nil, quickActionsItem: PlayerQuickActionsItem?
  ) -> PlayerQuickActionsItem? {
    guard
      loadedItemID == itemID,
      loadedEpisodeID == episodeID,
      quickActionsItem?.id == itemID,
      quickActionsItem?.episodeID == episodeID
    else { return nil }
    return quickActionsItem
  }

  /// What the chapter row beneath title/author renders. Unlike `isChapterAffordanceEnabled`, it
  /// must tell "not resolved yet" from "confirmed no chapters", which `chapterMap` carries: `nil`
  /// is unresolved, an empty map is none, a non-empty map shows the current chapter.
  nonisolated enum ChapterRowState: Equatable {
    /// A podcast episode never draws this control (an ABS episode carries no chapter map).
    /// Nothing stands in for the row's height: the page absorbs the difference in the cover above
    /// the band, so an episode and a book put the controls in the same place.
    case hidden
    /// Chapter metadata has not resolved yet: the one-line slot is reserved (disabled, generic
    /// label) so title/scrubber placement does not jump once it arrives.
    case reserved
    /// An empty chapter map: a confirmed none, so the control is omitted rather than left
    /// permanently disabled. Height is absorbed as for `.hidden`.
    case chapterless
    /// A live, non-empty chapter map: enabled, showing the current chapter's title, "Chapter N"
    /// when it has none, or a generic label when the playhead sits in a gap no chapter covers.
    /// `label` is the compact display form (`ChapterTitleFormatting`); `spokenLabel` keeps the
    /// title as published for VoiceOver.
    case current(label: String, spokenLabel: String)
  }

  /// Which states draw a chapter control. A podcast episode has no chapters and a chapterless book
  /// is a confirmed none, so neither gets one or holds the row's height open. The cover above the
  /// band takes the difference (`ExpandedPlayerView.coverSize`), keeping the scrubber and
  /// transport still.
  nonisolated static func chapterRowDrawsControl(for state: ChapterRowState) -> Bool {
    switch state {
    case .hidden, .chapterless: false
    case .reserved, .current: true
    }
  }

  /// The chapter row's accessibility hint, shared rather than repeated at each call site.
  static let chapterRowAccessibilityHint = "Shows all chapters."

  /// The chapter jumps belong to the chapter row, not the transport controls. Symbols and spoken
  /// copy stay together so the two directions cannot drift apart.
  nonisolated enum ChapterNavigationDirection: Equatable {
    case previous
    case next

    var systemImage: String {
      switch self {
      case .previous: "backward.end.fill"
      case .next: "forward.end.fill"
      }
    }

    var accessibilityLabel: String {
      switch self {
      case .previous: "Previous chapter"
      case .next: "Next chapter"
      }
    }

    var accessibilityHint: String {
      switch self {
      case .previous: "Restarts this chapter, or goes to the previous one."
      case .next: "Goes to the start of the next chapter."
      }
    }
  }

  /// Resolves `ChapterRowState`. `currentChapter` should be `chapterMap?.currentChapter(at:)` at
  /// the displayed playhead, passed in so the caller's playhead resolution (live vs. retained
  /// projection) stays the single source of truth.
  static func chapterRowState(
    episodeID: String?, chapterMap: PlaybackChapterMap?, currentChapter: PlayerCore.PlaybackChapter?
  ) -> ChapterRowState {
    guard episodeID == nil else { return .hidden }
    guard let chapterMap else { return .reserved }
    guard chapterMap.chapters.isEmpty == false else { return .chapterless }
    guard let currentChapter else { return .current(label: "Chapters", spokenLabel: "Chapters") }
    let index = chapterMap.chapters.firstIndex(of: currentChapter) ?? 0
    let title = currentChapter.title ?? "Chapter \(index + 1)"
    return .current(label: ChapterTitleFormatting.compact(title), spokenLabel: title)
  }

  /// The duration "Mark as Finished" records as the completed position. For an episode the
  /// item-detail fetch describes the show, which would stamp a whole podcast's length on one
  /// episode, so prefer the live timeline (`livePlayerItem` confirms it is this episode's), then a
  /// bookmark for the same `(item, episode)` pair; a sibling's gives `nil`. For an item: the
  /// detail fetch, then the retained projection if it names the same item.
  static func finishDurationSeconds(
    itemID: String, episodeID: String?, displayedItem: PlaybackBookmark?,
    itemDetailDurationSeconds: Double?, liveTotalDuration: Double?
  ) -> Double? {
    guard let episodeID else {
      if let itemDetailDurationSeconds { return itemDetailDurationSeconds }
      guard let displayedItem, displayedItem.serverItemId == itemID, displayedItem.episodeID == nil
      else { return nil }
      return displayedItem.durationSeconds
    }
    if let liveTotalDuration, liveTotalDuration > 0 { return liveTotalDuration }
    guard
      let displayedItem,
      displayedItem.serverItemId == itemID,
      displayedItem.episodeID == episodeID
    else { return nil }
    return displayedItem.durationSeconds
  }

  /// The progress state for the overflow menu, only when the retained bookmark belongs to the
  /// exact item or episode displayed by this player. A sibling episode must never lend its state.
  static func playbackStatus(
    itemID: String, episodeID: String?, displayedItem: PlaybackBookmark?,
    retainedPositionSeconds: Double
  ) -> ItemPlaybackStatus? {
    guard
      let displayedItem,
      displayedItem.serverItemId == itemID,
      displayedItem.episodeID == episodeID
    else { return nil }
    return MediaProgressActionPolicy.playbackStatus(
      progressSeconds: retainedPositionSeconds,
      isFinished: displayedItem.isFinished)
  }
}
