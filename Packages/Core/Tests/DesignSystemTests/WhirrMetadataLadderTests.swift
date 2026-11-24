import DesignSystem
import Testing

/// The ladder value `ADR 0004` introduced, tested for the two things a surface relies on when it
/// chooses a ground the standard rungs cannot carry: the hierarchy survives the lift, and a page
/// that needs no lift pays nothing.
@Suite struct WhirrMetadataLadderTests {

  private static let rungs: [WhirrMetadataProminence] = [
    .primary, .secondary, .tertiary, .quaternary, .quinary,
  ]

  @Test("A floor at or below the standard one returns the standard rungs untouched")
  func noLiftIsANoOp() {
    for floor in [0.0, 0.3, WhirrMetadataProminence.floor] {
      let ladder = WhirrMetadataLadder.liftingFloor(to: floor)
      #expect(ladder == .standard)
      for rung in Self.rungs {
        #expect(ladder.opacity(for: rung) == rung.opacity, "\(rung) at floor \(floor)")
      }
    }
  }

  @Test("A lifted ladder starts at its floor and still ends at full strength")
  func theLiftAnchorsAtBothEnds() {
    for floor in [0.70, 0.75, 0.80, 0.9] {
      let ladder = WhirrMetadataLadder.liftingFloor(to: floor)
      #expect(abs(ladder.opacity(for: .quinary) - floor) < 1e-9, "floor \(floor)")
      #expect(ladder.opacity(for: .primary) == 1.0, "floor \(floor)")
    }
  }

  /// Why the map is affine rather than a clamp. `max(opacity, 0.80)` would print quinary,
  /// quaternary and tertiary in one colour: one shade, not a hierarchy with a dim bottom.
  @Test("Every rung stays distinct and in order under any lift")
  func theHierarchySurvivesTheLift() {
    for floor in stride(from: 0.65, through: 0.95, by: 0.05) {
      let ladder = WhirrMetadataLadder.liftingFloor(to: floor)
      for (dimmer, brighter) in zip(Self.rungs.dropFirst(), Self.rungs) {
        let low = ladder.opacity(for: dimmer)
        let high = ladder.opacity(for: brighter)
        #expect(low < high, "floor \(floor): \(dimmer) \(low) vs \(brighter) \(high)")
        #expect(low >= floor - 1e-9, "floor \(floor): \(dimmer) fell to \(low)")
      }
    }
  }

  /// The affine map preserves the ladder's shape: title-to-author is the widest break because the
  /// eye enters the block there, and a lift must not reorder it against the even steps below.
  @Test("The wide title-to-author break stays the widest gap under any lift")
  func theShapeIsPreserved() {
    for floor in [WhirrMetadataProminence.floor, 0.72, 0.80, 0.88] {
      let ladder = WhirrMetadataLadder.liftingFloor(to: floor)
      let gaps = zip(Self.rungs, Self.rungs.dropFirst()).map {
        ladder.opacity(for: $0) - ladder.opacity(for: $1)
      }
      #expect(gaps[0] > gaps[1] + 1e-9, "floor \(floor): gaps \(gaps)")
      for gap in gaps.dropFirst() {
        #expect(abs(gap - gaps[1]) < 1e-9, "floor \(floor): gaps \(gaps)")
      }
    }
  }

  @Test("A lift is capped at full opacity")
  func theLiftCannotExceedOne() {
    let ladder = WhirrMetadataLadder.liftingFloor(to: 1.4)
    #expect(ladder.floor == 1)
    for rung in Self.rungs {
      #expect(ladder.opacity(for: rung) == 1.0, "\(rung)")
    }
  }
}
