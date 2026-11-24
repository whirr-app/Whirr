import Foundation
import Persistence

/// Pure presentation for the episode's sheet-presented card, deterministic from a
/// `PodcastEpisodeContext` (no view, model or I/O). Reusable facts (date/duration text, the
/// download control, the canonical action list) come from `PodcastEpisodePresentation` /
/// `PodcastShowPresentation`, so the card cannot disagree with the row or the menu.
public struct PodcastEpisodeCardPresentation: Sendable, Equatable {
  public let title: String
  /// The show's title, for the tappable `title ›` row that dismisses the card and pushes the show.
  public let showTitle: String
  /// The show's creator, for the canonical menu's `.moreFromCreator` label. `nil` when the feed
  /// never supplied one.
  public let showAuthor: String?
  /// The parent show's declared artwork, retained from the episode context so the App target can
  /// resolve the credential-aware provider source without opening another read.
  public let artworkURL: URL?
  public let artworkFeedURL: URL?
  /// The RSS episode's own declared artwork; `nil` for ABS and for episodes that declare none.
  /// `artworkURL` stays the show's.
  public let episodeArtworkURL: URL?
  /// The ABS show's server `updatedAt`, which revisions the cover the card draws.
  public let showServerUpdatedAt: Date?
  /// "Jul 27, 2026 · 39 min": the row's date/duration text, joined. `metadataLine` is what the
  /// card renders; this stays the raw join.
  public let metadataText: String
  /// `metadataText`, with "· 12 min left" appended while the episode is genuinely part-played.
  /// Remaining time lives here rather than in the play button, directly above the progress bar.
  /// Gated on `remainingProgressFraction` so the figure and the bar appear together.
  public var metadataLine: String {
    guard remainingProgressFraction != nil, let remainingAudioSeconds else { return metadataText }
    let remaining = PodcastCopy.remaining(
      seconds: remainingAudioSeconds, playbackRate: playbackRate)
    return "\(metadataText) · \(remaining)"
  }
  /// `metadataLine` as VoiceOver reads it: the same figure, with the rate in words.
  public var metadataAccessibilityLabel: String {
    guard remainingProgressFraction != nil, let remainingAudioSeconds else { return metadataText }
    let remaining = PodcastCopy.spokenRemaining(
      seconds: remainingAudioSeconds, playbackRate: playbackRate)
    return "\(metadataText), \(remaining)"
  }
  /// The progress bar's fill fraction, present only when part-played (`0 < fraction < 1`, not
  /// marked finished). Unstarted and finished episodes (including overrun progress) render no bar,
  /// matching the row's `visiblePlaybackProgressFraction`. Also gates `metadataLine`'s remainder.
  public private(set) var remainingProgressFraction: Double?
  /// "Play", or "Resume" once partway through. The remainder is `metadataLine`'s; see
  /// `PodcastCopy.play`.
  public var playButtonLabel: String {
    remainingAudioSeconds == nil ? PodcastCopy.play : PodcastCopy.resume
  }
  /// "Pause": the same button while this episode plays (`PodcastEpisodeCardPlayControl.pause`).
  public var pauseButtonLabel: String { PodcastCopy.pause }
  /// Full show notes, paragraphs preserved. The inverse of row policy (`subtitle`, then the
  /// description): the card prefers the description and falls back to `subtitle`. Publisher
  /// boilerplate is split off into `supplementaryNotes` (see `PodcastShowNotes`).
  public let notes: String?
  /// Membership plugs, sponsor reads, socials, and credits folded out of `notes`, for the card to
  /// draw behind a disclosure. `nil` when nothing folded.
  public let supplementaryNotes: String?
  public let deviceDownloadText: String
  public let isDownloadSizeKnown: Bool
  /// The raw device-transfer state, so the card view can draw the show row's glyph-per-state
  /// vocabulary (`PodcastEpisodeDeviceDownloadStatus`). `primaryDeviceAction` alone carries no
  /// icon for the states that answer no tap (`.pausedAuth`, `.deleting`, `.completed`).
  public let deviceDownloadStatus: ItemDownloadStatus
  /// What the trailing download control does when tapped, or `nil` for states that answer no tap.
  /// See `PodcastShowPresentation.primaryDeviceAction`.
  public let primaryDeviceAction: MediaItemAction?
  /// Whether the episode is marked finished. The card has no leading playback glyph like the show
  /// row's (`PodcastEpisodePlaybackStatus`), so this sources its finished badge. The raw progress
  /// state independently drives `contextActions` through the shared policy.
  public let isFinished: Bool
  /// Whether the server can provide this episode, retained so the App target can rederive the
  /// canonical menu with live saved membership rather than using a stale snapshot.
  public let isAvailableOnServer: Bool
  /// The coarse progress state retained so the App target can rederive the canonical menu with
  /// live saved membership rather than using a stale snapshot.
  public let playbackStatus: ItemPlaybackStatus?
  /// The membership-free episode menu for `.episodeDetail`, suppressing entries the card presents
  /// as its own controls (`PodcastShowPresentation.suppressedActions(on:)`). The App card view
  /// rederives it when it has a live saved-membership value.
  public let contextActions: [MediaItemAction]
  /// The rate used for listening-time copy. The card view reprojects this value when the shared
  /// playback model changes speed while the card remains presented.
  public private(set) var playbackRate: Double

  private var remainingAudioSeconds: Double?
  private let durationSeconds: Double?
  /// The stored position the card was loaded at: the `persisted` answer for
  /// `PlaybackModel.displayedPositionSeconds`.
  public let progressSeconds: Double

  /// `boilerplate` comes from the show's recent episodes (`PodcastEpisodeCardModel`); `.none`
  /// leaves only the single-episode fold.
  public init(
    context: PodcastEpisodeContext, playbackRate: Double = 1.0,
    boilerplate: ShowNotesBoilerplate = .none,
    watchCopy: PodcastEpisodeWatchCopy? = nil
  ) {
    let episode = context.episode
    let row = PodcastEpisodePresentation(episode: episode)

    title = episode.title.isEmpty ? PodcastCopy.untitledEpisode : episode.title
    showTitle = context.showTitle
    showAuthor = context.showAuthor
    artworkURL = context.artworkURL
    artworkFeedURL = context.artworkFeedURL
    episodeArtworkURL = context.episodeArtworkURL
    showServerUpdatedAt = context.showServerUpdatedAt
    metadataText = "\(row.dateText) · \(row.durationText)"
    self.playbackRate = playbackRate

    durationSeconds = episode.durationSeconds
    progressSeconds = episode.progressSeconds
    isFinished = episode.isFinished
    (remainingProgressFraction, remainingAudioSeconds) = Self.remaining(
      progressSeconds: episode.progressSeconds, durationSeconds: episode.durationSeconds,
      isFinished: episode.isFinished)

    let showNotes =
      (FeedHTML.paragraphs(episode.episodeDescription)
      ?? FeedHTML.paragraphs(episode.subtitle)).map { PodcastShowNotes($0, boilerplate: boilerplate) }
    notes = showNotes.flatMap { $0.primary.isEmpty ? nil : $0.primary }
    supplementaryNotes = showNotes?.supplementary

    isDownloadSizeKnown = episode.isDownloadSizeKnown
    deviceDownloadText = ItemDownloadCopy.text(
      for: episode.downloadStatus, isDownloadSizeKnown: episode.isDownloadSizeKnown)
    deviceDownloadStatus = episode.downloadStatus
    isAvailableOnServer = episode.isAvailableOnServer
    playbackStatus = MediaProgressActionPolicy.playbackStatus(
      progressSeconds: episode.progressSeconds, isFinished: episode.isFinished)
    primaryDeviceAction = PodcastShowPresentation.primaryDeviceAction(
      status: episode.downloadStatus, isAvailableOnServer: episode.isAvailableOnServer)
    contextActions = PodcastShowPresentation.episodeActions(
      status: episode.downloadStatus, isAvailableOnServer: episode.isAvailableOnServer,
      surface: .episodeDetail,
      playbackStatus: playbackStatus,
      watchCopy: watchCopy)
  }

  /// Reuses the loaded episode projection while allowing a live playback-rate change to redraw
  /// only the listening-time copy. Media duration and progress fraction remain unchanged facts.
  public func adjusted(forPlaybackRate playbackRate: Double) -> Self {
    var adjusted = self
    adjusted.playbackRate = playbackRate
    return adjusted
  }

  /// The same card with its progress lines (`remainingProgressFraction`, `metadataLine`) at
  /// `progressSeconds`, the position `PlaybackModel.displayedPositionSeconds` resolves for display.
  /// `breaks`, when known, are the ad skips ahead of that position: their time is left out of the
  /// remainder, as the player will leave it out of playback. The fraction stays media over media,
  /// so the bar does not jump when analysis lands. Only the view that draws those lines should
  /// ask, so the rest of the card does not follow the playhead.
  public func atPosition(_ progressSeconds: Double, skipping breaks: AdSkipBreaks? = nil) -> Self {
    var moved = self
    (moved.remainingProgressFraction, moved.remainingAudioSeconds) = Self.remaining(
      progressSeconds: progressSeconds, durationSeconds: durationSeconds, isFinished: isFinished)
    if let breaks, let durationSeconds, let remaining = moved.remainingAudioSeconds {
      let skipped = breaks.skippedSeconds(
        resumingAt: progressSeconds, duration: durationSeconds)
      moved.remainingAudioSeconds = max(0, remaining - skipped)
    }
    return moved
  }

  private static func remaining(
    progressSeconds: Double, durationSeconds: Double?, isFinished: Bool
  ) -> (fraction: Double?, audioSeconds: Double?) {
    guard isFinished == false, let durationSeconds,
      let fraction = HomeRowPresentation.progressFraction(
        progressSeconds: progressSeconds, durationSeconds: durationSeconds),
      fraction > 0, fraction < 1
    else { return (nil, nil) }
    return (
      fraction,
      ItemDetailDurationPresentation.remainingSeconds(
        durationSeconds: durationSeconds, progressSeconds: progressSeconds)
    )
  }
}
