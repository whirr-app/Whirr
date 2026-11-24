import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Scrub session")
struct ScrubSessionTests {

  private static let trackWidth: CGFloat = 352

  private static func engaged(from startFraction: Double) -> ScrubSession {
    var session = ScrubSession(startFraction: startFraction)
    session.update(
      translation: CGSize(width: ScrubSession.engagementThreshold, height: 0), trackWidth: trackWidth)
    return session
  }

  // MARK: - Engagement

  @Test("a fresh session is disengaged and parked on the current position")
  func freshSessionIsDisengaged() {
    let session = ScrubSession(startFraction: 0.25)
    #expect(session.isEngaged == false)
    #expect(session.fraction == 0.25)
    #expect(session.speed == .full)
  }

  @Test("start fraction is clamped into 0...1")
  func startFractionIsClamped() {
    #expect(ScrubSession(startFraction: -3).fraction == 0)
    #expect(ScrubSession(startFraction: 4).fraction == 1)
    #expect(ScrubSession(startFraction: .nan).fraction == 0)
  }

  @Test("a horizontal drag under the engagement threshold never engages")
  func subThresholdDragDoesNotEngage() {
    var session = ScrubSession(startFraction: 0.25)
    session.update(
      translation: CGSize(width: ScrubSession.engagementThreshold - 1, height: 0),
      trackWidth: Self.trackWidth)
    #expect(session.isEngaged == false)
    #expect(session.fraction == 0.25)
  }

  @Test("a predominantly vertical drag never engages, however far it travels")
  func verticalDragDoesNotEngage() {
    var session = ScrubSession(startFraction: 0.25)
    for height in stride(from: 10.0, through: 200.0, by: 10.0) {
      session.update(translation: CGSize(width: 12, height: height), trackWidth: Self.trackWidth)
    }
    #expect(session.isEngaged == false)
    #expect(session.fraction == 0.25)
  }

  @Test("an ambiguous first sample is not treated as horizontal")
  func ambiguousSampleDoesNotEngage() {
    var session = ScrubSession(startFraction: 0.25)
    session.update(translation: CGSize(width: 12, height: 10), trackWidth: Self.trackWidth)
    #expect(session.isEngaged == false)
  }

  @Test("a scroll that drifts sideways mid-flick stays refused rather than becoming a scrub")
  func refusalIsLatched() {
    var session = ScrubSession(startFraction: 0.25)
    session.update(translation: CGSize(width: 4, height: 40), trackWidth: Self.trackWidth)
    #expect(session.isRefused)

    // Plainly horizontal travel, but the gesture was already given away as a scroll.
    session.update(translation: CGSize(width: 220, height: 44), trackWidth: Self.trackWidth)
    #expect(session.isEngaged == false)
    #expect(session.fraction == 0.25)
  }

  @Test("a scrub that begins with slight vertical drift still engages once it turns horizontal")
  func slightDriftStillEngages() {
    var session = ScrubSession(startFraction: 0.25)
    session.update(translation: CGSize(width: 3, height: 9), trackWidth: Self.trackWidth)
    #expect(session.isRefused == false)

    session.update(translation: CGSize(width: 40, height: 10), trackWidth: Self.trackWidth)
    #expect(session.isEngaged)
  }

  @Test("a drag past the threshold in the horizontal axis engages")
  func horizontalDragEngages() {
    var session = ScrubSession(startFraction: 0.25)
    session.update(
      translation: CGSize(width: ScrubSession.engagementThreshold, height: 3),
      trackWidth: Self.trackWidth)
    #expect(session.isEngaged)
  }

  @Test("engaging anchors at the threshold, so the playhead never lurches on pick-up")
  func engagementDoesNotLurch() {
    let session = Self.engaged(from: 0.25)
    #expect(session.isEngaged)
    #expect(abs(session.fraction - 0.25) < 1e-12)
  }

  @Test("once engaged, a later vertical excursion does not disengage")
  func engagementSurvivesVerticalExcursion() {
    var session = Self.engaged(from: 0.5)
    session.update(translation: CGSize(width: 10, height: 300), trackWidth: Self.trackWidth)
    #expect(session.isEngaged)
  }

  // MARK: - Relative movement

  @Test("movement is relative to the position at pick-up, not to where the finger landed")
  func movementIsRelativeToStartFraction() {
    var session = Self.engaged(from: 0.25)
    session.update(
      translation: CGSize(width: ScrubSession.engagementThreshold + Self.trackWidth / 2, height: 0),
      trackWidth: Self.trackWidth)
    #expect(abs(session.fraction - 0.75) < 1e-9)
  }

  @Test("dragging back toward the start moves the fraction down by the same ratio")
  func draggingBackwardMovesDown() {
    var session = Self.engaged(from: 0.75)
    session.update(
      translation: CGSize(width: ScrubSession.engagementThreshold - Self.trackWidth / 4, height: 0),
      trackWidth: Self.trackWidth)
    #expect(abs(session.fraction - 0.5) < 1e-9)
  }

  @Test("the fraction clamps to 0...1 however far the finger travels")
  func fractionClamps() {
    var forward = Self.engaged(from: 0.9)
    forward.update(translation: CGSize(width: 4000, height: 0), trackWidth: Self.trackWidth)
    #expect(forward.fraction == 1)

    var backward = Self.engaged(from: 0.1)
    backward.update(translation: CGSize(width: -4000, height: 0), trackWidth: Self.trackWidth)
    #expect(backward.fraction == 0)
  }

  @Test("a non-positive track width is inert rather than producing a NaN fraction")
  func nonPositiveTrackWidthIsInert() {
    var session = ScrubSession(startFraction: 0.4)
    session.update(translation: CGSize(width: 120, height: 0), trackWidth: 0)
    session.update(translation: CGSize(width: 120, height: 0), trackWidth: -10)
    #expect(session.isEngaged == false)
    #expect(session.fraction == 0.4)
  }

  // MARK: - Variable scrub speed

  @Test(
    "scrub speed steps down as the finger moves away from the track",
    arguments: [
      (0.0, ScrubSession.Speed.full),
      (49.0, ScrubSession.Speed.full),
      (50.0, ScrubSession.Speed.half),
      (99.0, ScrubSession.Speed.half),
      (100.0, ScrubSession.Speed.quarter),
      (159.0, ScrubSession.Speed.quarter),
      (160.0, ScrubSession.Speed.fine),
      (600.0, ScrubSession.Speed.fine),
    ])
  func speedStepsByVerticalDistance(verticalDistance: Double, expected: ScrubSession.Speed) {
    #expect(ScrubSession.speed(verticalDistance: CGFloat(verticalDistance)) == expected)
    #expect(ScrubSession.speed(verticalDistance: CGFloat(-verticalDistance)) == expected)
  }

  @Test("every speed multiplier is positive, and they descend from full to fine")
  func speedMultipliersDescend() {
    #expect(ScrubSession.Speed.full.multiplier == 1)
    let ordered = ScrubSession.Speed.allCases
    #expect(ordered == [.full, .half, .quarter, .fine])
    for (slower, faster) in zip(ordered.dropFirst(), ordered) {
      #expect(slower.multiplier > 0)
      #expect(slower.multiplier < faster.multiplier)
    }
  }

  @Test("a fine-speed drag covers a fraction of the distance a full-speed drag covers")
  func fineDragMovesLessThanFullDrag() {
    var full = Self.engaged(from: 0.5)
    full.update(
      translation: CGSize(width: ScrubSession.engagementThreshold + 100, height: 0),
      trackWidth: Self.trackWidth)

    var fine = Self.engaged(from: 0.5)
    fine.update(translation: CGSize(width: ScrubSession.engagementThreshold, height: 200), trackWidth: Self.trackWidth)
    fine.update(
      translation: CGSize(width: ScrubSession.engagementThreshold + 100, height: 200),
      trackWidth: Self.trackWidth)

    #expect(fine.speed == .fine)
    #expect(abs(full.fraction - 0.5) > abs(fine.fraction - 0.5))
    let expectedFine = 0.5 + (100 / Double(Self.trackWidth)) * ScrubSession.Speed.fine.multiplier
    #expect(abs(fine.fraction - expectedFine) < 1e-9)
  }

  @Test("crossing a speed band re-anchors, so the playhead does not jump under the finger")
  func speedChangeReAnchors() {
    var session = Self.engaged(from: 0.25)
    session.update(
      translation: CGSize(width: ScrubSession.engagementThreshold + 100, height: 0),
      trackWidth: Self.trackWidth)
    let beforeBandChange = session.fraction

    // Same horizontal travel, finger dropped into the half-speed band: the position must hold.
    session.update(
      translation: CGSize(width: ScrubSession.engagementThreshold + 100, height: 60),
      trackWidth: Self.trackWidth)
    #expect(session.speed == .half)
    #expect(abs(session.fraction - beforeBandChange) < 1e-12)

    // Travel made after the band change is scaled by the new speed only.
    session.update(
      translation: CGSize(width: ScrubSession.engagementThreshold + 200, height: 60),
      trackWidth: Self.trackWidth)
    let expected = beforeBandChange + (100 / Double(Self.trackWidth)) * ScrubSession.Speed.half.multiplier
    #expect(abs(session.fraction - expected) < 1e-9)
  }

  @Test("returning to the track restores full speed without moving the playhead")
  func returningToTrackRestoresFullSpeed() {
    var session = Self.engaged(from: 0.25)
    session.update(
      translation: CGSize(width: ScrubSession.engagementThreshold + 100, height: 200),
      trackWidth: Self.trackWidth)
    let awayFromTrack = session.fraction

    session.update(
      translation: CGSize(width: ScrubSession.engagementThreshold + 100, height: 0),
      trackWidth: Self.trackWidth)
    #expect(session.speed == .full)
    #expect(abs(session.fraction - awayFromTrack) < 1e-12)
  }
}
