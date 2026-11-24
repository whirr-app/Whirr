import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// The funnel's glyphs. Only the two dimensions that picture something concrete have them.
///
/// As in Files' overflow menu, action rows and the Icons/List picker carry a glyph; the sort
/// picker and playback state don't (an attribute, and no honest picture of "Any").
enum BrowseFilterMenuPresentation {
  /// Routed through `MediaKindBadge` so the menu glyph is the same one badged onto the rows behind
  /// it, rather than a second vocabulary.
  static func mediaSymbolName(for filter: MediaFilter) -> String? {
    filter.category.map { HomeViewPresentation.badgeKind(for: $0).symbolName }
  }

  /// The same glyph every download command in the app already draws.
  static let downloadedSymbolName = "arrow.down.circle"

  /// What the funnel reports as engaged. In the Library's Collections mode only the media kinds
  /// narrow anything, so the other two dimensions are not counted: a badge for a filter that does
  /// nothing would wrongly say the list is narrowed.
  static func displayedFilters(_ filters: BrowseFilters, appliesCategoriesOnly: Bool) -> BrowseFilters {
    appliesCategoriesOnly ? BrowseFilters(categories: filters.categories) : filters
  }
}

/// The filter funnel, the single declaration of its rows for every screen that filters.
///
/// One generic view over `BrowseFiltering`, so the Library and Search cannot drift apart.
///
/// Rows are real system controls (`Toggle`s and a `Picker`, per `FilterButton`), so checkmarks,
/// glass and Dynamic Type come from UIKit. Media kinds are additive toggles, and
/// `menuActionDismissBehavior` lets several be picked in one visit. Rows commit on tap; Apply
/// Filters stages nothing and only dismisses, since tapping outside read as a cancel.
struct BrowseFilterMenu<Model: BrowseFiltering>: View {
  let model: Model
  /// True in the Library's Collections mode: the Downloaded and playback rows are shown disabled,
  /// and only the media kinds count as engaged.
  var appliesCategoriesOnly = false

  private var displayedFilters: BrowseFilters {
    BrowseFilterMenuPresentation.displayedFilters(
      model.filters, appliesCategoriesOnly: appliesCategoriesOnly)
  }

  /// The media dimension's rows. `.all` is absent: no kind selected already means All.
  private static var mediaFilters: [MediaFilter] { MediaFilter.allCases.filter { $0 != .all } }

  var body: some View {
    FilterButton(
      accessibilityLabel: LibraryFilterCopy.activeSummary(for: displayedFilters),
      isActive: displayedFilters.isActive
    ) {
      Section(MediaFilterCopy.title) {
        ForEach(Self.mediaFilters, id: \.self) { filter in
          if let category = filter.category {
            Toggle(
              isOn: Binding(
                get: { model.isMediaCategorySelected(category) },
                set: { model.setMediaCategory(category, isOn: $0) })
            ) {
              if let symbolName = BrowseFilterMenuPresentation.mediaSymbolName(for: filter) {
                Label(LibraryFilterCopy.mediaLabel(for: filter), systemImage: symbolName)
              } else {
                Text(LibraryFilterCopy.mediaLabel(for: filter))
              }
            }
            .menuActionDismissBehavior(.disabled)
          }
        }
      }

      Section {
        Toggle(
          isOn: Binding(get: { model.filters.downloadedOnly }, set: { model.updateDownloadedOnly($0) })
        ) {
          Label(
            LibraryFilterCopy.downloadedTitle,
            systemImage: BrowseFilterMenuPresentation.downloadedSymbolName)
        }
        .menuActionDismissBehavior(.disabled)
        .disabled(appliesCategoriesOnly)
      }

      // A submenu for height: a UIKit menu scrolls whatever does not fit between its anchor and the
      // screen edge, and inline rows pushed Clear All Filters below the fold. The submenu row
      // carries the dimension's name (an inline `Picker` in a `Menu` draws no label), and
      // `playbackMenuLabel` names the engaged state the collapsed row would hide.
      Section {
        Menu(LibraryFilterCopy.playbackMenuLabel(for: model.filters.playback)) {
          Picker(
            LibraryFilterCopy.playbackTitle,
            selection: Binding(get: { model.filters.playback }, set: { model.updatePlayback($0) })
          ) {
            ForEach(PlaybackFilter.allCases, id: \.self) { playback in
              Text(LibraryFilterCopy.playbackLabel(for: playback)).tag(playback)
            }
          }
          .pickerStyle(.inline)
        }
        .disabled(appliesCategoriesOnly)
      }

      Section {
        // Nothing to commit, the rows already did. The default dismiss behaviour closes the menu.
        Button(LibraryFilterCopy.applyFiltersLabel) {}
          .accessibilityIdentifier(LibraryAccessibilityID.applyFiltersButton)
      }

      Section {
        Button(LibraryFilterCopy.clearAllFiltersLabel, role: .destructive) {
          model.clearFilters()
        }
        .disabled(displayedFilters.isActive == false)
      }
    }
    .accessibilityIdentifier(LibraryAccessibilityID.filterButton)
  }
}
