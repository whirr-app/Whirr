#if DEBUG || PERF_INVESTIGATION
  import Foundation

  /// Debug-only, environment-driven ablation switches for the scroll investigation.
  /// Every flag is a `static let` so the environment dictionary is materialised once.
  /// `ProcessInfo.environment` rebuilds a whole `[String: String]` from `environ` on every access;
  /// read from a view body, that costs more per row than the work these flags measure and would
  /// show up as the very stall being hunted. Never compiled into release builds.
  enum HarnessAblation {
    private static let environment = ProcessInfo.processInfo.environment
    private static func isOn(_ key: String) -> Bool { environment[key] == "1" }

    /// Moved here so it does not rebuild the environment per row.
    static let noContextMenus = isOn("WHIRR_UI_HARNESS_NO_CONTEXT_MENUS")

    /// Shelf appearance observers. Both clean-room A/Bs held these constant, so no device
    /// evidence has varied them.
    static let noShelfPrefetch = isOn("WHIRR_ABLATE_PREFETCH")
    static let noBulkWashRequest = isOn("WHIRR_ABLATE_BULK_WASH")
    static let noVisibleWashRequest = isOn("WHIRR_ABLATE_VISIBLE_WASH")

    /// Wash publication and the scroll-phase plumbing that defers it.
    static let noWashPublication = isOn("WHIRR_ABLATE_WASH_PUBLISH")
    static let noScrollPhaseTracking = isOn("WHIRR_ABLATE_SCROLL_PHASE")

    /// Home's shelf-retirement animation, applied to the scroll view rather than its content.
    /// It is the one modifier Home's scroll view carries that Your Shows' does not.
    static let noHomeAnimation = isOn("WHIRR_ABLATE_HOME_ANIMATION")

    /// Per-tile modifiers in the Library grid. Tile construction priced at 1.4 ms with every
    /// counter at the same enrichment, so no subview stands out and contributors are removed one
    /// at a time.
    static let noTileAccessibility = isOn("WHIRR_ABLATE_TILE_A11Y")
    static let noZoomTransitionSource = isOn("WHIRR_ABLATE_ZOOM_SOURCE")

    /// Replaces the Library title tile with the cheapest one still showing a cover and two text
    /// lines (no button, menu, accessibility element, zoom source or crossfade): a floor, not a
    /// proposal.
    static let floorTile = isOn("WHIRR_ABLATE_TILE_FLOOR")

    /// Pins the title tile to a fixed height. The device profile attributes 39% of the control's
    /// stalling main-thread time to `LazySubviewPlacements` measuring subviews, which a grid with
    /// content-derived heights does per tile. Overrun overflows: this prices measurement, not
    /// layout.
    static let pinTileHeight = isOn("WHIRR_ABLATE_TILE_PINNED_HEIGHT")

    /// Restores the SwiftUI regular-width Library grid (`ScrollView` → `LazyVStack` →
    /// `LazyVGrid`) in place of the collection-view host, for A/B/A runs on one frozen binary.
    static let swiftUILibraryGrid = isOn("WHIRR_ABLATE_SWIFTUI_LIBRARY_GRID")

    /// Card content held constant by geometry: the cover is replaced by a same-sized fill.
    static let noCoverArtwork = isOn("WHIRR_ABLATE_COVER")

    /// The pieces of a cover, one at a time, with the artwork kept. Removing the whole cover took
    /// every offscreen pass a Library tile owns with it; inside the cover only the corner marks'
    /// material discs and the clip around them can make one per tile.
    static let noCoverMarks = isOn("WHIRR_ABLATE_COVER_MARKS")
    static let noCoverOuterClip = isOn("WHIRR_ABLATE_COVER_OUTER_CLIP")
    static let noSwipeActions = isOn("WHIRR_ABLATE_SWIPES")

    /// Fixture volume. The stock harness gives each shelf a handful of cards; a real library
    /// fills every shelf to `HomeModel`'s 20-item cap and the latest-episodes shelf toward
    /// `HomeMoreModel`'s 100. Cost quadratic in shelf length is invisible at seven cards.
    nonisolated static let fixtureScale: Int =
      environment["WHIRR_UI_HARNESS_SCALE"].flatMap(Int.init) ?? 1
  }
#endif
