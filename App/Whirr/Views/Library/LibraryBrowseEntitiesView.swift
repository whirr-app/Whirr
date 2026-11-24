import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// Entity rows share the title rows' section renderer, typography, separators and hit area. Each
/// is an entity joined to the items the filter matches (`LibraryEntityGrouping`), giving a count,
/// media-kind badges and cover (a series borrows its first book's; authors stack matched covers).
/// Compact rows only: the root owns the `List` and selects the regular grid.
struct LibraryBrowseEntitiesView: View {
  @Bindable var model: AuthorSeriesBrowseModel
  let coverClient: any ArtworkServing
  let query: String
  let onSelect: (LibraryEntityGroup) -> Void
  let onClearFilters: () -> Void

  private var entityNoun: String { AuthorSeriesBrowseCopy.entityNoun(for: model.kind) }

  var body: some View {
    let groups = LibraryQuickFilter.filter(groups: model.groups, query: query)

    switch LibraryBrowsePresentation.entityRowsPresentation(
      state: model.state,
      filters: model.filters,
      hasMore: model.hasMore,
      query: query,
      matchCount: groups.count
    ) {
    case .none:
      EmptyView()
    case .filteredEmpty:
      filteredEmptyState
        .editorialListRow()
    case .queryEmpty(let query, let offersClearFilters):
      queryEmptyState(query: query, offersClearFilters: offersClearFilters)
        .editorialListRow()
    case .rows:
      AlphabeticallyIndexedRows(items: groups, title: \.name) { group in
        entityRow(group)
      }
      if model.hasMore {
        ProgressView()
          .frame(maxWidth: .infinity)
          .listRowSeparator(.hidden)
          .editorialListRow()
          .onAppear { Task { await model.loadMore() } }
      }
    }
  }

  /// In the list rather than an overlay: it carries the button out of the empty state, and an
  /// overlay that dropped hit testing would take the button with it.
  private var filteredEmptyState: some View {
    ContentUnavailableView {
      Label(
        model.kind == .author ? "No Matching Authors" : "No Matching Series",
        systemImage: FilterButtonPresentation.emptyStateSymbolName)
    } description: {
      Text("No \(entityNoun) have anything matching your filters.")
    } actions: {
      Button(LibraryFilterCopy.clearFiltersLabel) { onClearFilters() }
        .accessibilityIdentifier(LibraryAccessibilityID.clearFiltersButton)
    }
  }

  /// An in-list row, like `filteredEmptyState`: `modeOverlay` drops hit testing and would put this
  /// recovery state under a live keyboard rather than beside the rows it replaces.
  private func queryEmptyState(query: String, offersClearFilters: Bool) -> some View {
    ContentUnavailableView {
      Label(
        LibraryBrowsePresentation.queryEmptyTitle(query: query),
        systemImage: LibraryBrowsePresentation.queryEmptySymbol)
    } description: {
      Text(LibraryBrowsePresentation.queryEmptyMessage)
    } actions: {
      if offersClearFilters {
        Button(LibraryFilterCopy.clearFiltersLabel) { onClearFilters() }
          .accessibilityIdentifier(LibraryAccessibilityID.clearFiltersButton)
      }
    }
    .accessibilityIdentifier(LibraryAccessibilityID.queryEmptyState)
  }

  /// No `.buttonStyle(.plain)`, as in the title rows: plain hit-tests only where the label draws,
  /// while the list's own button style makes the whole row tappable.
  ///
  /// The author card is neutral: a wash from one of the author's covers encodes nothing (whichever
  /// sorts first), and colour varying down an alphabetical index reads as a grouping the data
  /// lacks. Colour belongs on the author's own destination.
  @ViewBuilder
  private func entityRow(_ group: LibraryEntityGroup) -> some View {
    if group.kind == .author {
      Button {
        onSelect(group)
      } label: {
        LibraryAuthorCardLabel(group: group, coverClient: coverClient)
      }
      .editorialCardListRow(.neutral)
      .accessibilityLabel(LibraryBrowsePresentation.entityAccessibilityLabel(for: group))
    } else {
      Button {
        onSelect(group)
      } label: {
        ItemListRow(
          title: group.name,
          author: LibraryBrowsePresentation.entitySubtitle(for: group)
        ) {
          entityCover(group)
        } progress: {
          HStack(spacing: WhirrSpacing.xxSmall) {
            ForEach(group.categories, id: \.self) { category in
              MediaKindBadgeView(
                kind: HomeViewPresentation.badgeKind(for: category),
                label: HomeRowPresentation.badgeLabel(for: category))
            }
          }
        }
      }
      .accessibilityLabel(LibraryBrowsePresentation.entityAccessibilityLabel(for: group))
    }
  }

  @ViewBuilder
  private func entityCover(_ group: LibraryEntityGroup) -> some View {
    if group.kind == .series, let coverItemID = group.coverItemID {
      CoverImageView(
        itemID: coverItemID, title: group.name,
        displaySize: WhirrMetric.minimumTouchTarget, client: coverClient, source: nil,
        author: group.primaryAuthorName, revision: group.coverRevision)
    } else {
      Image(systemName: LibraryBrowsePresentation.entityPlaceholderSymbol(for: group.kind))
        .font(.title3)
        .foregroundStyle(WhirrColorToken.brandInk.color)
        .frame(width: WhirrMetric.minimumTouchTarget, height: WhirrMetric.minimumTouchTarget)
        .background(
          WhirrColorToken.surfaceSecondary.color,
          in: RoundedRectangle(cornerRadius: WhirrSpacing.small))
    }
  }

}

private enum LibraryEntityCoverStackMetrics {
  static let coverWidth: CGFloat = 34
  static let portraitAspectRatio: CGFloat = 1.5
  static let overlap: CGFloat = 12
  /// The gutter every row reserves, so the names share one leading edge down the list. Derived
  /// from the widest case (three covers).
  static let stackWidth: CGFloat = drawnWidth(forCoverCount: 3)
  static let stackHeight: CGFloat = coverWidth * portraitAspectRatio

  /// How much of that gutter a number of covers paints: each cover after the first adds only the
  /// sliver the one in front does not hide.
  static func drawnWidth(forCoverCount count: Int) -> CGFloat {
    guard count > 1 else { return coverWidth }
    return coverWidth + CGFloat(count - 1) * (coverWidth - overlap)
  }
}

private struct LibraryEntityCoverStack: View {
  let group: LibraryEntityGroup
  let coverClient: any ArtworkServing

  private var covers: [ItemSummary] { Array(group.items.prefix(3)) }

  /// What this row paints, narrower than the gutter unless it has three covers. Centred in the
  /// gutter so a lone cover does not leave a gap between itself and the name.
  private var drawnWidth: CGFloat {
    covers.isEmpty
      ? WhirrMetric.minimumTouchTarget
      : LibraryEntityCoverStackMetrics.drawnWidth(forCoverCount: covers.count)
  }

  var body: some View {
    ZStack(alignment: .leading) {
      if covers.isEmpty {
        Image(systemName: LibraryBrowsePresentation.entityPlaceholderSymbol(for: group.kind))
          .font(WhirrTypeToken.display.font)
          .foregroundStyle(WhirrColorToken.brandInk.color)
          .frame(width: WhirrMetric.minimumTouchTarget, height: WhirrMetric.minimumTouchTarget)
          .background(
            WhirrColorToken.surfaceSecondary.color,
            in: RoundedRectangle(cornerRadius: WhirrSpacing.small))
      } else {
        ForEach(Array(covers.enumerated()), id: \.element.id) { index, item in
          CoverImageView(
            itemID: item.serverItemId,
            title: item.title,
            displaySize: WhirrMetric.minimumTouchTarget,
            client: coverClient,
            source: nil,
            author: item.author,
            role: .libraryThumbnail,
            revision: item.artworkRevision
          )
          .frame(
            width: LibraryEntityCoverStackMetrics.coverWidth,
            height: LibraryEntityCoverStackMetrics.coverWidth
              * LibraryEntityCoverStackMetrics.portraitAspectRatio
          )
          .offset(
            x: CGFloat(index)
              * (LibraryEntityCoverStackMetrics.coverWidth - LibraryEntityCoverStackMetrics.overlap)
          )
          .zIndex(Double(covers.count - index))
        }
      }
    }
    // Two frames because the covers and the gutter differ in width. The inner one is what this row
    // paints, laid out from its leading edge so the stack still fans rightwards; the outer is the
    // fixed gutter.
    .frame(
      width: drawnWidth,
      height: LibraryEntityCoverStackMetrics.stackHeight,
      alignment: .leading
    )
    .frame(width: LibraryEntityCoverStackMetrics.stackWidth)
    .accessibilityHidden(true)
  }
}

/// Regular-width Library Authors reuse the compact rows' neutral card label. The label stays
/// private so its stacked-cover geometry is owned by this file; this factory exposes only the
/// opaque view the grid needs.
@ViewBuilder
func libraryAuthorCardLabel(
  group: LibraryEntityGroup,
  coverClient: any ArtworkServing
) -> some View {
  LibraryAuthorCardLabel(group: group, coverClient: coverClient)
}

private struct LibraryAuthorCardLabel: View {
  let group: LibraryEntityGroup
  let coverClient: any ArtworkServing

  var body: some View {
    HStack(alignment: .center, spacing: WhirrSpacing.small) {
      LibraryEntityCoverStack(group: group, coverClient: coverClient)

      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        Text(group.name)
          .font(WhirrTypeToken.headline.font)

        // The kinds share the count's line, not the name's: names can already run the card's width
        // ("Charlotte Perkins Gilman"), while the count is short and leaves its line free.
        HStack(alignment: .center, spacing: WhirrSpacing.xSmall) {
          if let subtitle = LibraryBrowsePresentation.entitySubtitle(for: group) {
            Text(subtitle)
              .font(WhirrTypeToken.caption.font)
              .foregroundStyle(WashInk.secondary)
          }

          // Pinned to the trailing edge, not the count: the count's length varies by row ("1 book"
          // against "5 books · 1 series"), and the kinds are scanned as a column.
          Spacer(minLength: 0)

          HStack(spacing: WhirrSpacing.xxSmall) {
            ForEach(group.categories, id: \.self) { category in
              MediaKindBadgeView(
                kind: HomeViewPresentation.badgeKind(for: category),
                label: HomeRowPresentation.badgeLabel(for: category))
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget, alignment: .leading)
  }
}

/// Shared by the entity rows and the root's overlay, which state the same noun in different
/// sentences and live in two different types.
enum AuthorSeriesBrowseCopy {
  static func entityNoun(for kind: SearchResultKind) -> String {
    kind == .author ? "authors" : "series"
  }
}
