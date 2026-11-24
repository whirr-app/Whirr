import SwiftUI

/// The filter funnel's glyph, as a non-generic type so any caller can reach it without naming
/// `FilterButton`'s `Content` specialization (Search needs this), and one source for the glyph
/// names on both screens.
public enum FilterButtonPresentation {
  /// The toolbar funnel uses SF Symbols' matched outline/fill pair for its selection state.
  ///
  /// The state has to live in the glyph: the `Menu` stays the same native toolbar item throughout
  /// so iOS can morph its Liquid Glass surface into the menu and back. Styling only the active
  /// branch as a button creates a second, squarer surface and changes the transition's geometry.
  public static func symbolName(isActive: Bool) -> String {
    isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
  }

  /// An enclosed symbol spends more of its bounds on context than a bare toolbar glyph. Large is
  /// SF Symbols' semantic scale for correcting that optical difference without fixing a point size
  /// or changing the toolbar's system-owned hit target.
  public static let imageScale: Image.Scale = .large

  /// The funnel an empty state pictures, which stays enclosed. A `ContentUnavailableView` draws it
  /// large and captioned, where the ring costs no legibility, and it is paired there with
  /// `PodcastShowListCopy.noMatchingEpisodesSystemImage` picturing the same fact. The toolbar
  /// uniformity reasoning above does not apply.
  public static let emptyStateSymbolName = "line.3.horizontal.decrease.circle"
}

/// A toolbar filter funnel: a `Menu` whose rows the caller supplies, labelled by the shared funnel
/// glyph. Mounted in `topBarTrailing`, it is reachable at any scroll offset, which an in-list
/// control is not.
///
/// Like `MediaFilterPicker`, it takes finished strings, not a filter type: this target imports no
/// `AppModel` (see ARCHITECTURE.md). It knows only whether a filter is on.
///
/// Two constraints:
/// - Menu rows only: `Toggle`s and inline `Picker`s. Never a segmented control inside a `Menu`
///   (a palette-`ControlGroup` mistake that made the playback-speed menu slow and forced it into
///   a sheet). If the control outgrows a menu it becomes a sheet.
/// - No surface styling: a `topBarTrailing` toolbar menu gets iOS 26's glass treatment and
///   presentation morph from the system, so this file carries no button style, `.glassEffect`,
///   material, colour or fixed frame.
public struct FilterButton<Content: View>: View {
  public let accessibilityLabel: String
  public let isActive: Bool
  private let content: Content

  public init(
    accessibilityLabel: String,
    isActive: Bool,
    @ViewBuilder content: () -> Content
  ) {
    self.accessibilityLabel = accessibilityLabel
    self.isActive = isActive
    self.content = content()
  }

  public var symbolName: String { FilterButtonPresentation.symbolName(isActive: isActive) }

  public var body: some View {
    Menu {
      content
    } label: {
      Label(accessibilityLabel, systemImage: symbolName)
        .imageScale(FilterButtonPresentation.imageScale)
    }
    .labelStyle(.iconOnly)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityAddTraits(isActive ? .isSelected : [])
  }
}
