import SwiftUI
import WatchPlayback
import WatchProtocol

struct WatchBrowseStatusView: View {
  let phase: WatchBrowseModel.Phase
  let emptyCopy: String?
  let errorCopy: String
  var loadingCopy: String? = nil
  var secondaryEmptyCopy = true
  var retryMinHeight: CGFloat? = 44
  let retry: () -> Void

  var body: some View {
    switch phase {
    case .idle:
      EmptyView()
    case .loading:
      if let loadingCopy { ProgressView(loadingCopy) }
    case .failed:
      WatchEmptyState(title: "Couldn’t load", message: errorCopy, systemImage: "wifi.exclamationmark")
      Button("Retry", systemImage: "arrow.clockwise", action: retry).frame(minHeight: retryMinHeight)
    case .loaded:
      if let emptyCopy {
        WatchEmptyState(title: "Nothing here yet", message: emptyCopy, systemImage: "books.vertical")
      }
    }
  }
}

struct WatchBrowsePaginationFooter: View {
  let hasMore: Bool
  let isLoading: Bool
  var title = "Load more"
  var minHeight: CGFloat? = 44
  let loadMore: () -> Void

  var body: some View {
    if hasMore {
      Button(title, action: loadMore).frame(minHeight: minHeight).disabled(isLoading)
    }
  }
}

struct WatchBrowseEntityRow: View {
  let title: String
  let secondary: String?
  var selection: WatchSelection? = nil
  var accountStamp: WatchAccountStamp? = nil
  var phoneCatalogueStamp: WatchAccountStamp? = nil

  var body: some View {
    HStack(spacing: 8) {
      if let selection {
        WatchArtworkView(selection: selection, accountStamp: accountStamp, phoneCatalogueStamp: phoneCatalogueStamp)
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.headline).lineLimit(2)
        if let secondary { Text(secondary).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
      }
    }
  }
}

struct WatchPodcastEpisodePresentation {
  let selection: WatchSelection
  let title: String
  let metadata: String
  let capabilities: WatchSelectionCapabilities
  let accountStamp: WatchAccountStamp?
  let phoneCatalogueStamp: WatchAccountStamp?
  let unavailableCopy: String

  init(episode: WatchPodcastBrowseEpisode, accountStamp: WatchAccountStamp?) {
    selection = episode.selection
    title = episode.title
    metadata = WatchDisplayFormatting.metadata([
      episode.showTitle, episode.publishedAt.map { WatchDisplayFormatting.date($0) },
      episode.durationSeconds.map { WatchDisplayFormatting.duration($0) },
    ])
    capabilities = WatchSelectionCapabilities(phonePlayable: episode.audio != nil, watchPlayable: episode.audio != nil)
    self.accountStamp = accountStamp
    phoneCatalogueStamp = nil
    unavailableCopy = "Unavailable"
  }

  init(row: WatchBrowseEpisodeRow, accountStamp: WatchAccountStamp, snapshot: WatchCatalogueSnapshot?) {
    selection = row.selection
    title = row.title
    let time = row.durationSeconds.map {
      row.progressSeconds > 0
        ? "\(WatchDisplayFormatting.duration(max(0, $0 - row.progressSeconds))) left"
        : WatchDisplayFormatting.duration($0)
    }
    metadata = WatchDisplayFormatting.metadata([
      row.showTitle, row.publishedAt.map { WatchDisplayFormatting.date($0) }, time,
    ])
    capabilities = WatchSelectionCapabilities(phonePlayable: row.phonePlayable, watchPlayable: row.watchPlayable)
    self.accountStamp = snapshot?.accountStamp == accountStamp ? snapshot?.authenticatedAccountStamp : nil
    phoneCatalogueStamp = accountStamp
    unavailableCopy = "Unavailable"
  }
}

struct WatchPodcastEpisodeRow: View {
  let presentation: WatchPodcastEpisodePresentation

  var body: some View {
    if presentation.capabilities.phonePlayable || presentation.capabilities.watchPlayable {
      WatchSelectionRow(
        selection: presentation.selection, title: presentation.title, subtitle: presentation.metadata,
        capabilities: presentation.capabilities, accountStamp: presentation.accountStamp,
        phoneCatalogueStamp: presentation.phoneCatalogueStamp)
    } else {
      VStack(alignment: .leading, spacing: 4) {
        Text(presentation.title).lineLimit(2)
        Text(WatchDisplayFormatting.metadata([presentation.unavailableCopy, presentation.metadata]))
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }.frame(minHeight: 44)
    }
  }
}

/// Keeps the glyph vertically centred against wrapped text; the stock `Label` aligns it to the first line.
struct WatchCenteredActionLabel: View {
  let title: String
  let systemImage: String

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Image(systemName: systemImage)
      Text(title).multilineTextAlignment(.leading)
      Spacer(minLength: 0)
    }
  }
}
