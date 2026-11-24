import ABSApi
import DesignSystem
import PlayerCore
import SwiftUI

/// Pure cover arithmetic shared by the expanded-player metrics and its regular-width resolver.
/// Keeping this helper outside the `View` extension lets the resolver remain nonisolated while the
/// existing `ExpandedPlayerView` static surface and compact equations stay where callers expect.
nonisolated enum ExpandedPlayerViewMetrics {
  static func clampedCoverSize(
    preferredSize: CGFloat,
    availableWidth: CGFloat,
    minimumSize: CGFloat,
    maximumSize: CGFloat
  ) -> CGFloat {
    let lowerBound = max(0, min(minimumSize, maximumSize))
    let upperBound = max(lowerBound, maximumSize.isFinite ? maximumSize : lowerBound)
    let width = availableWidth.isFinite ? max(0, availableWidth) : 0
    let preferred = preferredSize.isFinite ? max(0, preferredSize) : upperBound
    return max(lowerBound, min(upperBound, min(preferred, width)))
  }
}

/// The type's static surface: cover-geometry constants and page layout resolution, plus
/// the small formatting and timing constants its leaves read by name.
extension ExpandedPlayerView {
  /// The compact-width artwork cap, and the high-fidelity request rung on a phone. A phone renders
  /// only the compact layout, so the largest cover it can draw is also the largest worth fetching.
  /// An iPad requests the larger regular cap instead; see `artworkRequestSize(forIdiom:)`.
  nonisolated static let maximumCoverSize: CGFloat = 380

  /// The smallest cover the page will draw. Below this the artwork stops reading as the subject of
  /// the screen, so a page that cannot fit its content around this cover scrolls instead of
  /// shrinking past it.
  static let minimumCoverSize: CGFloat = 210

  /// The cover's height-relative ceiling makes its size a function of the screen rather than the
  /// item. A podcast and a chaptered audiobook therefore resolve the same cover, with the chapter
  /// row's height coming out of the surrounding slack instead of out of the artwork.
  static let coverHeightShare: CGFloat = 0.70

  /// The share of slack kept above the cover. The remainder does not stay where a top-aligned
  /// column would leave it; see `upperLayout`.
  static let upperTopSlackShare: CGFloat = 0.3

  /// The key the page's palette is derived under: the high-fidelity cover it draws, so a cold
  /// open waits on that cover's own fetch (a visible palette request, no transfer of its own).
  /// That cover can stand in for the home card, which the mini-player's thumbnail cannot.
  static func paletteArtworkKey(
    itemID: String, coverClient: any ArtworkServing, source: ArtworkSource?,
    displayScale: CGFloat, revision: ArtworkRevision
  ) -> ArtworkKey {
    CoverPaletteService.artworkKey(
      itemID: itemID, coverClient: coverClient, source: source,
      displaySize: artworkRequestSize, displayScale: displayScale, role: .highFidelity,
      revision: revision)
  }

  /// A ceiling on the top slack keeps a tall region from turning the space above the cover into a
  /// second void. Slack past this ceiling goes to the cover/metadata seam instead.
  static let upperTopSlackCap: CGFloat = 40

  /// The display size every high-fidelity request for the playing item is keyed on: the device's
  /// artwork cap, not the size `coverSize` resolves. `displaySize` feeds only the cache key and
  /// decode target (the call site applies its own `.frame`), so the cap costs layout nothing.
  /// `NowPlayingMetadataAdapter` resolves the same rung, so this view and the lock screen share
  /// one `CoverRequest.quantizedWidth` entry.
  ///
  /// Scoped by idiom, not size class. A phone never draws above the 380pt compact cap, so 620pt
  /// would double its fetch and decode and push it off the 2x entry shared with item detail. An
  /// iPad keeps 620pt at every width: a narrow Slide Over can be resized back at any moment, and
  /// a size-class rung would refetch.
  nonisolated static func artworkRequestSize(forIdiom idiom: UIUserInterfaceIdiom) -> CGFloat {
    idiom == .pad ? ExpandedPlayerLayoutPresentation.regularArtworkMaximumSize : maximumCoverSize
  }

  /// The rung for the device this process is running on. `userInterfaceIdiom` is fixed for the
  /// lifetime of the process, so unlike `displayScale` there is nothing here to observe or inject.
  static var artworkRequestSize: CGFloat {
    artworkRequestSize(forIdiom: UIDevice.current.userInterfaceIdiom)
  }

  /// The compact page's side inset: the design gap on a phone, and whatever centres a 560pt column
  /// on a wider compact page. The upper content and the chrome share it, so the scrubber's ends
  /// line up with the cover's edges on every compact width.
  static func horizontalPadding(availableWidth: CGFloat) -> CGFloat {
    max(WhirrSpacing.large, (availableWidth - 560) / 2)
  }

  /// A first-frame seed for the metadata band, superseded within one layout pass by the real
  /// `onGeometryChange` reading, never a reservation. Title and byline measure around 50pt at
  /// ordinary Dynamic Type and a chapter row adds roughly 44, so the seed is wrong by tens of
  /// points for one frame; seeding the cover from a height ratio would open at `minimumCoverSize`
  /// and visibly settle upward.
  static let upperContentHeightSeed: CGFloat = 72

  /// Resolves the cover and the room around it from the upper region's geometry; the metadata band
  /// stays a fallback clamp for overflow. Every point of slack is spent, the seam taking what the
  /// top inset does not, since the top-aligned column would otherwise leave a void above the
  /// chrome (a chapterless podcast has a shorter band, so more slack). Dependency runs one way
  /// (cover from band and region, slack from cover, seam from slack) so layout settles in one pass.
  static func upperLayout(availableWidth: CGFloat, height: CGFloat, upperContentHeight: CGFloat)
    -> (coverSize: CGFloat, topInset: CGFloat, coverToMetadataSpacing: CGFloat)
  {
    let band = upperContentHeight > 0 ? upperContentHeight : upperContentHeightSeed
    let availableCoverWidth = availableWidth - (horizontalPadding(availableWidth: availableWidth) * 2)
    let coverSize = max(
      minimumCoverSize,
      min(
        availableCoverWidth,
        maximumCoverSize,
        coverHeightShare * height,
        height - WhirrSpacing.large - band
      )
    )
    let slack = max(0, height - coverSize - WhirrSpacing.large - band)
    let topInset = min(slack * upperTopSlackShare, upperTopSlackCap)
    return (
      coverSize: coverSize,
      topInset: topInset,
      coverToMetadataSpacing: WhirrSpacing.large + (slack - topInset)
    )
  }

  /// The on-screen cover edge within the flexible upper region. `height` is that region's own
  /// available height, while `upperContentHeight` is only the measured metadata band and status
  /// banner; zero means the first layout pass has not reported yet and the seed above stands in.
  /// The gap above the band is the only fixed reservation. The chrome is laid out outside this
  /// calculation, and the scroll content carries no bottom inset of its own.
  static func coverSize(availableWidth: CGFloat, height: CGFloat, upperContentHeight: CGFloat)
    -> CGFloat
  {
    upperLayout(
      availableWidth: availableWidth, height: height, upperContentHeight: upperContentHeight
    ).coverSize
  }

  /// Which container edges the page spends: only the bottom, and not at accessibility Dynamic
  /// Type, where the chrome is taller (`quickActionMinHeight` 72, labels wrap) so crowding the
  /// home indicator matters and the whole inset goes back. The modifier's argument, not a branch,
  /// so a Dynamic Type change keeps view identity. A `GeometryProxy` ignoring an edge reports zero
  /// for it, so spending part of an inset would need a second feedback reader: ignore the edge or
  /// don't; `chromeBottomClearance` reads from whichever bottom results.
  static func ignoredContainerEdges(isAccessibilitySize: Bool) -> Edge.Set {
    isAccessibilitySize ? [] : .bottom
  }

  static let bufferingBannerDelay: Double = 1.0

  /// Names the reduced scrub resolutions, so the vertical precision gesture is discoverable at the
  /// moment it engages. Full speed is unlabelled.
  static func precisionLabel(_ speed: ScrubSession.Speed) -> String? {
    switch speed {
    case .full: return nil
    case .half: return "HALF-SPEED"
    case .quarter: return "QUARTER-SPEED"
    case .fine: return "FINE"
    }
  }

  static func displayRate(_ rate: Double) -> String {
    PlaybackRatePresetConfiguration.display(rate)
  }
}
