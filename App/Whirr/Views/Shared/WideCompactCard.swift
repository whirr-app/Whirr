import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// The wide compact card: the full-width, artwork-led row card of Downloads, Saved for Later,
/// Home's More lists and the Podcasts episode list. Home's shelves use the tall `HomeCardView`.
///
/// One type, so row, list-row chrome and editorial wash are not assembled per screen. An `rss:`
/// subject is only coloured when its request carries the feed's artwork source, so the subject
/// carries it and the card requests its own wash on appear.
///
/// Two flavours: item and podcast episode. The item flavour hands its row back through
/// `container` (inside a `Button`, or a `DisclosureGroup` label so the swipe stays on the label).
/// The chrome goes outside it so a swipe container cannot mask the fill.
struct WideCompactCard<Content: View>: View {
  /// The artwork square of the item flavour, shared with the cover request so one decoded
  /// variant serves every list.
  static var itemCoverSize: CGFloat { 56 }

  private enum Chrome {
    case item
    case episode
  }

  private let subject: EditorialWashSubject
  private let provider: HomeWashProvider
  private let chrome: Chrome
  private let displaySize: CGFloat
  private let content: (CoverWash) -> Content

  @Environment(\.displayScale) private var displayScale

  private init(
    subject: EditorialWashSubject,
    provider: HomeWashProvider,
    chrome: Chrome,
    displaySize: CGFloat,
    content: @escaping (CoverWash) -> Content
  ) {
    self.subject = subject
    self.provider = provider
    self.chrome = chrome
    self.displaySize = displaySize
    self.content = content
  }

  var body: some View {
    let wash = provider.wash(for: subject)
    chromed(content(wash), wash: wash)
      .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
      .onAppear {
        provider.request(
          [subject], intent: .visible, displaySize: displaySize, displayScale: displayScale,
          artworkRole: .libraryThumbnail)
      }
  }

  @ViewBuilder
  private func chromed(_ view: Content, wash: CoverWash) -> some View {
    switch chrome {
    case .item:
      view
        .editorialCardListRow(wash, verticalInset: WhirrSpacing.small)
        .listRowSeparator(.hidden)
    case .episode:
      view.podcastEpisodeCardListRow(wash)
    }
  }
}

extension WideCompactCard {
  /// The item flavour. The cover is the subject's own artwork at the card's cover size;
  /// `coverTitle` and `coverAuthor` feed the generated placeholder when there is none, and
  /// default to the row's title.
  init<Inline: View, Trailing: View>(
    item subject: EditorialWashSubject,
    provider: HomeWashProvider,
    coverClient: any ArtworkServing,
    title: String,
    subtitle: String?,
    metadata: String,
    accessibilityLabel: String,
    eyebrow: String? = nil,
    coverTitle: String? = nil,
    coverAuthor: String? = nil,
    @ViewBuilder inlineContent: @escaping () -> Inline,
    @ViewBuilder trailingContent: @escaping () -> Trailing,
    bookZoomSource: BookZoomTransitionSource? = nil,
    @ViewBuilder container: @escaping (MediaItemSummaryRow<BookZoomTransitionCover, Inline, Trailing>) -> Content
  ) {
    let coverSize = Self.itemCoverSize
    self.init(
      subject: subject, provider: provider, chrome: .item, displaySize: coverSize
    ) { wash in
      container(
        MediaItemSummaryRow(
          title: title,
          subtitle: subtitle,
          metadata: metadata,
          accessibilityLabel: accessibilityLabel,
          coverSize: coverSize,
          wash: wash,
          eyebrow: eyebrow,
          cover: {
            BookZoomTransitionCover(
              cover: CoverImageView(
                itemID: subject.itemID, title: coverTitle ?? title, displaySize: coverSize,
                client: coverClient, source: subject.artworkSource, author: coverAuthor,
                revision: subject.artworkRevision),
              source: bookZoomSource)
          },
          inlineContent: inlineContent,
          trailingContent: trailingContent))
    }
  }

  /// The podcast episode flavour, with the show's palette. The row selects and plays through its
  /// own controls; while `isSelecting` it hands both to the multiselect list. `downloadStatus`,
  /// progress (via `playback`) and `adActivity` are read in this card's body, so they redraw the
  /// card, not the list. `showsDate` is false under day headings; height is unchanged.
  init(
    episode: HomePodcastEpisode,
    provider: HomeWashProvider,
    coverClient: any ArtworkServing,
    downloadStatus: DownloadStatusStore,
    playback: PlaybackModel,
    isPlaying: Bool,
    isSelecting: Bool = false,
    showsDate: Bool = true,
    onSelect: @escaping () -> Void,
    onPlay: @escaping () -> Void,
    adActivity: AdSkipActivityModel? = nil
  ) where Content == PodcastEpisodeCardRow<CoverImageView> {
    // Resolved here, not as the default value: in Swift 5 mode a default argument is evaluated
    // nonisolated, and `shared` is main-actor isolated.
    let adActivity = adActivity ?? .shared
    let coverSize = PodcastEpisodeCardRowMetrics.coverSize
    self.init(
      subject: episode.washSubject, provider: provider, chrome: .episode, displaySize: coverSize
    ) { wash in
      let presentation = HomePodcastEpisodePresentation(
        episode: episode,
        progressSeconds: playback.listPositionSeconds(
          itemID: episode.itemID, episodeID: episode.episodeID,
          persisted: episode.progressSeconds),
        playbackRate: playback.effectiveRate(for: episode.itemID))
      return PodcastEpisodeCardRow(
        title: presentation.title,
        showTitle: presentation.showTitle,
        dateText: showsDate ? presentation.dateText : nil,
        durationText: presentation.durationText,
        accessibilityLabel: presentation.accessibilityLabel,
        coverSize: coverSize,
        wash: wash,
        isPlaying: isPlaying,
        isSelecting: isSelecting,
        progressText: presentation.startedTimeText,
        progressFraction: presentation.listening.progressFraction,
        downloadedLabel: downloadStatus.presence(for: episode.itemID, episodeID: episode.episodeID)
          == .completed ? ItemDownloadCopy.completed : nil,
        isCheckingForAds: adActivity.isAnalysing(itemID: episode.itemID, episodeID: episode.episodeID),
        cover: {
          CoverImageView(
            itemID: episode.itemID, title: episode.showTitle, displaySize: coverSize,
            client: coverClient, source: episode.providerArtworkSource,
            revision: episode.artworkRevision)
        },
        onSelect: onSelect,
        onPlay: onPlay)
    }
  }
}

/// Keeps `WideCompactCard`'s public row generic stable while attaching the transition source to
/// the artwork itself. App-only, and a no-op when zoom is disabled.
struct BookZoomTransitionCover: View {
  let cover: CoverImageView
  let source: BookZoomTransitionSource?

  var body: some View {
    cover.bookZoomTransitionSource(source)
  }
}
