import Foundation
import SwiftUI
import WatchPlayback
import WatchProtocol

struct WatchPhonePodcastList: View {
  @Environment(WatchCompanionStore.self) private var companion
  @Environment(WatchArtworkStore.self) private var artwork
  let scope: WatchBrowseScope
  let source: WatchBrowseSource?
  let title: String
  let accountStamp: WatchAccountStamp
  @AppStorage private var sortRaw: String
  @AppStorage private var filterRaw: String
  @State private var browse: WatchPhoneBrowseModel

  init(
    scope: WatchBrowseScope, source: WatchBrowseSource?, title: String, accountStamp: WatchAccountStamp,
    companion: WatchCompanionStore
  ) {
    _browse = State(
      initialValue: WatchPhoneBrowseModel(
        scope: scope, source: source, accountStamp: accountStamp,
        currentAccountStamp: { companion.snapshot?.accountStamp },
        loader: { scope, source, page, sort, played, generation in
          await companion.browse(
            scope: scope, source: source, page: page, episodeSort: sort, played: played, generation: generation)
        }))
    self.scope = scope
    self.source = source
    self.title = title
    self.accountStamp = accountStamp
    let scopeKey = (try? JSONEncoder().encode(scope).base64EncodedString()) ?? title
    let key = WatchNavigationPolicy.podcastListPreferenceKey(
      base: accountStamp.accountIdentityHash + "." + scopeKey, source: source)
    _sortRaw = AppStorage(wrappedValue: WatchBrowseEpisodeSort.newest.rawValue, "watch.podcasts.order." + key)
    _filterRaw = AppStorage(wrappedValue: WatchBrowsePlayedFilter.unplayed.rawValue, "watch.podcasts.played." + key)
  }

  private var shows: Bool {
    if case .shows = scope { return true }
    return false
  }
  private var latest: Bool {
    if case .latestEpisodes = scope { return true }
    return false
  }
  private var sort: WatchBrowseEpisodeSort { WatchBrowseEpisodeSort(rawValue: sortRaw) ?? .newest }
  private var filter: WatchBrowsePlayedFilter { WatchBrowsePlayedFilter(rawValue: filterRaw) ?? .unplayed }

  private var emptyEpisodeCopy: String {
    switch filter {
    case .inProgress: "No episodes in progress."
    case .unplayed: "No unplayed episodes."
    case .all: "No episodes found."
    }
  }

  private func artworkSelection(_ show: WatchBrowseShowIdentity) -> WatchSelection {
    switch show {
    case .audiobookshelf(let id): .audiobookshelf(itemID: id, episodeID: "cover")
    case .nativeFeed(let id): .nativeFeed(feedID: id, episodeID: "cover")
    }
  }

  var body: some View {
    List {
      ForEach(browse.rows) { row in
        switch row {
        case .show(let show):
          NavigationLink {
            WatchPhonePodcastList(
              scope: .episodes(show: show.id), source: source, title: show.title, accountStamp: accountStamp,
              companion: companion)
          } label: {
            WatchBrowseEntityRow(
              title: show.title, secondary: show.author,
              selection: artworkSelection(show.id), phoneCatalogueStamp: accountStamp
            ).frame(minHeight: 44)
          }
        case .episode(let episode):
          WatchFollowedEpisodeRow(
            presentation: .init(row: episode, accountStamp: accountStamp, snapshot: companion.snapshot))
        }
      }
      WatchBrowseStatusView(
        phase: browse.phase,
        emptyCopy: browse.rows.isEmpty ? (shows ? "No shows found." : emptyEpisodeCopy) : nil,
        errorCopy: browse.message ?? "",
        loadingCopy: shows ? "Loading shows" : "Loading episodes",
        secondaryEmptyCopy: false, retryMinHeight: nil
      ) { Task { await browse.retry() } }
      WatchBrowsePaginationFooter(hasMore: browse.hasMore, isLoading: browse.isLoading, minHeight: nil) {
        Task { await browse.loadMore() }
      }
      if browse.loaded {
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await browse.refresh() } }
          .disabled(browse.isLoading)
      }
    }
    .navigationTitle(title).watchPlayerToolbar()
    .watchPodcastFilter(
      filterRaw: $filterRaw, sortRaw: $sortRaw, showsOrder: !latest, disabled: browse.isLoading, hidden: shows
    )
    .task { await browse.refresh(sort: sort, filter: filter) }
    .onChange(of: sortRaw) { _, _ in Task { await browse.refresh(sort: sort, filter: filter) } }
    .onChange(of: filterRaw) { _, _ in Task { await browse.refresh(sort: sort, filter: filter) } }
    .onChange(of: companion.snapshot?.accountStamp) { _, _ in browse.accountChanged() }
    .onChange(of: browse.rows) { _, rows in artwork.learnCoverRevisions(from: rows, accountStamp: accountStamp) }
  }
}

/// The phone's followed (native RSS) shows. They play only on the iPhone, so this hub exists only
/// while the phone is reachable; it mirrors the Audiobookshelf Episodes and Shows entries.
struct WatchFollowedPodcastsView: View {
  @Environment(WatchCompanionStore.self) private var companion

  var body: some View {
    List {
      if let stamp = companion.snapshot?.accountStamp {
        NavigationLink {
          WatchPhonePodcastList(
            scope: .latestEpisodes, source: .nativeFeed, title: "Episodes", accountStamp: stamp, companion: companion)
        } label: {
          WatchCategoryLabel(
            title: "Episodes", systemImage: "play.square.stack.fill", color: WatchVisualStyle.podcasts)
        }.frame(minHeight: 44)
        NavigationLink {
          WatchPhonePodcastList(
            scope: .shows, source: .nativeFeed, title: "Shows", accountStamp: stamp, companion: companion)
        } label: {
          WatchCategoryLabel(title: "Shows", systemImage: "mic.fill", color: WatchVisualStyle.podcasts)
        }.frame(minHeight: 44)
      } else {
        WatchSetupHint()
      }
    }.navigationTitle("Followed").watchPlayerToolbar()
  }
}

/// Puts the episode filter in the bottom bar as one neutral toolbar button, matching the
/// audiobook titles list, and presents the choices in a sheet.
private struct WatchPodcastFilterToolbar: ViewModifier {
  @Binding var filterRaw: String
  @Binding var sortRaw: String
  var showsOrder: Bool
  var isDisabled: Bool
  var isHidden: Bool
  @State private var presented = false

  private var label: String {
    switch WatchBrowsePlayedFilter(rawValue: filterRaw) ?? .unplayed {
    case .inProgress: "In Progress"
    case .unplayed: "Unplayed"
    case .all: "All Episodes"
    }
  }

  func body(content: Content) -> some View {
    content
      .toolbar {
        if !isHidden {
          ToolbarItem(placement: .bottomBar) {
            Button("Filter episodes", systemImage: "line.3.horizontal.decrease") { presented = true }
              .disabled(isDisabled)
              .accessibilityValue(
                label + (showsOrder ? (sortRaw == "oldest" ? ", oldest first" : ", newest first") : ""))
          }
        }
      }
      .sheet(isPresented: $presented) {
        NavigationStack {
          List {
            option("Unplayed", value: WatchBrowsePlayedFilter.unplayed.rawValue, selection: $filterRaw)
            option("In Progress", value: WatchBrowsePlayedFilter.inProgress.rawValue, selection: $filterRaw)
            option("All Episodes", value: WatchBrowsePlayedFilter.all.rawValue, selection: $filterRaw)
            if showsOrder {
              Section("Order") {
                option("Newest first", value: WatchBrowseEpisodeSort.newest.rawValue, selection: $sortRaw)
                option("Oldest first", value: WatchBrowseEpisodeSort.oldest.rawValue, selection: $sortRaw)
              }
            }
          }.navigationTitle("Filters")
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                Button("Done", systemImage: "xmark") { presented = false }.labelStyle(.iconOnly)
              }
            }
        }
      }
  }

  private func option(_ title: String, value: String, selection: Binding<String>) -> some View {
    Button {
      selection.wrappedValue = value
      presented = false
    } label: {
      HStack {
        Text(title)
        Spacer(minLength: 4)
        if selection.wrappedValue == value {
          Image(systemName: "checkmark").foregroundStyle(WatchVisualStyle.podcasts)
        }
      }.frame(minHeight: 44)
    }
    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
    .accessibilityAddTraits(selection.wrappedValue == value ? .isSelected : [])
  }
}

extension View {
  func watchPodcastFilter(
    filterRaw: Binding<String>, sortRaw: Binding<String>, showsOrder: Bool = true, disabled: Bool = false,
    hidden: Bool = false
  ) -> some View {
    modifier(
      WatchPodcastFilterToolbar(
        filterRaw: filterRaw, sortRaw: sortRaw, showsOrder: showsOrder, isDisabled: disabled, isHidden: hidden))
  }
}
