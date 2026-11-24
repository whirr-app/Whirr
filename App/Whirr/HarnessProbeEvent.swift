import DesignSystem
import Foundation
import QuartzCore
import SwiftUI

/// Named app-owned events the debug scroll probe attributes run-loop turns to.
///
/// The enum itself is unconditional so instrumented call sites read the same in both
/// configurations; the recording behind `note` exists only in DEBUG, and the release build
/// inlines `harnessNote` away to nothing.
enum HarnessProbeEvent: Int, CaseIterable {
  case shelfCardAppear
  case prefetchObserve
  case washRequestVisible
  case washRequestBulk
  case washRequestedItems
  case washPublish
  case washPublishedItems
  case coverBody
  case scrollPhaseChange
  case miniPlayerModelTask
  case playbackPeriodicPosition

  var label: String {
    switch self {
    case .shelfCardAppear: "cardAppear"
    case .prefetchObserve: "prefetch"
    case .washRequestVisible: "washVisible"
    case .washRequestBulk: "washBulk"
    case .washRequestedItems: "washItems"
    case .washPublish: "washPublish"
    case .washPublishedItems: "washPublished"
    case .coverBody: "coverBody"
    case .scrollPhaseChange: "scrollPhase"
    case .miniPlayerModelTask: "miniModelTask"
    case .playbackPeriodicPosition: "playback.periodicPosition"
    }
  }
}

@inline(__always)
@MainActor
func harnessNote(_ event: HarnessProbeEvent, _ count: Int = 1) {
  #if DEBUG
    HarnessScrollProbe.shared.note(event, count)
  #elseif PERF_INVESTIGATION
    MicrostutterProbe.shared.note(event.label, count: count)
  #endif
}

/// Times a named span rather than a `HarnessProbeEvent` case, so one view's body can be split into
/// several spans. A bare count cannot tell whether a run-loop turn went into the tile's body or
/// SwiftUI's graph work after it.
@inline(__always)
@MainActor
func harnessTimedSpan<Value>(_ name: String, _ body: () -> Value) -> Value {
  #if PERF_INVESTIGATION
    let start = CACurrentMediaTime()
    let value = body()
    MicrostutterProbe.shared.note(name, elapsed: CACurrentMediaTime() - start)
    return value
  #else
    return body()
  #endif
}

/// Ablation switches as plain booleans in both configurations: a `#if DEBUG` block cannot open a
/// brace in one branch and close it in another, so call sites can't gate on `HarnessAblation`
/// directly. Release folds these to `false`.
enum HarnessSwitch {
  @inline(__always) static var skipsShelfPrefetch: Bool {
    #if DEBUG || PERF_INVESTIGATION
      HarnessAblation.noShelfPrefetch
    #else
      false
    #endif
  }

  @inline(__always) static var skipsVisibleWashRequest: Bool {
    #if DEBUG || PERF_INVESTIGATION
      HarnessAblation.noVisibleWashRequest
    #else
      false
    #endif
  }

  @inline(__always) static var skipsBulkWashRequest: Bool {
    #if DEBUG || PERF_INVESTIGATION
      HarnessAblation.noBulkWashRequest
    #else
      false
    #endif
  }

  @inline(__always) static var skipsWashPublication: Bool {
    #if DEBUG || PERF_INVESTIGATION
      HarnessAblation.noWashPublication
    #else
      false
    #endif
  }

  @inline(__always) static var skipsTileAccessibility: Bool {
    #if DEBUG || PERF_INVESTIGATION
      HarnessAblation.noTileAccessibility
    #else
      false
    #endif
  }

  @inline(__always) static var skipsZoomTransitionSource: Bool {
    #if DEBUG || PERF_INVESTIGATION
      HarnessAblation.noZoomTransitionSource
    #else
      false
    #endif
  }

  /// Returns a height for the Library title tile, or nil for the shipping behaviour. A value
  /// rather than a conditional modifier: `.frame(width:height:alignment:)` already accepts an
  /// optional height, so both arms build the identical view tree and only the measured height
  /// differs. A conditional modifier would change the tree and make the arm the thing measured.
  @inline(__always) static func pinnedTileHeight(tileWidth: CGFloat) -> CGFloat? {
    #if DEBUG || PERF_INVESTIGATION
      HarnessAblation.pinTileHeight ? tileWidth + 128 : nil
    #else
      nil
    #endif
  }

  /// Marks are a value, like the pinned height: `.none` keeps the overlay in the tree and only
  /// draws nothing into it.
  @inline(__always) static func coverMarks(_ marks: CoverArtworkMarks) -> CoverArtworkMarks {
    #if DEBUG || PERF_INVESTIGATION
      HarnessAblation.noCoverMarks ? .none : marks
    #else
      marks
    #endif
  }

  @inline(__always) static var skipsCoverOuterClip: Bool {
    #if DEBUG || PERF_INVESTIGATION
      HarnessAblation.noCoverOuterClip
    #else
      false
    #endif
  }

  @inline(__always) static var usesSwiftUILibraryGrid: Bool {
    #if DEBUG || PERF_INVESTIGATION
      HarnessAblation.swiftUILibraryGrid
    #else
      false
    #endif
  }

  @inline(__always) static var usesFloorTile: Bool {
    #if DEBUG || PERF_INVESTIGATION
      HarnessAblation.floorTile
    #else
      false
    #endif
  }

  @inline(__always) static var skipsScrollPhaseTracking: Bool {
    #if DEBUG || PERF_INVESTIGATION
      HarnessAblation.noScrollPhaseTracking
    #else
      false
    #endif
  }
}

extension View {
  /// Applies `transform` unless an ablation switch removes it, so a device sweep can price one
  /// per-tile modifier. Defined twice: an `if`/`else` in a `@ViewBuilder` is a compile-time
  /// `buildEither`, so one definition would leave `_ConditionalContent` in release, an extra node
  /// per ablatable modifier (three per Library tile).
  #if DEBUG || PERF_INVESTIGATION
    @ViewBuilder
    func ablatable<Transformed: View>(
      _ isAblated: Bool, _ transform: (Self) -> Transformed
    ) -> some View {
      if isAblated { self } else { transform(self) }
    }
  #else
    @inline(__always)
    func ablatable<Transformed: View>(
      _ isAblated: Bool, _ transform: (Self) -> Transformed
    ) -> Transformed {
      transform(self)
    }
  #endif
}
