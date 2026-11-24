import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// Pure copy and derivation for the Library's Collections mode.
nonisolated enum LibraryCollectionsPresentation {
  static let emptyTitle = "No Collections or Playlists"
  static let emptyMessage =
    "Collections and playlists you make in the Audiobookshelf web client appear here."
  /// Whirr shows these lists but never edits them; this says where they are edited.
  static let editingNote = "To edit collections and playlists, use Audiobookshelf on the web."
  static let loadingMessage = "Loading collections…"

  static func symbol(for kind: LibraryCollectionListKind) -> String {
    switch kind {
    case .collection: "rectangle.stack"
    case .playlist: "music.note.list"
    }
  }

  static func sectionTitle(for kind: LibraryCollectionListKind) -> String {
    switch kind {
    case .collection: "Collections"
    case .playlist: "Playlists"
    }
  }

  static func kindLabel(for kind: LibraryCollectionListKind) -> String {
    switch kind {
    case .collection: "Collection"
    case .playlist: "Playlist"
    }
  }

  /// The server allows a list with no name; it still needs a row title.
  static func displayName(for listing: LibraryCollectionListing) -> String {
    if let name = listing.name?.trimmingCharacters(in: .whitespacesAndNewlines), name.isEmpty == false {
      return name
    }
    switch listing.key.kind {
    case .collection: return "Untitled Collection"
    case .playlist: return "Untitled Playlist"
    }
  }

  /// "12 titles", or "3 episodes" for a playlist that holds only episodes. A playlist holds books
  /// or episodes, never both, so "titles" is right for everything else.
  static func countText(heldCount: Int, categories: Set<ItemMediaCategory>) -> String {
    let isEpisodes = categories == [.podcast]
    let noun =
      isEpisodes
      ? (heldCount == 1 ? "episode" : "episodes")
      : (heldCount == 1 ? "title" : "titles")
    return "\(heldCount) \(noun)"
  }

  static func subtitle(for row: LibraryCollectionsBrowseModel.Row) -> String {
    let count = countText(
      heldCount: row.listing.heldMemberCount, categories: row.listing.heldCategories)
    return row.showsLibraryName ? "\(count) in \(row.listing.libraryName)" : count
  }

  static let pinnedSymbol = "arrow.down.circle.fill"

  /// "Collection, Favourites, 12 titles", plus the library when the list says which. The row
  /// ignores its children, so the pin's glyph is said here or not at all.
  static func accessibilityLabel(for row: LibraryCollectionsBrowseModel.Row) -> String {
    var parts = [kindLabel(for: row.listing.key.kind), displayName(for: row.listing), subtitle(for: row)]
    if row.isPinned { parts.append(PinnedListDownloadCopy.accessibilityDownloaded) }
    return parts.joined(separator: ", ")
  }

  /// The quick filter matches a list's name and description.
  static func filter(
    _ rows: [LibraryCollectionsBrowseModel.Row], query: String
  ) -> [LibraryCollectionsBrowseModel.Row] {
    let fragments = LibraryQuickFilter.fragments(query)
    guard fragments.isEmpty == false else { return rows }
    return rows.filter {
      LibraryQuickFilter.matches(
        fragments: fragments, fields: [displayName(for: $0.listing), $0.listing.description])
    }
  }

  /// The overlay states. `filteredEmpty` is drawn in the list, beside the way out of it.
  static func placeholder(
    for state: LibraryCollectionsBrowseModel.State
  ) -> LibraryBrowsePresentation.Placeholder? {
    switch state {
    case .loading: .loading(message: loadingMessage)
    case .empty:
      .empty(title: emptyTitle, message: emptyMessage, systemImage: symbol(for: .collection))
    case .filteredEmpty, .loaded: nil
    }
  }
}

/// The Collections mode's rows for the root's `List`: a Collections section, then Playlists, each
/// omitted when empty. Loading and empty states are the root's overlay
/// (`LibraryCollectionsPresentation.placeholder`); the two recovery states stay in the list so
/// their buttons stay live.
struct LibraryBrowseCollectionsView: View {
  @Bindable var model: LibraryCollectionsBrowseModel
  let query: String
  let onSelect: (LibraryCollectionKey) -> Void
  let onClearFilters: () -> Void

  var body: some View {
    let collections = LibraryCollectionsPresentation.filter(model.collections, query: query)
    let playlists = LibraryCollectionsPresentation.filter(model.playlists, query: query)

    switch model.state {
    case .loading, .empty:
      EmptyView()
    case .filteredEmpty:
      filteredEmptyState
        .editorialListRow()
    case .loaded:
      if collections.isEmpty && playlists.isEmpty {
        queryEmptyState
          .editorialListRow()
      } else {
        section(.collection, rows: collections)
        section(.playlist, rows: playlists)
        LibraryCollectionsEditingNote()
      }
    }
  }

  @ViewBuilder
  private func section(
    _ kind: LibraryCollectionListKind, rows: [LibraryCollectionsBrowseModel.Row]
  ) -> some View {
    if rows.isEmpty == false {
      Section {
        ForEach(rows) { row in
          listRow(row)
            .editorialListRow()
        }
      } header: {
        Text(LibraryCollectionsPresentation.sectionTitle(for: kind))
      }
    }
  }

  /// No `.buttonStyle(.plain)`, as in the title and entity rows: the list's own style makes the
  /// whole row the hit area.
  private func listRow(_ row: LibraryCollectionsBrowseModel.Row) -> some View {
    Button {
      onSelect(row.id)
    } label: {
      ItemListRow(
        title: LibraryCollectionsPresentation.displayName(for: row.listing),
        author: LibraryCollectionsPresentation.subtitle(for: row)
      ) {
        Image(systemName: LibraryCollectionsPresentation.symbol(for: row.listing.key.kind))
          .font(.title3)
          .foregroundStyle(WhirrColorToken.brandInk.color)
          .frame(width: WhirrMetric.minimumTouchTarget, height: WhirrMetric.minimumTouchTarget)
          .background(
            WhirrColorToken.surfaceSecondary.color,
            in: RoundedRectangle(cornerRadius: WhirrSpacing.small)
          )
          .accessibilityHidden(true)
      } progress: {
        if row.isPinned {
          Image(systemName: LibraryCollectionsPresentation.pinnedSymbol)
            .font(WhirrTypeToken.caption.font)
            .foregroundStyle(WhirrColorToken.textSecondary.color)
            .accessibilityHidden(true)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(LibraryCollectionsPresentation.accessibilityLabel(for: row))
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier(LibraryAccessibilityID.collectionRow(row.id))
  }

  private var filteredEmptyState: some View {
    ContentUnavailableView {
      Label(
        "No Matching Collections",
        systemImage: FilterButtonPresentation.emptyStateSymbolName)
    } description: {
      Text("No collections or playlists hold anything matching your filters.")
    } actions: {
      Button(LibraryFilterCopy.clearFiltersLabel) { onClearFilters() }
        .accessibilityIdentifier(LibraryAccessibilityID.clearFiltersButton)
    }
  }

  private var queryEmptyState: some View {
    ContentUnavailableView {
      Label(
        LibraryBrowsePresentation.queryEmptyTitle(query: query),
        systemImage: LibraryBrowsePresentation.queryEmptySymbol)
    } description: {
      Text(LibraryBrowsePresentation.queryEmptyMessage)
    }
    .accessibilityIdentifier(LibraryAccessibilityID.queryEmptyState)
  }
}

/// The footer under the Library's Collections mode and under each list: these lists are read-only
/// in Whirr and edited in Audiobookshelf itself. A plain list row, so it scrolls with the content
/// it explains rather than claiming space on screen.
struct LibraryCollectionsEditingNote: View {
  var body: some View {
    Text(LibraryCollectionsPresentation.editingNote)
      .font(WhirrTypeToken.caption.font)
      .foregroundStyle(WhirrColorToken.textSecondary.color)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, WhirrSpacing.medium)
      .plainListRow(top: WhirrSpacing.medium, bottom: WhirrSpacing.large)
      .accessibilityIdentifier(LibraryAccessibilityID.collectionEditingNote)
  }
}
