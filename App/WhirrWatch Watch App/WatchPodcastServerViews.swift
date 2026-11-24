import SwiftUI
import WatchPlayback
import WatchProtocol

struct WatchPodcastsView: View {
  @Environment(WatchCompanionStore.self) private var companion
  @Environment(WatchLibraryModel.self) private var model
  let client: WatchLibraryClient?
  private var libraryID: String? {
    WatchNavigationPolicy.selectedLibrary(model.libraries, preferred: model.selectedLibrary, mediaType: .podcast)
  }

  init(client: WatchLibraryClient?) {
    self.client = client
  }

  var body: some View {
    List {
      NavigationLink {
        WatchPodcastLatestHubView(
          client: client, libraryID: libraryID, accountStamp: try? model.account?.authenticatedStamp())
      } label: {
        WatchCategoryLabel(title: "Episodes", systemImage: "play.square.stack.fill", color: WatchVisualStyle.podcasts)
      }.frame(minHeight: 44)
      NavigationLink {
        WatchPodcastShowsHubView(
          client: client, libraryID: libraryID, accountStamp: try? model.account?.authenticatedStamp())
      } label: {
        WatchCategoryLabel(title: "Shows", systemImage: "mic.fill", color: WatchVisualStyle.podcasts)
      }.frame(minHeight: 44)
      if WatchNavigationPolicy.offersFollowedOnIPhone(
        phoneReachable: companion.phoneIsReachable, phoneSignedIn: companion.snapshot?.accountStamp != nil,
        followedPodcastsEnabled: companion.snapshot?.followedPodcastsEnabled)
      {
        NavigationLink {
          WatchFollowedPodcastsView()
        } label: {
          WatchCategoryLabel(title: "Followed on iPhone", systemImage: "iphone", color: WatchVisualStyle.podcasts)
        }.frame(minHeight: 44)
      }
      if !(companion.phoneIsReachable && companion.snapshot?.accountStamp != nil),
        WatchNavigationPolicy.libraries(model.libraries, mediaType: .podcast).count > 1
      {
        NavigationLink("Library: \(model.libraries.first(where: { $0.id == libraryID })?.name ?? "Podcasts")") {
          WatchLibraryPickerView(mediaType: .podcast)
        }
      }
      if model.account == nil {
        WatchConnectionStatusView()
      }
    }.navigationTitle("Podcasts").watchPlayerToolbar().task {
      await model.initialize()
      if model.selectedLibrary == nil { await model.refresh() }
    }
  }
}

private struct WatchPodcastLatestHubView: View {
  @Environment(WatchCompanionStore.self) private var companion
  let client: WatchLibraryClient?
  let libraryID: String?
  let accountStamp: WatchAccountStamp?
  var body: some View {
    if companion.phoneIsReachable, let stamp = companion.snapshot?.accountStamp {
      WatchPhonePodcastList(
        scope: .latestEpisodes, source: .audiobookshelf, title: "Episodes", accountStamp: stamp, companion: companion)
    } else if client != nil, libraryID != nil {
      WatchLatestPodcastEpisodesView(client: client, libraryID: libraryID, accountStamp: accountStamp)
    } else {
      List {
        WatchSetupHint()
      }.navigationTitle("Episodes").watchPlayerToolbar()
    }
  }
}

private struct WatchPodcastShowsHubView: View {
  @Environment(WatchCompanionStore.self) private var companion
  let client: WatchLibraryClient?
  let libraryID: String?
  let accountStamp: WatchAccountStamp?
  var body: some View {
    if companion.phoneIsReachable, let stamp = companion.snapshot?.accountStamp {
      WatchPhonePodcastList(
        scope: .shows, source: .audiobookshelf, title: "Shows", accountStamp: stamp, companion: companion)
    } else if client != nil, libraryID != nil {
      WatchPodcastShowsView(client: client, libraryID: libraryID, accountStamp: accountStamp)
    } else {
      List { WatchSetupHint() }.navigationTitle("Shows").watchPlayerToolbar()
    }
  }
}

struct WatchLatestPodcastEpisodesView: View {
  @Environment(WatchLibraryModel.self) private var model
  @State private var browse: WatchBrowseModel
  @State private var filter: WatchPodcastEpisodeFilter = .unplayed
  let client: WatchLibraryClient?
  let libraryID: String?
  let accountStamp: WatchAccountStamp?

  init(client: WatchLibraryClient?, libraryID: String?, accountStamp: WatchAccountStamp?) {
    self.client = client
    self.libraryID = libraryID
    self.accountStamp = accountStamp
    _browse = State(initialValue: WatchBrowseModel(client: client))
  }

  var body: some View {
    List {
      ForEach(browse.episodes) { episode in
        WatchPodcastEpisodeRow(presentation: .init(episode: episode, accountStamp: accountStamp))
      }
      WatchBrowsePaginationFooter(
        hasMore: browse.hasMore, isLoading: browse.phase == .loading, title: "Load more episodes"
      ) {
        Task { await browse.loadMore() }
      }
      WatchBrowseStatusView(
        phase: browse.phase,
        emptyCopy: browse.episodes.isEmpty
          ? filter.emptyCopy : nil,
        errorCopy: browse.errorMessage ?? "Couldn’t load episodes.", loadingCopy: "Loading episodes"
      ) { Task { await browse.retry() } }
    }.navigationTitle("Episodes").watchPlayerToolbar()
      .watchPodcastFilter(
        filterRaw: Binding(
          get: { filter.rawValue }, set: { filter = WatchPodcastEpisodeFilter(rawValue: $0) ?? .unplayed }),
        sortRaw: .constant(WatchPodcastEpisodeSort.newest.rawValue), showsOrder: false,
        disabled: browse.phase == .loading
      ).task(id: filter) {
        guard let libraryID else { return }
        await browse.loadRecentEpisodes(libraryID: libraryID, filter: filter)
      }.onChange(of: model.account?.userID) { _, _ in
        browse.reset()
        Task { if let id = libraryID { await browse.loadRecentEpisodes(libraryID: id, filter: filter) } }
      }
  }
}

struct WatchPodcastShowsView: View {
  @Environment(WatchLibraryModel.self) private var model
  @State private var browse: WatchBrowseModel
  let client: WatchLibraryClient?
  let libraryID: String?
  let accountStamp: WatchAccountStamp?
  @State private var query = ""

  init(client: WatchLibraryClient?, libraryID: String?, accountStamp: WatchAccountStamp?) {
    self.client = client
    self.libraryID = libraryID
    self.accountStamp = accountStamp
    _browse = State(initialValue: WatchBrowseModel(client: client))
  }

  var body: some View {
    List {
      ForEach(browse.shows) { show in
        NavigationLink {
          WatchPodcastShowEpisodesView(client: client, libraryID: libraryID, show: show, accountStamp: accountStamp)
        } label: {
          WatchBrowseEntityRow(
            title: show.title, secondary: "\(show.episodeCount) episode\(show.episodeCount == 1 ? "" : "s")",
            selection: .audiobookshelf(itemID: show.id, episodeID: "cover"), accountStamp: accountStamp)
        }.frame(minHeight: 44)
      }
      WatchBrowsePaginationFooter(
        hasMore: browse.hasMore, isLoading: browse.phase == .loading, title: "Load more shows"
      ) {
        Task { await browse.loadMore() }
      }
      WatchBrowseStatusView(
        phase: browse.phase,
        emptyCopy: browse.shows.isEmpty ? "No podcast shows found." : nil,
        errorCopy: browse.errorMessage ?? "Couldn’t load shows.", loadingCopy: "Loading shows"
      ) { Task { await browse.retry() } }
    }.navigationTitle("Shows").searchable(text: $query, prompt: "Show").watchPlayerToolbar()
      .task(id: query) {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        load()
      }
      .onChange(of: model.account?.userID) { _, _ in
        browse.reset()
        load()
      }
  }

  private func load() {
    guard let libraryID, !libraryID.isEmpty else { return }
    Task { await browse.loadPodcastShows(libraryID: libraryID, query: query) }
  }
}

struct WatchPodcastShowEpisodesView: View {
  @Environment(WatchLibraryModel.self) private var model
  @State private var browse: WatchBrowseModel
  let client: WatchLibraryClient?
  let libraryID: String?
  let show: WatchPodcastShow
  let accountStamp: WatchAccountStamp?
  @AppStorage private var sortRaw: String
  @AppStorage private var filterRaw: String

  init(client: WatchLibraryClient?, libraryID: String?, show: WatchPodcastShow, accountStamp: WatchAccountStamp?) {
    self.client = client
    self.libraryID = libraryID
    self.show = show
    self.accountStamp = accountStamp
    _browse = State(initialValue: WatchBrowseModel(client: client))
    let stamp = accountStamp?.accountIdentityHash ?? "signed-out"
    _sortRaw = AppStorage(
      wrappedValue: WatchPodcastEpisodeSort.newest.rawValue, "watch.podcasts.sort.\(stamp).\(show.id)")
    _filterRaw = AppStorage(
      wrappedValue: WatchPodcastEpisodeFilter.unplayed.rawValue, "watch.podcasts.filter.\(stamp).\(show.id)")
  }

  private var sort: WatchPodcastEpisodeSort { WatchPodcastEpisodeSort(rawValue: sortRaw) ?? .newest }
  private var filter: WatchPodcastEpisodeFilter { WatchPodcastEpisodeFilter(rawValue: filterRaw) ?? .unplayed }

  var body: some View {
    List {
      ForEach(browse.episodes) { episode in
        WatchPodcastEpisodeRow(presentation: .init(episode: episode, accountStamp: accountStamp))
      }
      WatchBrowsePaginationFooter(
        hasMore: browse.hasMore, isLoading: browse.phase == .loading, title: "Load more episodes"
      ) {
        Task { await browse.loadMore() }
      }
      WatchBrowseStatusView(
        phase: browse.phase,
        emptyCopy: browse.episodes.isEmpty
          ? filter.emptyCopy : nil,
        errorCopy: browse.errorMessage ?? "Couldn’t load episodes.", loadingCopy: "Loading episodes"
      ) { Task { await browse.retry() } }
    }.navigationTitle(show.title).watchPlayerToolbar()
      .watchPodcastFilter(filterRaw: $filterRaw, sortRaw: $sortRaw, disabled: browse.phase == .loading)
      .onChange(of: sortRaw) { _, _ in load() }.onChange(of: filterRaw) { _, _ in load() }
      .task { load() }
      .onChange(of: model.account?.userID) { _, _ in
        browse.reset()
        load()
      }
  }

  private func load() {
    guard let libraryID, !libraryID.isEmpty else { return }
    Task { await browse.loadPodcastEpisodes(libraryID: libraryID, showID: show.id, sort: sort, filter: filter) }
  }
}

extension WatchPodcastEpisodeFilter {
  fileprivate var emptyCopy: String {
    switch self {
    case .inProgress: "No episodes in progress."
    case .unplayed: "No unplayed episodes."
    case .all: "No episodes found."
    }
  }
}
