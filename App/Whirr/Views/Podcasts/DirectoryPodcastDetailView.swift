import ABSApi
import AppModel
import DesignSystem
import SwiftUI

/// Whether a directory result zooms into its detail page. The page is presented modally rather
/// than pushed: the zoom pop inside `NavigationStack` is the iOS 26 regression that keeps the book
/// zoom switched off, and a modal dismissal does not go through it. If the same touch cancellation
/// shows up here, turning `isAvailable` off leaves a plain presentation and nothing else changes.
nonisolated enum DirectoryPodcastDetailTransitionPolicy {
  static let isAvailable = true

  static func usesZoom(reduceMotion: Bool, isAvailable: Bool = isAvailable) -> Bool {
    isAvailable && reduceMotion == false
  }

  enum Container: Equatable {
    /// Compact width: the page takes the screen, as the App Store's cards do.
    case fullScreen
    /// Regular width: a page-sized card, so it does not overshoot the form sheet it grows from.
    case pageSheet
  }

  static func container(for windowHorizontalSizeClass: UserInterfaceSizeClass?) -> Container {
    windowHorizontalSizeClass == .regular ? .pageSheet : .fullScreen
  }
}

/// A directory result opens the page a followed show has, so its text runs to the same measure:
/// at regular width the page's content is centred on the show page's reading measure, and the
/// hero alone stays full width.
nonisolated enum DirectoryPodcastDetailLayout {
  static func contentHorizontalInset(
    availableWidth: CGFloat,
    horizontalSizeClass: UserInterfaceSizeClass?
  ) -> CGFloat {
    PodcastsViewPresentation.boundedRowHorizontalInset(
      availableWidth: availableWidth, horizontalSizeClass: horizontalSizeClass)
  }

  /// The most of the page the hero may take. On a short page (an iPhone Duo panel, a phone in
  /// landscape) a full-width square pushed the title and author down under the floating Follow
  /// pill; every portrait phone's square is under this share, so it keeps the square.
  static let heroMaximumPageFraction: CGFloat = 0.55

  /// The hero's height, or nil until the page is measured, which keeps the square.
  static func heroHeight(availableWidth: CGFloat, pageHeight: CGFloat) -> CGFloat? {
    guard availableWidth > 0, pageHeight > 0 else { return nil }
    return min(availableWidth, (pageHeight * heroMaximumPageFraction).rounded(.down))
  }
}

extension View {
  /// Marks a directory result row as the zoom's source. The results list is at most
  /// `PodcastDirectorySearchClient.maximumResults` rows in a `Form`, so every row can carry a
  /// standing source. The book shelf's attach-on-tap relay solves a lazy-grid problem this list
  /// does not have.
  @ViewBuilder
  func directoryDetailZoomSource(id: URL, in namespace: Namespace.ID, isEnabled: Bool) -> some View {
    if isEnabled {
      matchedTransitionSource(id: id, in: namespace) { source in
        source
          .background(Color(uiColor: .secondarySystemGroupedBackground))
          .clipShape(RoundedRectangle(cornerRadius: WhirrSpacing.small, style: .continuous))
      }
    } else {
      self
    }
  }

  @ViewBuilder
  func directoryDetailZoomDestination(id: URL, in namespace: Namespace.ID, isEnabled: Bool)
    -> some View
  {
    if isEnabled {
      navigationTransition(.zoom(sourceID: id, in: namespace))
    } else {
      self
    }
  }
}

/// A directory result's description and recent episodes, shown before any follow. The header is
/// drawn from the directory result, so it is in place for the zoom; only the description and
/// episodes wait for the feed. Artwork is the directory's own image: ADR 0004 keeps a feed's
/// declared artwork unfetched until the feed is followed.
///
/// The page is painted with the cover's `CoverWash`, as a followed show's is, from
/// `CoverPaletteService.unsavedPalette` (under the one extraction admission), held in this view
/// only: a preview persists nothing, palette rows included.
struct DirectoryPodcastDetailView: View {
  @Bindable var model: AddFeedModel
  let feedURL: URL
  let artworkClient: any ArtworkServing
  let paletteService: CoverPaletteService
  @Environment(\.dismiss) private var dismiss
  /// The sheet's own size class, not the window's: a regular window's `.page` sheet is wide enough
  /// to report `.regular`, and it is the sheet's width the content has to fit.
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var availableWidth: CGFloat = 0
  @State private var pageHeight: CGFloat = 0
  @State private var expandedEpisodeIDs: Set<Int> = []
  @State private var wash: CoverWash?

  /// A wash too grey to carry a hue paints nothing, as on the show page: its page colour sits
  /// within a few percent of the plain background.
  private var pageWash: CoverWash? { wash?.accentColor == nil ? nil : wash }

  var body: some View {
    NavigationStack {
      ScrollView {
        if let detail = model.directoryDetail(for: feedURL) {
          VStack(alignment: .leading, spacing: WhirrSpacing.large) {
            DirectoryPodcastHero(
              detail: detail, artworkClient: artworkClient, paletteService: paletteService,
              pageColor: pageColor,
              height: DirectoryPodcastDetailLayout.heroHeight(
                availableWidth: availableWidth, pageHeight: pageHeight),
              wash: $wash)
            VStack(alignment: .leading, spacing: WhirrSpacing.large) {
              header(detail)
              content(detail)
            }
            .padding(.horizontal, contentHorizontalInset)
          }
          .padding(.bottom, WhirrSpacing.large)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .onGeometryChange(for: CGSize.self) { geometry in
        geometry.size
      } action: { size in
        availableWidth = size.width
        pageHeight = size.height
      }
      // The hero is the top of the page, under the status bar and the close button, rather than a
      // square inset below them.
      .ignoresSafeArea(.container, edges: .top)
      .scrollEdgeEffectStyle(.soft, for: .top)
      .background(pageColor.ignoresSafeArea())
      .drawnOnCoverWash(pageWash)
      .tint(pageWash?.accentColor ?? WhirrColorToken.accent.color)
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
      // Status bar and close button sit on the artwork's darkened top edge whatever the appearance.
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(role: .close) { dismiss() }
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) { followPill }
    }
    .animation(.easeInOut(duration: 0.35), value: wash)
    .task(id: feedURL) { await model.openDirectoryDetail(feedURL: feedURL) }
  }

  private var contentHorizontalInset: CGFloat {
    DirectoryPodcastDetailLayout.contentHorizontalInset(
      availableWidth: availableWidth, horizontalSizeClass: horizontalSizeClass)
  }

  private var pageColor: Color {
    pageWash?.pageColor ?? WhirrColorToken.surfacePrimary.color
  }

  /// The cover's accent as small text on the page: each episode's date line and the rules between
  /// rows. It is what breaks up a page otherwise set entirely in near-white on the wash, so it is
  /// solved to the text contrast floor rather than the 3:1 a mark would need.
  private var pageMark: Color {
    pageWash?.accentColor(on: .page, minimumRatio: 4.5) ?? WhirrColorToken.accent.color
  }

  private func header(_ detail: DirectoryPodcastDetailDisplay) -> some View {
    VStack(spacing: WhirrSpacing.xSmall) {
      Text(detail.title)
        .font(.title.bold())
        .multilineTextAlignment(.center)
      if let author = detail.author {
        Text(author)
          .font(.body)
          .foregroundStyle(WashInk.secondary)
          .multilineTextAlignment(.center)
      }
      if let count = detail.episodeCountText {
        Text(count)
          .font(.subheadline)
          .foregroundStyle(WashInk.secondary)
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }

  @ViewBuilder
  private func content(_ detail: DirectoryPodcastDetailDisplay) -> some View {
    switch detail.content {
    case .loading:
      HStack(spacing: WhirrSpacing.small) {
        ProgressView()
        Text(AddFeedSheetPresentation.detailLoadingLabel)
          .foregroundStyle(WashInk.secondary)
      }
      .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
    case .failed(let message):
      VStack(spacing: WhirrSpacing.small) {
        Text(message)
          .foregroundStyle(WashInk.destructive)
          .multilineTextAlignment(.center)
        Button(AddFeedSheetPresentation.detailRetryLabel) {
          Task { await model.openDirectoryDetail(feedURL: feedURL) }
        }
        .buttonStyle(.glass)
      }
      .frame(maxWidth: .infinity)
    case .loaded(let description, let episodes):
      if let description {
        VStack(alignment: .leading, spacing: WhirrSpacing.small) {
          sectionTitle(AddFeedSheetPresentation.detailAboutTitle)
          // Never clamped: the description is what someone opened this page to read.
          Text(description)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      episodesSection(episodes)
    }
  }

  private func episodesSection(_ episodes: [DirectoryEpisodeDisplay]) -> some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.small) {
      sectionTitle(AddFeedSheetPresentation.detailRecentEpisodesTitle)
      if episodes.isEmpty {
        Text(AddFeedSheetPresentation.detailNoEpisodes)
          .foregroundStyle(WashInk.secondary)
      } else {
        ForEach(episodes) { episode in
          if episode.id != episodes.first?.id {
            // A system divider all but vanishes on a coloured page.
            Divider().overlay(pageMark.opacity(0.35))
          }
          episodeRow(episode)
        }
      }
    }
  }

  private func sectionTitle(_ title: String) -> some View {
    Text(title)
      .font(.title3.bold())
      .accessibilityAddTraits(.isHeader)
  }

  @ViewBuilder
  private func episodeRow(_ episode: DirectoryEpisodeDisplay) -> some View {
    let isExpanded = expandedEpisodeIDs.contains(episode.id)
    let label = VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
      // Date and length lead the row, as in Apple Podcasts: a coloured line to scan down that
      // separates one episode from the next better than its title can.
      if let metadata = episode.metadata {
        Text(metadata)
          .font(.caption.weight(.semibold))
          .foregroundStyle(pageMark)
      }
      Text(episode.title)
        .font(.body.weight(.semibold))
        .multilineTextAlignment(.leading)
      if let notes = episode.notes {
        Text(notes)
          .font(.subheadline)
          .foregroundStyle(WashInk.secondary)
          .lineLimit(isExpanded ? nil : 2)
          .multilineTextAlignment(.leading)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, WhirrSpacing.xxSmall)
    .contentShape(Rectangle())

    if episode.notes != nil {
      Button {
        withAnimation(.snappy) {
          if isExpanded {
            expandedEpisodeIDs.remove(episode.id)
          } else {
            expandedEpisodeIDs.insert(episode.id)
          }
        }
      } label: {
        label
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityHint(
        isExpanded ? "" : AddFeedSheetPresentation.detailEpisodeAccessibilityHint)
    } else {
      label.accessibilityElement(children: .combine)
    }
  }

  /// A floating glass capsule over the page rather than a bar across it, so the show's colour runs
  /// to the bottom edge. Its fill takes the cover's accent through the page tint.
  @ViewBuilder
  private var followPill: some View {
    VStack(spacing: WhirrSpacing.xSmall) {
      if let error = model.directoryFollowErrors[feedURL] {
        Label(
          AddFeedSheetPresentation.directoryFollowMessage(for: error),
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(WashInk.destructive)
        .padding(.horizontal, WhirrSpacing.medium)
        .padding(.vertical, WhirrSpacing.xSmall)
        .glassEffect(.regular, in: .capsule)
      }
      if model.isDirectoryResultFollowed(feedURL) {
        Label(AddFeedSheetPresentation.followedLabel, systemImage: "checkmark")
          .font(.headline)
          .padding(.horizontal, WhirrSpacing.xLarge)
          .frame(minHeight: WhirrMetric.minimumTouchTarget)
          .glassEffect(.regular, in: .capsule)
      } else {
        let isFollowingThis = model.directoryFollowingURL == feedURL
        // The dark band of a cover accent is a bright colour, so the capsule's default white label
        // disappears on it; the pair picks the label per appearance against the fill it sits on.
        let colors = legibleAccentColors(for: pageWash?.accentColor ?? WhirrColorToken.accent.color)
        Button {
          Task { await model.followDirectoryResult(feedURL: feedURL) }
        } label: {
          HStack(spacing: WhirrSpacing.small) {
            if isFollowingThis { ProgressView().tint(colors.ink) }
            Text(
              isFollowingThis
                ? AddFeedSheetPresentation.followingLabel
                : AddFeedSheetPresentation.followButtonLabel)
          }
          .font(.headline)
          .foregroundStyle(colors.ink)
          .padding(.horizontal, WhirrSpacing.large)
          .frame(minHeight: WhirrMetric.minimumTouchTarget)
        }
        .buttonStyle(.glassProminent)
        .tint(colors.fill)
        .buttonBorderShape(.capsule)
        // Not disabled while this follow runs: `.glassProminent` drops its fill when disabled,
        // which would empty the capsule reporting the follow. Another row's follow does disable it.
        .disabled(model.directoryFollowingURL != nil && isFollowingThis == false)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, WhirrSpacing.medium)
    .padding(.bottom, WhirrSpacing.small)
  }
}

/// The directory artwork, full width from the physical top edge and square unless the page is short
/// (`DirectoryPodcastDetailLayout.heroHeight`), fading into the page.
///
/// It asks for the directory image at hero size first and falls back to the 600px image the search
/// returned. The row's own thumbnail, already cached, holds the frame until one arrives, so the
/// zoom lands on artwork rather than an empty square. The loaded bytes also give the page its wash.
private struct DirectoryPodcastHero: View {
  let detail: DirectoryPodcastDetailDisplay
  let artworkClient: any ArtworkServing
  let paletteService: CoverPaletteService
  let pageColor: Color
  /// From `DirectoryPodcastDetailLayout.heroHeight`; nil draws the full-width square.
  let height: CGFloat?
  @Binding var wash: CoverWash?
  @Environment(\.displayScale) private var displayScale
  @State private var image: UIImage?

  /// The request tier, not the drawn size: a phone-width hero at 3x wants the whole 1200px image,
  /// and `.highFidelity` rounds this up to it. Fixed so every width shares one cache entry.
  private static let requestSize: CGFloat = 400
  /// The row's thumbnail size in `AddFeedSheetView`, so the placeholder is a prepared-cache hit.
  private static let rowThumbnailSize: CGFloat = 48
  /// How far down the artwork the page colour starts taking over.
  private static let fadeHeight: CGFloat = 120
  /// Darkens the top of the artwork so the status bar and close button read on a pale cover.
  private static let scrimHeight: CGFloat = 140

  var body: some View {
    frame
      .overlay {
        if let image {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .transition(.opacity)
        } else {
          placeholder
        }
      }
      .clipped()
      .overlay(alignment: .top) {
        LinearGradient(
          colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom
        )
        .frame(height: Self.scrimHeight)
      }
      .overlay(alignment: .bottom) {
        LinearGradient(colors: [.clear, pageColor], startPoint: .top, endPoint: .bottom)
          .frame(height: Self.fadeHeight)
      }
      .animation(.easeInOut(duration: 0.25), value: image != nil)
      .accessibilityHidden(true)
      .task(id: detail.feedURL) { await load() }
  }

  /// Full width, and square unless the page caps the height; a capped hero crops the artwork.
  @ViewBuilder
  private var frame: some View {
    if let height {
      Color.clear.frame(maxWidth: .infinity).frame(height: height)
    } else {
      Color.clear.aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity)
    }
  }

  @ViewBuilder
  private var placeholder: some View {
    if let artworkURL = detail.artworkURL, let source = source(for: artworkURL) {
      CoverImageView(
        itemID: detail.feedURL.absoluteString,
        title: detail.title,
        displaySize: Self.rowThumbnailSize,
        client: artworkClient,
        source: .rss(source),
        cornerRadius: 0,
        revision: .unversioned
      )
      .blur(radius: 12)
    } else {
      WhirrColorToken.groupedSurface.color
        .overlay {
          Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.system(size: 56))
            .foregroundStyle(WhirrColorToken.textSecondary.color)
        }
    }
  }

  private func source(for url: URL) -> RSSArtworkSource? {
    RSSArtworkSource(feedIdentity: "directory:\(detail.feedURL.absoluteString)", artworkURL: url)
  }

  private func load() async {
    for url in [detail.heroArtworkURL, detail.largeArtworkURL].compactMap(\.self) {
      guard let source = source(for: url) else { continue }
      let key = CoverImageView.artworkKey(
        itemID: detail.feedURL.absoluteString, client: artworkClient, source: .rss(source),
        displaySize: Self.requestSize, displayScale: displayScale, role: .highFidelity,
        revision: .unversioned)
      guard
        let loaded = await ArtworkImagePipeline.shared.image(
          for: key, priority: .visible, client: artworkClient)
      else {
        if Task.isCancelled { return }
        continue
      }
      image = loaded
      guard let data = await artworkClient.data(for: key),
        let palette = await paletteService.unsavedPalette(from: data),
        Task.isCancelled == false
      else { return }
      let accent = palette.rawAccentHSB
      wash = CoverWash.from(
        hue: accent?.hue, saturation: accent?.saturation, brightness: accent?.brightness)
      return
    }
  }
}
