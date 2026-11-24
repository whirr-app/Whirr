import DesignSystem
import SwiftUI

#if PERF_INVESTIGATION
  import QuartzCore
#endif

/// The compact native `List` owns the rail, its scrub interaction, and selection feedback for every
/// Library mode. Empty sections are kept: they are how SwiftUI receives the complete A-Z index
/// without a custom overlay. Regular width uses `LibraryBrowseAlphabetJumpMenu` instead.
struct AlphabeticallyIndexedRows<Item: Identifiable, Row: View>: View {
  let items: [Item]
  let title: (Item) -> String
  let row: (Item) -> Row

  init(
    items: [Item],
    title: @escaping (Item) -> String,
    @ViewBuilder row: @escaping (Item) -> Row
  ) {
    self.items = items
    self.title = title
    self.row = row
  }

  var body: some View {
    ForEach(indexedSections) { section in
      Section {
        ForEach(section.items) { item in
          row(item)
            .editorialListRow()
        }
      } header: {
        if section.items.isEmpty == false {
          Text(section.id)
        }
      }
      .sectionIndexLabel(Text(section.id))
    }
  }

  private var indexedSections: [LibraryBrowsePresentation.Section<Item>] {
    #if PERF_INVESTIGATION
      let started = CACurrentMediaTime()
      let sections = LibraryBrowsePresentation.indexedSections(for: items, title: title)
      MicrostutterProbe.shared.note(
        "Library.indexedSections", count: items.count, elapsed: CACurrentMediaTime() - started)
      return sections
    #else
      LibraryBrowsePresentation.indexedSections(for: items, title: title)
    #endif
  }
}

private struct LibraryIndexedListStyle: ViewModifier {
  let sectionIndexVisibility: Visibility
  let isSelecting: Bool

  func body(content: Content) -> some View {
    content
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(WhirrColorToken.editorialBackground.color.ignoresSafeArea())
      .listSectionIndexVisibility(sectionIndexVisibility)
      .primaryScrollEdgeEffect(isSelecting: isSelecting)
  }
}

extension View {
  func libraryIndexedListStyle(
    sectionIndexVisibility: Visibility, isSelecting: Bool = false
  ) -> some View {
    modifier(
      LibraryIndexedListStyle(
        sectionIndexVisibility: sectionIndexVisibility, isSelecting: isSelecting))
  }

  /// Lets the page background through a row instead of the plain `List`'s own cell fill.
  ///
  /// `scrollContentBackground(.hidden)` leaves each cell's fill, which falls back to
  /// `systemBackground` (pure black against this page's `#0B0D0E`, pure white in light). Rows using
  /// `plainListRow` already clear it; these keep default separators and insets, so need this alone.
  func editorialListRow() -> some View {
    listRowBackground(Color.clear)
  }
}
