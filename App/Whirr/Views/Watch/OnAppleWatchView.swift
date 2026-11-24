import ABSApi
import DesignSystem
import SwiftUI

/// Everything on the Apple Watch, whoever started it: the books and episodes this iPhone sent and
/// the downloads started on the Watch, with what the Watch is doing about each and the storage they
/// share. Reached from Downloads and Settings › Apple Watch. No tap-through and no origin mark;
/// every row can be removed.
struct OnAppleWatchView: View {
  @Environment(\.watchCopies) private var watchCopies
  /// The shell's one artwork pipeline, so a row's cover shares the cache every other episode row
  /// uses. Nil in previews and harnesses that compose no artwork; those rows then draw the loader's
  /// placeholder square.
  let coverClient: (any ArtworkServing)?

  private static let ringSize: CGFloat = 20

  init(coverClient: (any ArtworkServing)? = nil) {
    self.coverClient = coverClient
  }

  var body: some View {
    let sections = watchCopies?.sections ?? OnAppleWatchSections(audiobooks: [], episodes: [])
    List {
      storageSection
      if watchCopies?.asksToSetUpWatch == true {
        setUpWatchSection
      }
      if sections.isEmpty {
        EmptyStateView(
          title: OnAppleWatchPresentation.emptyTitle,
          message: OnAppleWatchPresentation.emptyMessage,
          systemImage: "applewatch"
        )
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
      } else {
        rowSection(OnAppleWatchPresentation.audiobooksHeader, rows: sections.audiobooks)
        rowSection(OnAppleWatchPresentation.episodesHeader, rows: sections.episodes)
      }
    }
    .listStyle(.plain)
    .navigationTitle(OnAppleWatchPresentation.title)
    .navigationBarTitleDisplayMode(.inline)
    .task {
      watchCopies?.start()
      watchCopies?.refreshWatchAvailability()
    }
  }

  /// The one storage figure for everything on the Watch, as a card heading the screen: a title, a
  /// meter and the figures under it. The bar is hidden from VoiceOver, which hears the figures.
  @ViewBuilder
  private var storageSection: some View {
    if let watchCopies {
      let used = watchCopies.budgetUsedBytes
      let total = watchCopies.budgetTotalBytes
      let readiness = watchCopies.watchAppReadiness
      VStack(alignment: .leading, spacing: WhirrSpacing.small) {
        Text(OnAppleWatchPresentation.storageTitle)
          .font(WhirrTypeToken.headline.font)
        if let fraction = OnAppleWatchPresentation.storageFraction(
          usedBytes: used, totalBytes: total, readiness: readiness)
        {
          StorageMeter(fraction: fraction)
        }
        storageFigures(
          summary: OnAppleWatchPresentation.storageSummary(
            usedBytes: used, totalBytes: total, readiness: readiness),
          free: OnAppleWatchPresentation.storageFree(
            usedBytes: used, totalBytes: total, readiness: readiness))
      }
      .padding(WhirrSpacing.medium)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        WhirrColorToken.surfaceSecondary.color,
        in: RoundedRectangle(cornerRadius: Self.storageCornerRadius, style: .continuous)
      )
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(OnAppleWatchPresentation.storageTitle)
      .accessibilityValue(
        OnAppleWatchPresentation.storageAccessibilityValue(
          usedBytes: used, totalBytes: total, readiness: readiness)
      )
      .accessibilityIdentifier("onAppleWatch.storage")
      .listRowInsets(
        EdgeInsets(
          top: WhirrSpacing.xSmall, leading: WhirrSpacing.medium,
          bottom: WhirrSpacing.small, trailing: WhirrSpacing.medium)
      )
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
    }
  }

  private static let storageCornerRadius: CGFloat = 16

  /// Used on the leading edge and free on the trailing one, stacked when they no longer fit.
  private func storageFigures(summary: String, free: String?) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: WhirrSpacing.small) {
        Text(summary)
        Spacer(minLength: WhirrSpacing.small)
        if let free { Text(free) }
      }
      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        Text(summary)
        if let free { Text(free) }
      }
    }
    .font(.subheadline)
    .foregroundStyle(WhirrColorToken.textSecondary.color)
    .monospacedDigit()
  }

  /// One header in place of the account's books and episodes while the Watch is signed
  /// out or on another account. Setup is on the Watch, so it offers no button.
  private var setUpWatchSection: some View {
    Section {
      Label {
        VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
          Text(OnAppleWatchPresentation.setUpWatchTitle)
            .font(WhirrTypeToken.headline.font)
          Text(OnAppleWatchPresentation.setUpWatchMessage)
            .font(WhirrTypeToken.subheadline.font)
            .foregroundStyle(WhirrColorToken.textSecondary.color)
        }
      } icon: {
        Image(systemName: "applewatch")
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("onAppleWatch.setUpWatch")
    }
  }

  @ViewBuilder
  private func rowSection(_ title: String, rows: [OnAppleWatchRow]) -> some View {
    if rows.isEmpty == false {
      Section(title) {
        ForEach(rows) { row in
          rowView(row)
        }
      }
    }
  }

  /// A row in the shape of the app's other episode lists: artwork, show or author, title and
  /// status, with the device-transfer control at the trailing edge.
  private func rowView(_ row: OnAppleWatchRow) -> some View {
    HStack(alignment: .center, spacing: WhirrSpacing.small) {
      artwork(row)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        if row.subtitle.isEmpty == false {
          Text(row.subtitle)
            .font(WhirrTypeToken.subheadline.font.weight(.medium))
            .foregroundStyle(WhirrColorToken.textSecondary.color)
            .lineLimit(1)
        }
        Text(row.title)
          .font(WhirrTypeToken.headline.font)
          .lineLimit(2)
        Text(row.status.text)
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
          .lineLimit(1)
      }
      .accessibilityElement(children: .combine)
      Spacer(minLength: WhirrSpacing.small)
      trailingControl(row)
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      podcastEpisodeSwipeButtons(
        row.canRemove ? [OnAppleWatchPresentation.removeSwipeButton] : []
      ) { _ in
        Task { await watchCopies?.remove(row.target) }
      }
    }
  }

  @ViewBuilder
  private func artwork(_ row: OnAppleWatchRow) -> some View {
    let size = PodcastEpisodeCardRowMetrics.coverSize
    if let coverClient {
      CoverImageView(
        itemID: row.artworkItemID,
        title: row.subtitle.isEmpty ? row.title : row.subtitle,
        displaySize: size,
        client: coverClient,
        source: row.artworkSource,
        fallbackSource: row.artworkFallbackSource,
        cornerRadius: WhirrSpacing.xSmall,
        revision: row.artworkRevision
      )
      .frame(width: size, height: size)
    } else {
      RoundedRectangle(cornerRadius: WhirrSpacing.xSmall, style: .continuous)
        .fill(WhirrColorToken.groupedSurface.color)
        .frame(width: size, height: size)
    }
  }

  /// The row's one trailing control: the recovery button where the status offers one, otherwise the
  /// Watch's download ring. Its percentage is only as fresh as the Watch's last report, so the ring
  /// carries the fraction without the row claiming a live number.
  @ViewBuilder
  private func trailingControl(_ row: OnAppleWatchRow) -> some View {
    if let action = row.action {
      Button(action.title, systemImage: action.systemImage) {
        Task { await watchCopies?.send(row.target) }
      }
      .font(.footnote.weight(.semibold))
      .buttonStyle(.bordered)
      .buttonBorderShape(.capsule)
      .controlSize(.small)
      .fixedSize()
      .accessibilityLabel("\(action.title): \(row.title)")
    } else if row.status.isDownloading {
      downloadProgress(row.status)
    }
  }

  @ViewBuilder
  private func downloadProgress(_ status: OnAppleWatchStatus) -> some View {
    if let fraction = status.downloadProgressFraction {
      DownloadProgressRing(progressFraction: fraction, systemImage: nil)
        .frame(width: Self.ringSize, height: Self.ringSize)
        .accessibilityLabel("Download progress")
        .accessibilityValue(status.downloadPercentText ?? "")
    } else {
      ProgressView()
        .progressViewStyle(.circular)
        .frame(width: Self.ringSize, height: Self.ringSize)
        .accessibilityLabel("Download progress")
    }
  }
}

/// The Watch storage bar: a capsule track filled to the used share, in the accent colour until the
/// budget is nearly full. Any use at all draws at least a dot, so a few megabytes still register.
private struct StorageMeter: View {
  let fraction: Double

  private static let height = WhirrSpacing.small

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary)
        if fraction > 0 {
          Capsule()
            .fill(tint)
            .frame(width: max(proxy.size.width * CGFloat(fraction), Self.height))
        }
      }
    }
    .frame(height: Self.height)
    .animation(.smooth, value: fraction)
    .accessibilityHidden(true)
  }

  private var tint: Color {
    switch OnAppleWatchPresentation.storageLevel(fraction: fraction) {
    case .normal: WhirrColorToken.accent.color
    case .nearlyFull: .orange
    case .full: .red
    }
  }
}
