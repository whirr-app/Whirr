import SwiftUI
import Testing

@testable import DesignSystem

/// `DesignTokenTests` assert the minimum-size constant, not that a control reserving it accepts a
/// tap across it. These cover the geometry that decides the hit region, including the label-only
/// controls that measured below the HIG minimum on device.
@Suite("Hit target geometry")
struct HitTargetGeometryTests {

  @Test("a short control grows symmetrically to the minimum")
  func shortControlGrowsSymmetrically() {
    // The expanded player's byline as measured on device: 250.2 x 23.2.
    let region = WhirrHitTargetGeometry.region(for: CGSize(width: 250.2, height: 23.2))

    #expect(region.height == WhirrMetric.minimumTouchTarget)
    #expect(region.width == 250.2)
    // Centred on the content, so the label does not drift inside its own target.
    #expect(region.midY == 23.2 / 2)
    #expect(region.minY == (23.2 - WhirrMetric.minimumTouchTarget) / 2)
  }

  @Test("a narrow control grows on the axis that falls short")
  func narrowControlGrowsOnTheShortAxis() {
    // The Library A-Z index rail: 20.2 wide, far past the minimum tall.
    let region = WhirrHitTargetGeometry.region(for: CGSize(width: 20.2, height: 605.2))

    #expect(region.width == WhirrMetric.minimumTouchTarget)
    #expect(region.height == 605.2)
  }

  @Test("a control already at the minimum is left exactly where it is")
  func passingControlIsUnchanged() {
    let size = CGSize(width: 120, height: WhirrMetric.minimumTouchTarget)
    let region = WhirrHitTargetGeometry.region(for: size)

    #expect(region == CGRect(origin: .zero, size: size))
  }

  @Test("the region never crops a control that already passes on both axes")
  func regionNeverCropsAPassingControl() {
    let size = CGSize(width: 320, height: 88)
    let region = WhirrHitTargetGeometry.region(for: size)

    #expect(region.width >= size.width)
    #expect(region.height >= size.height)
  }

  /// Controls measured on device, listed by size rather than name so the expectation survives a
  /// re-layout. The derived region must pass whatever the type measures.
  @Test(
    "every control P5 failed now derives a passing region",
    arguments: [
      CGSize(width: 20.2, height: 605.2),  // Library A-Z index rail
      CGSize(width: 125.7, height: 23.2),  // Item detail, Save for Later
      CGSize(width: 250.2, height: 23.2),  // Expanded player, byline
      CGSize(width: 151.6, height: 18.9),  // Podcast episode sheet, show name
    ])
  func everyFailingControlDerivesAPassingRegion(size: CGSize) {
    let region = WhirrHitTargetGeometry.region(for: size)

    #expect(region.width >= WhirrMetric.minimumTouchTarget)
    #expect(region.height >= WhirrMetric.minimumTouchTarget)
  }

  @Test("the shape places the region in the rect it is given, not at the origin")
  func shapePlacesRegionInTheProposedRect() {
    let shape = WhirrHitTargetShape()
    let rect = CGRect(x: 40, y: 100, width: 250.2, height: 23.2)

    let bounds = shape.path(in: rect).boundingRect

    #expect(bounds.height == WhirrMetric.minimumTouchTarget)
    #expect(bounds.midX == rect.midX)
    #expect(bounds.midY == rect.midY)
  }

  @Test("a custom minimum is honoured over the default")
  func customMinimumIsHonoured() {
    let region = WhirrHitTargetGeometry.region(for: CGSize(width: 10, height: 10), minimum: 60)

    #expect(region.width == 60)
    #expect(region.height == 60)
  }
}
