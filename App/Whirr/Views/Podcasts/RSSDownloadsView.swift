import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

enum RSSDownloadsViewPresentation {
  static let episodeDeleteMessage = DownloadsViewPresentation.episodeDeleteMessage

  /// The accent line above the title: the feed's author, as a server podcast row shows it. `nil`
  /// for a feed without one, so the row omits the line rather than repeating the "Podcast" badge
  /// that already opens the metadata line.
  static func feedEyebrow(author: String?) -> String? {
    guard let author, author.isEmpty == false else { return nil }
    return author
  }

  /// "Podcast · 51.5 MB": the kind · size shape a server podcast's storage row uses.
  static func feedMetadata(totalBytes: Int64) -> String {
    [
      HomeRowPresentation.badgeLabel(for: .podcast),
      StorageCopy.itemSizeDetail(totalBytes: totalBytes, removedEpisodeBytes: 0),
    ]
    .joined(separator: " · ")
  }

  static func feedDeleteAction(title: String) -> String {
    "Remove downloads for \(title)"
  }

  static func episodeDeleteTitle(title: String) -> String {
    DownloadsViewPresentation.episodeDeleteTitle(title: title)
  }
}

/// The device-owned side of Downloads. Feeds are rows of the same `List` as the server-owned
/// items, with the same summary row, card wash and delete swipe, so the two sources look alike.
///
/// Presents nothing: deletions go up as a `PendingDownloadDeletion` for `DownloadsView` to
/// confirm, since an alert modifier on a row group in a `List` lands on every row and cancels
/// itself (`DownloadsViewPresentation.EpisodeDeleteConfirmationHost`).
struct RSSDownloadsView: View {
  let model: RSSDownloadsModel
  /// The screen's animated mirror of `model.feeds`, not the model's live value: a row removal only
  /// animates when the membership change carries the transaction
  /// (`DownloadsViewPresentation.rowRemovalMotion`).
  let feeds: [RSSDownloadedFeed]
  let homeWashProvider: HomeWashProvider
  let coverClient: any ArtworkServing
  let onRequestDelete: (PendingDownloadDeletion) -> Void
  var isSelecting = false
  @State private var expandedFeedIDs: Set<Int64> = []

  /// A feed is one row in both states. While selecting it is the selectable unit: ticking it
  /// takes the whole feed's downloads, as `DownloadsViewPresentation.selectionPlan` treats a
  /// parent owning its children.
  var body: some View {
    ForEach(feeds) { feed in
      feedRow(feed)
        .tag(DownloadsViewPresentation.SelectionID.rssFeed(feed.id))
        .selectionDisabled(feed.episodes.allSatisfy { $0.state == .deleting })
    }
  }

  private func feedRow(_ feed: RSSDownloadedFeed) -> some View {
    let isExpanded = expandedFeedIDs.contains(feed.id)
    let metadata = RSSDownloadsViewPresentation.feedMetadata(totalBytes: feed.totalBytes)

    // The feed's wash subject carries the canonical `rss:` item id and the feed's artwork source,
    // which is what lets the card colour a device-owned show the way it colours a server one.
    return WideCompactCard(
      item: feed.washSubject,
      provider: homeWashProvider,
      coverClient: coverClient,
      title: feed.title,
      subtitle: nil,
      metadata: metadata,
      accessibilityLabel: [feed.title, feed.author, metadata]
        .compactMap { $0 }
        .joined(separator: ", "),
      eyebrow: RSSDownloadsViewPresentation.feedEyebrow(author: feed.author),
      coverAuthor: feed.author,
      inlineContent: { EmptyView() },
      trailingContent: { EmptyView() }
    ) { summaryRow in
      if isSelecting {
        summaryRow.contentShape(Rectangle())
      } else {
        DisclosureGroup(
          isExpanded: Binding(
            get: { expandedFeedIDs.contains(feed.id) },
            set: { isExpanded in
              if isExpanded { expandedFeedIDs.insert(feed.id) } else { expandedFeedIDs.remove(feed.id) }
            })
        ) {
          ForEach(feed.episodes) { episode in
            episodeRow(feed: feed, episode: episode)
          }
        } label: {
          summaryRow
            // On the label, not the group: a container swipe action is inherited by every
            // disclosed episode row, giving each the feed's Delete as well as its own.
            .downloadDeleteSwipeAction(
              label: RSSDownloadsViewPresentation.feedDeleteAction(title: feed.title),
              hint: "Asks for confirmation before removing."
            ) {
              onRequestDelete(
                PendingDownloadDeletion(
                  id: "feed-\(feed.id)",
                  alertTitle: StorageCopy.purgeItemTitle,
                  message: StorageCopy.purgeItemMessage(title: feed.title)
                ) {
                  await model.purgeItemDownload(feedId: feed.id)
                })
            }
        }
        .accessibilityHint(
          isExpanded ? "Collapses downloaded episodes." : "Expands downloaded episodes."
        )
      }
    }
    .accessibilityIdentifier("rss-download-feed-\(feed.id)")
  }

  @ViewBuilder private func episodeRow(feed: RSSDownloadedFeed, episode: RSSDownloadedEpisode) -> some View {
    let label = HStack {
      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        Text(episode.title)
          .font(WhirrTypeToken.subheadline.font.weight(.semibold))
          .lineLimit(2)
        Text(statusText(for: episode))
          .font(WhirrTypeToken.caption2.font)
          .foregroundStyle(WashInk.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: WhirrSpacing.small)
      if episode.actualBytes > 0 {
        Text(ByteCountFormatter.string(fromByteCount: episode.actualBytes, countStyle: .file))
          .font(WhirrTypeToken.caption.font)
          .monospacedDigit()
          .foregroundStyle(WashInk.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, WhirrSpacing.xSmall)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    label
      .downloadDeleteSwipeAction(
        label: "Remove \(episode.title)",
        hint: "Asks for confirmation before removing this downloaded episode.",
        isDeleting: episode.state == .deleting
      ) {
        onRequestDelete(
          PendingDownloadDeletion(
            id: "episode-\(feed.id)-\(episode.id)",
            alertTitle: RSSDownloadsViewPresentation.episodeDeleteTitle(title: episode.title),
            message: RSSDownloadsViewPresentation.episodeDeleteMessage
          ) {
            await model.purgeEpisodeDownload(feedId: feed.id, episodeID: episode.id)
          })
      }
  }

  private func statusText(for episode: RSSDownloadedEpisode) -> String {
    switch episode.state {
    case .completed: return "Downloaded"
    case .downloading: return "Downloading"
    case .pending where episode.holdReason == .waitingForWiFi: return "Waiting for Wi‑Fi"
    case .pausedAuth where episode.holdReason == .feedCredentials: return "Needs feed credentials"
    case .pausedAuth: return "Authorization required"
    case .paused: return "Paused"
    case .failed: return "Failed"
    case .interrupted: return "Waiting to retry"
    case .deleting: return "Removing…"
    case .pending: return "Waiting"
    }
  }
}
