import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI
import Testing

@testable import Whirr

/// Presentation rules for Library collections.
@Suite("Library collections presentation")
struct LibraryCollectionsPresentationTests {
  @Test("Collections is the fourth mode and has no entity kind")
  func collectionsIsTheFourthMode() {
    #expect(LibraryBrowsePresentation.Mode.allCases.last == .collections)
    #expect(LibraryBrowsePresentation.Mode.collections.label == "Collections")
    #expect(LibraryBrowsePresentation.Mode.collections.entityKind == nil)
    #expect(LibraryBrowsePresentation.quickFilterPrompt(for: .collections) == "Filter collections")
  }

  @Test("regular width draws Collections as the compact list and keeps the grid for the others")
  func regularWidthUsesTheCompactListForCollections() {
    #expect(
      LibraryBrowseLayoutPresentation.indexOwner(for: .regular, mode: .collections) == .nativeList)
    #expect(
      LibraryBrowseLayoutPresentation.indexOwner(for: .compact, mode: .collections) == .nativeList)
    for mode in [LibraryBrowsePresentation.Mode.titles, .authors, .series] {
      #expect(LibraryBrowseLayoutPresentation.indexOwner(for: .regular, mode: mode) == .jumpMenu)
      #expect(LibraryBrowseLayoutPresentation.indexOwner(for: .compact, mode: mode) == .nativeList)
    }
  }

  @Test("sections are named, collections first, each with its own glyph")
  func sectionsAndSymbols() {
    #expect(LibraryCollectionsPresentation.sectionTitle(for: .collection) == "Collections")
    #expect(LibraryCollectionsPresentation.sectionTitle(for: .playlist) == "Playlists")
    #expect(LibraryCollectionsPresentation.symbol(for: .collection) == "rectangle.stack")
    #expect(LibraryCollectionsPresentation.symbol(for: .playlist) == "music.note.list")
  }

  @Test("a row counts titles, or episodes for an episode playlist, and names its library when asked")
  func rowSubtitleAndAccessibilityLabel() {
    let collection = row(kind: .collection, name: "Favourites", held: 12, categories: [.audiobook])
    #expect(LibraryCollectionsPresentation.subtitle(for: collection) == "12 titles")
    #expect(
      LibraryCollectionsPresentation.accessibilityLabel(for: collection)
        == "Collection, Favourites, 12 titles")

    let episodes = row(
      kind: .playlist, name: "Commute", held: 1, categories: [.podcast], showsLibraryName: true)
    #expect(LibraryCollectionsPresentation.subtitle(for: episodes) == "1 episode in Podcasts")
    #expect(
      LibraryCollectionsPresentation.accessibilityLabel(for: episodes)
        == "Playlist, Commute, 1 episode in Podcasts")
  }

  @Test("a pinned list's row says it is downloaded")
  func pinnedRowAccessibilityLabel() {
    let pinned = row(kind: .collection, name: "Favourites", held: 12, isPinned: true)
    #expect(
      LibraryCollectionsPresentation.accessibilityLabel(for: pinned)
        == "Collection, Favourites, 12 titles, Downloaded")
  }

  @Test("the list's download control speaks the book page's glyphs and roles")
  func pinnedDownloadControl() {
    #expect(PinnedListDownloadPresentation.kind(for: .off) == .notDownloaded)
    #expect(PinnedListDownloadPresentation.kind(for: .failed(count: 2)) == .failed)
    #expect(DownloadControlRole.role(for: PinnedListDownloadPresentation.kind(for: .failed(count: 1))) == .warning)
    #expect(PinnedListDownloadPresentation.progressFraction(for: .downloading(done: 1, total: 4)) == 0.25)
    #expect(PinnedListDownloadPresentation.progressFraction(for: .downloading(done: 0, total: 0)) == 0)
    #expect(PinnedListDownloadPresentation.progressFraction(for: .downloaded) == nil)
    let states: [PinnedListDownloadModel.State] = [
      .off, .downloading(done: 0, total: 1), .downloaded, .waitingForWiFi, .failed(count: 1),
    ]
    for state in states {
      #expect(
        ItemDetailDownloadBubblePresentation.isEnclosed(PinnedListDownloadPresentation.systemImage(for: state))
          == false)
    }
    #expect(PinnedListDownloadPresentation.accessibilityLabel(for: .off) == "Download List")
    #expect(
      PinnedListDownloadPresentation.accessibilityLabel(for: .downloading(done: 2, total: 5))
        == "Downloads, Downloaded 2 of 5")
  }

  @Test("a list's header names its kind and count without a separator glyph")
  func headerSummary() {
    #expect(
      LibraryCollectionPresentation.summary(kind: .playlist, heldCount: 2, categories: [.podcast])
        == "Playlist of 2 episodes")
    #expect(
      LibraryCollectionPresentation.summary(kind: .collection, heldCount: 1, categories: [.audiobook])
        == "Collection of 1 title")
  }

  @Test("a list the server left unnamed still has a title")
  func unnamedListsHaveATitle() {
    #expect(
      LibraryCollectionsPresentation.displayName(for: row(kind: .collection, name: nil).listing)
        == "Untitled Collection")
    #expect(
      LibraryCollectionsPresentation.displayName(for: row(kind: .playlist, name: "  ").listing)
        == "Untitled Playlist")
  }

  @Test("the quick filter matches a list's name and description")
  func quickFilterMatchesNameAndDescription() {
    let rows = [
      row(kind: .collection, name: "Space Opera", description: nil),
      row(kind: .collection, name: "Shortlist", description: "Booker prize"),
      row(kind: .playlist, name: "Commute", description: nil),
    ]
    #expect(LibraryCollectionsPresentation.filter(rows, query: "").count == 3)
    #expect(
      LibraryCollectionsPresentation.filter(rows, query: "space").map(\.listing.name)
        == ["Space Opera"])
    #expect(
      LibraryCollectionsPresentation.filter(rows, query: "booker").map(\.listing.name)
        == ["Shortlist"])
  }

  @Test("loading and empty are overlays; filtered-empty and loaded draw in the list")
  func listPlaceholders() {
    #expect(
      LibraryCollectionsPresentation.placeholder(for: .loading)
        == .loading(message: "Loading collections…"))
    #expect(
      LibraryCollectionsPresentation.placeholder(for: .empty)
        == .empty(
          title: "No Collections or Playlists",
          message: "Collections and playlists you make in the Audiobookshelf web client appear here.",
          systemImage: "rectangle.stack"))
    #expect(LibraryCollectionsPresentation.placeholder(for: .filteredEmpty) == nil)
    #expect(LibraryCollectionsPresentation.placeholder(for: .loaded) == nil)
  }

  @Test("in Collections only the media kinds count as engaged filters")
  func inertFiltersAreNotShownActive() {
    let inert = BrowseFilters(downloadedOnly: true, playback: .finished)
    #expect(
      BrowseFilterMenuPresentation.displayedFilters(inert, appliesCategoriesOnly: true).isActive
        == false)
    #expect(
      BrowseFilterMenuPresentation.displayedFilters(inert, appliesCategoriesOnly: false) == inert)

    let mixed = BrowseFilters(categories: [.podcast], downloadedOnly: true)
    #expect(
      BrowseFilterMenuPresentation.displayedFilters(mixed, appliesCategoriesOnly: true)
        == BrowseFilters(categories: [.podcast]))
  }

  // MARK: Bar title and placeholders

  @Test("the bar title stays hidden while the header shows the name, and fills in once it scrolls away")
  func barTitleNeverDoublesTheHeaderTitle() {
    #expect(LibraryCollectionPresentation.showsBarTitle(hasHeader: true, isHeaderTitleVisible: true) == false)
    #expect(LibraryCollectionPresentation.showsBarTitle(hasHeader: true, isHeaderTitleVisible: false))
    #expect(LibraryCollectionPresentation.showsBarTitle(hasHeader: false, isHeaderTitleVisible: false))
  }

  @Test("a collection's screen states loading, nothing held, and a list a refresh removed")
  func detailPlaceholders() {
    #expect(
      LibraryCollectionPresentation.placeholder(for: .loading, kind: .playlist)
        == .loading(message: "Loading…"))
    #expect(
      LibraryCollectionPresentation.placeholder(for: .unavailable, kind: .collection)
        == .empty(
          title: "No Longer Available", message: "This collection is no longer available.",
          systemImage: "exclamationmark.triangle"))
    #expect(
      LibraryCollectionPresentation.placeholder(for: .empty, kind: .playlist)
        == .empty(
          title: "Nothing on This Device",
          message: "None of this playlist's items are in your library on this device.",
          systemImage: "music.note.list"))
    #expect(LibraryCollectionPresentation.placeholder(for: .loaded, kind: .collection) == nil)
  }

  /// Server lists are read-only in Whirr. The footer says where they are edited, in the Library's
  /// Collections mode and under each list. The list screen offers no edit at all.
  @Test("the lists are read-only here, and a footer says where they are edited")
  func listsAreReadOnlyWithAnEditingFooter() {
    #expect(
      LibraryCollectionsPresentation.editingNote
        == "To edit collections and playlists, use Audiobookshelf on the web.")
  }

  @Test("entry labels say what each row is, including an episode and a finished title")
  func entryAccessibilityLabels() {
    let book = LibraryCollectionEntry.title(
      ItemSummary(
        serverItemId: "b", mediaKind: "book", title: "Dune", author: "Frank Herbert",
        durationSeconds: 60, category: .audiobook),
      isFinished: true)
    #expect(
      LibraryCollectionPresentation.accessibilityLabel(for: book)
        == "Dune, Frank Herbert, \(ItemFinishedCopy.badgeLabel)")

    let episode = LibraryCollectionEntry.episode(
      HomePodcastEpisode(
        itemID: "show", showTitle: "The Show", showAuthor: nil, episodeID: "e", title: "Pilot",
        subtitle: nil, publishedAt: .distantPast, durationSeconds: 30))
    #expect(
      LibraryCollectionPresentation.accessibilityLabel(for: episode) == "Episode, Pilot, The Show")
  }

  @Test("every list refresh is followed by a pinned-list pass, so new members download")
  func listRefreshesRunThePinnedListPass() throws {
    // One site in `AppEnvironment.init` (the sync traversal) and one in the Collections fill.
    let sources = [
      "App/Whirr/AppEnvironment.swift",
      "App/Whirr/AppEnvironment+LibraryCollectionsComposition.swift",
    ]
    var refreshSites = 0
    for source in sources {
      let text = try ViewSourceScan.executableText(
        of: ViewSourceScan.repositoryRoot().appending(path: source))
      let refreshes = ViewSourceScan.occurrences(of: ["await libraryCollectionService.refreshAll("], in: text)
      #expect(refreshes == 1, "\(source) must keep its one refresh site")
      let passes = text.components(separatedBy: "await libraryCollectionService.refreshAll(").dropFirst()
        .filter { $0.split(separator: "\n").dropFirst().first?.contains("await pinnedListReconciler?.run()") == true }
      #expect(passes.count == refreshes, "every refresh in \(source) must be followed by the pinned-list pass")
      refreshSites += refreshes
    }
    #expect(refreshSites == 2)
  }

  @Test("the collection screen's selection identifiers are pinned and share the toolbar's prefix")
  func selectionIdentifiersShareTheToolbarPrefix() {
    #expect(SelectionChromePresentation.Screen.libraryCollection.invitation == "Select Items")
    let root = SelectionChromePresentation.Screen.libraryCollection.accessibilityIdentifierPrefix + ".selection."
    #expect(root == "libraryCollection.selection.")
    for identifier in [
      LibraryAccessibilityID.collectionSelectionDownload,
      LibraryAccessibilityID.collectionSelectionMarkAsFinished,
      LibraryAccessibilityID.collectionSelectionActions,
    ] {
      #expect(identifier.hasPrefix(root), Comment(rawValue: identifier))
    }
  }

  // MARK: Fixtures

  private func row(
    kind: LibraryCollectionListKind,
    name: String?,
    held: Int = 1,
    categories: Set<ItemMediaCategory> = [.audiobook],
    description: String? = nil,
    showsLibraryName: Bool = false,
    isPinned: Bool = false
  ) -> LibraryCollectionsBrowseModel.Row {
    LibraryCollectionsBrowseModel.Row(
      listing: LibraryCollectionListing(
        key: LibraryCollectionKey(
          serverLibraryID: "lib", kind: kind, serverID: name ?? UUID().uuidString),
        libraryName: "Podcasts", name: name, description: description, lastUpdate: nil,
        heldMemberCount: held, heldCategories: categories),
      showsLibraryName: showsLibraryName, isPinned: isPinned)
  }
}
