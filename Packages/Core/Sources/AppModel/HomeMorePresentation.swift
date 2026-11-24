import Foundation
import Persistence

/// One item row on the pushed more-screen. Title, second line, badge and bar come from
/// `HomeCardText`, the same derivation the Home card uses.
///
/// Total duration appears only in sections that show no progress, since a row that already counts
/// down ("9h 0m left") would print a second, differently-formatted time.
public struct HomeMoreItemRowPresentation: Sendable, Equatable {
  public let title: String
  /// `nil` rather than "" for an item with no author, so the row omits the line instead of
  /// reserving its height.
  public let subtitle: String?
  public let metadataText: String
  /// The countdown line ("25% · 9h 0m left" or "Finished"), for progress-bearing sections only.
  public let progressText: String?
  public let progressFraction: Double?
  public let isFinished: Bool

  /// `surfaceMixesSources` is whether the page lists podcasts from both sources. A list row has no
  /// cover corner to mark, so the answer joins the metadata line instead.
  ///
  /// `progressSeconds` is the listening position the row prints (see
  /// `PlaybackModel.displayedPositionSeconds`); it defaults to the persisted position.
  public init(
    item: HomeItem, section: HomeMoreSection, playbackRate: Double = 1.0,
    surfaceMixesSources: Bool = false, progressSeconds: Double? = nil
  ) {
    let listenedSeconds = progressSeconds ?? item.progressSeconds
    let text = HomeCardText(
      item: item, showsProgress: section.showsProgress,
      usesEbookProgress: section == .continueReading, progressSeconds: listenedSeconds)
    title = text.title
    subtitle = text.subtitle
    isFinished = item.isFinished
    progressFraction = text.progressFraction

    let badge = HomeRowPresentation.badgeLabel(for: text.badgeCategory)

    let metadata: String
    if section.showsProgress {
      metadata = badge
      if item.isFinished {
        progressText =
          section == .continueReading
          ? HomeRowPresentation.ebookProgressCaption(
            ebookProgress: item.ebookProgress, isFinished: true)
          : HomeRowPresentation.remainingCaption(
            progressSeconds: listenedSeconds, durationSeconds: item.durationSeconds,
            isFinished: true, category: item.category, playbackRate: playbackRate)
      } else if let fraction = text.progressFraction {
        let remaining = HomeRowPresentation.remainingCaption(
          progressSeconds: listenedSeconds, durationSeconds: item.durationSeconds,
          isFinished: false, category: item.category, playbackRate: playbackRate)
        let percent = "\(Int((fraction * 100).rounded()))%"
        progressText =
          section == .continueReading || item.category == .ebook
          ? percent : "\(percent) · \(remaining)"
      } else {
        progressText = nil
      }
    } else {
      // The Downloaded page already appends the local file size. A book's total listening time
      // is noise in that storage-focused list, so metadata matches podcast rows: kind · size.
      let downloadedBadge =
        section == .downloaded ? Self.downloadedBadgeLabel(for: item, fallback: badge) : badge
      let duration =
        section == .downloaded
        ? nil
        : ItemDetailDurationPresentation.durationText(
          category: item.category, durationSeconds: item.durationSeconds)
      metadata = [downloadedBadge, duration].compactMap { $0 }.joined(separator: " · ")
      progressText = nil
    }

    let sourceMark = PodcastSourceMarkPolicy.mark(
      itemID: item.serverItemId, category: item.category,
      surfaceMixesSources: surfaceMixesSources)
    metadataText = [metadata, sourceMark?.accessibilityLabel]
      .compactMap { $0 }
      .joined(separator: " · ")
  }

  /// Built from `HomeRowPresentation.badgeLabel` so a mixed item's storage row names its media as
  /// every badge does.
  ///
  /// A downloaded companion PDF is named after the media it accompanies ("Audiobook + PDF"); it
  /// never puts a book on this list by itself.
  static func downloadedBadgeLabel(for item: HomeItem, fallback: String) -> String {
    guard item.category == .audiobook else { return fallback }
    let base: String
    if item.hasReadableEbook {
      let audio = HomeRowPresentation.badgeLabel(for: .audiobook)
      let ebook = HomeRowPresentation.badgeLabel(for: .ebook)
      switch (item.audioDownloaded, item.ebookDownloaded) {
      case (true, true): base = "\(audio) + \(ebook)"
      case (true, false): base = audio
      case (false, true): base = ebook
      case (false, false): base = fallback
      }
    } else {
      base = fallback
    }
    return item.supplementDownloaded ? "\(base) + PDF" : base
  }

  public var accessibilityLabel: String {
    [title, subtitle, metadataText, progressText].compactMap { $0 }.joined(separator: ", ")
  }
}

public struct HomePodcastEpisodePresentation: Sendable, Equatable {
  public let title: String
  public let showTitle: String
  public let subtitle: String?
  public let dateText: String
  public let durationText: String
  public let listening: PodcastEpisodeListeningState
  /// The card row's one time fact once the episode is started ("37 min left", or "Played").
  /// `nil` while unplayed, when the row shows the duration instead.
  public let startedTimeText: String?
  /// The same fact as `startedTimeText`, with the rate read as words for VoiceOver.
  private let startedTimeAccessibilityText: String?

  /// `progressSeconds` is the position the row prints, resolved through
  /// `PlaybackModel.displayedPositionSeconds` so the playing episode reads live. It defaults to the
  /// persisted position. `playbackRate` is the show's speed, so the remainder is listening time.
  public init(episode: HomePodcastEpisode, progressSeconds: Double? = nil, playbackRate: Double = 1.0) {
    title = episode.title.isEmpty ? PodcastCopy.untitledEpisode : episode.title
    showTitle = episode.showTitle
    subtitle = episode.subtitle
    dateText = PodcastCopy.podcastPublishedDate(episode.publishedAt)
    durationText = PodcastCopy.duration(seconds: episode.durationSeconds)
    let position = progressSeconds ?? episode.progressSeconds
    listening = PodcastEpisodeListeningState(
      progressSeconds: position,
      durationSeconds: episode.durationSeconds, isFinished: episode.isFinished)
    startedTimeText =
      if listening.playbackStatus == .inProgress, let duration = episode.durationSeconds,
        duration.isFinite, duration > position
      {
        PodcastCopy.remaining(seconds: duration - position, playbackRate: playbackRate)
      } else {
        listening.startedProgressText
      }
    startedTimeAccessibilityText =
      if listening.playbackStatus == .inProgress, let duration = episode.durationSeconds,
        duration.isFinite, duration > position
      {
        PodcastCopy.spokenRemaining(seconds: duration - position, playbackRate: playbackRate)
      } else {
        listening.startedProgressText
      }
  }

  /// What the card row's time line says: the remainder once started, otherwise the length.
  public var timeText: String {
    startedTimeText ?? durationText
  }

  public var accessibilityLabel: String {
    [title, showTitle, subtitle, dateText, durationText, startedTimeAccessibilityText]
      .compactMap { $0 }.joined(separator: ", ")
  }
}
