import SwiftUI
import WatchPlayback
import WatchProtocol

struct WatchAudiobookTitlesView: View {
  @Environment(WatchLibraryModel.self) private var model
  @State private var browse: WatchBrowseModel
  let client: WatchLibraryClient?
  let libraryID: String?
  let accountStamp: WatchAccountStamp?
  let title: String
  @State private var sort: WatchAudiobookSort
  @State private var searchText = ""
  @State private var selectedLetter: String?
  @State private var showsFilters = false

  init(
    client: WatchLibraryClient?, libraryID: String?, accountStamp: WatchAccountStamp?, title: String,
    sort: WatchAudiobookSort
  ) {
    self.client = client
    self.libraryID = libraryID
    self.accountStamp = accountStamp
    self.title = title
    _sort = State(initialValue: sort)
    _browse = State(initialValue: WatchBrowseModel(client: client))
  }

  private var letters: [String] {
    ["All"] + (65...90).map { String(UnicodeScalar($0)!) }
  }

  private var displayed: [WatchLibraryItem] {
    browse.books
  }

  private var preferenceKey: String {
    "watch.audiobooks.sort.\(accountStamp?.accountIdentityHash ?? "signed-out").\(libraryID ?? "none")"
  }

  var body: some View {
    List {
      titlesSection
    }
    .navigationTitle(title).watchPlayerToolbar()
    .toolbar {
      ToolbarItem(placement: .bottomBar) {
        Button("Sort and filter", systemImage: "line.3.horizontal.decrease") { showsFilters = true }
      }
    }
    .sheet(isPresented: $showsFilters) {
      NavigationStack { filterList }
    }
    .searchable(text: $searchText, prompt: "Title or author")
    .onChange(of: sort) { _, value in
      if title == "All Titles" { UserDefaults.standard.set(value.rawValue, forKey: preferenceKey) }
    }
    .task(id: "\(searchText)|\(selectedLetter ?? "All")|\(sort.rawValue)") {
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      guard !Task.isCancelled else { return }
      await reload()
    }
    .task {
      if title == "All Titles", let stored = UserDefaults.standard.string(forKey: preferenceKey),
        let value = WatchAudiobookSort(rawValue: stored)
      {
        sort = value
      }
    }
    .onChange(of: model.account?.userID) { _, _ in
      browse.reset()
      Task { await reload() }
    }
  }

  private var titlesSection: some View {
    Section {
      if browse.phase == .loading && browse.books.isEmpty { ProgressView("Loading titles") }
      ForEach(displayed) { item in
        WatchSelectionRow(
          selection: item.selection, title: item.title ?? "Untitled audiobook", subtitle: item.author,
          accountStamp: accountStamp)
      }
      WatchBrowsePaginationFooter(
        hasMore: browse.hasMore, isLoading: browse.phase == .loading, title: "Load more titles"
      ) {
        Task { await browse.loadMore() }
      }
      WatchBrowseStatusView(
        phase: browse.phase, emptyCopy: displayed.isEmpty ? "No titles match this search." : nil,
        errorCopy: browse.errorMessage ?? "Couldn’t load this catalogue."
      ) { Task { await browse.retry() } }
    }
  }

  private var filterList: some View {
    List {
      Picker("Starts with", selection: $selectedLetter) {
        ForEach(letters, id: \.self) { letter in
          Text(letter).tag(letter == "All" ? nil : Optional(letter))
        }
      }.pickerStyle(.navigationLink)
      Picker("Sort", selection: $sort) {
        Text("Title A–Z").tag(WatchAudiobookSort.title)
        Text("Author A–Z").tag(WatchAudiobookSort.author)
        Text("Recently added").tag(WatchAudiobookSort.recentlyAdded)
      }.pickerStyle(.navigationLink)
    }.navigationTitle("Filter titles")
  }

  private func reload() async {
    guard let libraryID, !libraryID.isEmpty else { return }
    await browse.loadAudiobooks(
      libraryID: libraryID, query: searchText, sort: sort,
      startsWith: selectedLetter)
  }
}

struct WatchAudiobooksView: View {
  @Environment(WatchLibraryModel.self) private var model
  @Environment(WatchCompanionStore.self) private var companion
  let client: WatchLibraryClient?

  private var libraryID: String? {
    WatchNavigationPolicy.selectedLibrary(model.libraries, preferred: model.selectedLibrary, mediaType: .book)
  }
  private var accountStamp: WatchAccountStamp? { try? model.account?.authenticatedStamp() }
  private var savedSort: WatchAudiobookSort {
    guard let stamp = accountStamp,
      let raw = UserDefaults.standard.string(
        forKey: "watch.audiobooks.sort.\(stamp.accountIdentityHash).\(libraryID ?? "none")")
    else { return .title }
    return WatchAudiobookSort(rawValue: raw) ?? .title
  }

  var body: some View {
    List {
      Section {
        NavigationLink {
          WatchContinueView(audiobooksOnly: true)
        } label: {
          WatchCategoryLabel(title: "Continue", systemImage: "headphones")
        }.frame(minHeight: 44)
        categoryLinks
      }
      libraryProblem
      signedOutPrompt
      libraryPicker
    }
    .navigationTitle("Books").watchPlayerToolbar()
    .task {
      await model.initialize()
      if model.selectedLibrary == nil { await model.refresh() }
    }
  }

  private var categoryLinks: some View {
    Group {
      NavigationLink {
        WatchAudiobookTitlesView(
          client: client, libraryID: libraryID, accountStamp: accountStamp, title: "All Titles", sort: savedSort)
      } label: {
        WatchCategoryLabel(title: "All Titles", systemImage: "books.vertical.fill")
      }.frame(minHeight: 44)
      NavigationLink {
        WatchAudiobookAuthorsView(client: client, libraryID: libraryID, accountStamp: accountStamp)
      } label: {
        WatchCategoryLabel(title: "Authors", systemImage: "person.fill")
      }
      .frame(minHeight: 44)
      NavigationLink {
        WatchAudiobookSeriesView(client: client, libraryID: libraryID, accountStamp: accountStamp)
      } label: {
        WatchCategoryLabel(title: "Series", systemImage: "square.stack.fill")
      }
      .frame(minHeight: 44)
      NavigationLink {
        WatchAudiobookTitlesView(
          client: client, libraryID: libraryID, accountStamp: accountStamp, title: "Recently Added",
          sort: .recentlyAdded)
      } label: {
        WatchCategoryLabel(title: "Recently Added", systemImage: "sparkles")
      }.frame(minHeight: 44)
    }.disabled(client == nil || libraryID == nil)
  }

  @ViewBuilder
  private var libraryProblem: some View {
    if model.account != nil && libraryID == nil {
      Text(model.libraryLoadFailure?.message ?? "No audiobook library available.")
        .font(.caption).foregroundStyle(.secondary)
      if model.isRefreshingLibraries {
        ProgressView("Refreshing")
      } else {
        Button("Refresh libraries", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
      }
    }
  }

  @ViewBuilder
  private var signedOutPrompt: some View {
    if model.account == nil {
      WatchSetupHint(text: "Set up on iPhone to browse")
      WatchPhoneShelf(section: .recentBooks, title: "Recent on iPhone")
    }
  }

  @ViewBuilder
  private var libraryPicker: some View {
    if WatchNavigationPolicy.libraries(model.libraries, mediaType: .book).count > 1 {
      Section {
        NavigationLink("Library: \(model.libraries.first(where: { $0.id == libraryID })?.name ?? "Default")") {
          WatchLibraryPickerView()
        }.frame(minHeight: 44)
      }
    }
  }
}

struct WatchAudiobookAuthorsView: View {
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
      if browse.phase == .loading && browse.authors.isEmpty { ProgressView("Loading authors") }
      ForEach(browse.authors) { author in
        NavigationLink {
          WatchAuthorBooksView(client: client, libraryID: libraryID, author: author, accountStamp: accountStamp)
        } label: {
          WatchBrowseEntityRow(
            title: author.name, secondary: "\(author.bookCount) audiobook\(author.bookCount == 1 ? "" : "s")")
        }.frame(minHeight: 44)
      }
      WatchBrowsePaginationFooter(
        hasMore: browse.hasMore, isLoading: browse.phase == .loading, title: "Load more authors"
      ) {
        Task { await browse.loadMore() }
      }
      WatchBrowseStatusView(
        phase: browse.phase, emptyCopy: browse.authors.isEmpty ? "No authors found." : nil,
        errorCopy: browse.errorMessage ?? "Couldn’t load authors."
      ) { Task { await browse.retry() } }
    }
    .navigationTitle("Authors").watchPlayerToolbar()
    .searchable(text: $query, prompt: "Author")
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
    Task { await browse.loadAuthors(libraryID: libraryID, query: query) }
  }
}

struct WatchAuthorBooksView: View {
  let client: WatchLibraryClient?
  let libraryID: String?
  let author: WatchBrowseAuthor
  let accountStamp: WatchAccountStamp?
  @State private var browse: WatchBrowseModel

  init(client: WatchLibraryClient?, libraryID: String?, author: WatchBrowseAuthor, accountStamp: WatchAccountStamp?) {
    self.client = client
    self.libraryID = libraryID
    self.author = author
    self.accountStamp = accountStamp
    _browse = State(initialValue: WatchBrowseModel(client: client))
  }

  var body: some View {
    List {
      ForEach(browse.books) { item in
        WatchSelectionRow(
          selection: item.selection, title: item.title ?? "Untitled audiobook", subtitle: item.author,
          accountStamp: accountStamp)
      }
      WatchBrowseStatusView(
        phase: browse.phase, emptyCopy: nil,
        errorCopy: browse.errorMessage ?? "Couldn’t load this author.", loadingCopy: "Loading titles"
      ) { Task { await browse.retry() } }
    }.navigationTitle(author.name).watchPlayerToolbar().task {
      guard let libraryID else { return }
      await browse.loadAuthorBooks(libraryID: libraryID, authorID: author.id)
    }
  }
}

struct WatchAudiobookSeriesView: View {
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
      ForEach(browse.series) { series in
        NavigationLink {
          WatchSeriesBooksView(client: client, libraryID: libraryID, series: series, accountStamp: accountStamp)
        } label: {
          WatchBrowseEntityRow(
            title: series.name, secondary: "\(series.bookCount) audiobook\(series.bookCount == 1 ? "" : "s")")
        }.frame(minHeight: 44)
      }
      WatchBrowsePaginationFooter(
        hasMore: browse.hasMore, isLoading: browse.phase == .loading, title: "Load more series"
      ) {
        Task { await browse.loadMore() }
      }
      WatchBrowseStatusView(
        phase: browse.phase, emptyCopy: browse.series.isEmpty ? "No series found." : nil,
        errorCopy: browse.errorMessage ?? "Couldn’t load series."
      ) { Task { await browse.retry() } }
    }.navigationTitle("Series").watchPlayerToolbar()
      .searchable(text: $query, prompt: "Series")
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
    Task { await browse.loadSeries(libraryID: libraryID, query: query) }
  }
}

struct WatchSeriesBooksView: View {
  @Environment(WatchLibraryModel.self) private var model
  @State private var browse: WatchBrowseModel
  let client: WatchLibraryClient?
  let libraryID: String?
  let series: WatchBrowseSeries
  let accountStamp: WatchAccountStamp?

  init(client: WatchLibraryClient?, libraryID: String?, series: WatchBrowseSeries, accountStamp: WatchAccountStamp?) {
    self.client = client
    self.libraryID = libraryID
    self.series = series
    self.accountStamp = accountStamp
    _browse = State(initialValue: WatchBrowseModel(client: client))
  }

  var body: some View {
    List {
      ForEach(browse.seriesBooks) { item in
        WatchSelectionRow(
          selection: item.selection, title: item.title ?? "Untitled audiobook", subtitle: item.author,
          accountStamp: accountStamp)
      }
      WatchBrowsePaginationFooter(
        hasMore: browse.hasMore, isLoading: browse.phase == .loading, title: "Load more books"
      ) {
        Task { await browse.loadMore() }
      }
      WatchBrowseStatusView(
        phase: browse.phase, emptyCopy: nil,
        errorCopy: browse.errorMessage ?? "Couldn’t load this series.", loadingCopy: "Loading series"
      ) { Task { await browse.retry() } }
    }.navigationTitle(series.name).watchPlayerToolbar().task {
      guard let libraryID else { return }
      await browse.loadSeriesBooks(libraryID: libraryID, seriesID: series.id)
    }.onChange(of: model.account?.userID) { _, _ in
      browse.reset()
      Task { if let id = libraryID { await browse.loadSeriesBooks(libraryID: id, seriesID: series.id) } }
    }
  }
}

struct WatchLibraryPickerView: View {
  @Environment(WatchLibraryModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  var mediaType: WatchMediaType = .book

  var body: some View {
    List {
      ForEach(WatchNavigationPolicy.libraries(model.libraries, mediaType: mediaType)) { library in
        Button {
          Task {
            await model.selectLibrary(library.id)
            dismiss()
          }
        } label: {
          Label(library.name, systemImage: model.selectedLibrary == library.id ? "checkmark.circle.fill" : "circle")
        }.frame(minHeight: 44)
      }
    }.navigationTitle("Library").watchPlayerToolbar()
  }
}
