import SwiftUI

/// The arithmetic behind one `PlaybackScrubber` drag, as a plain value so it is unit-tested rather
/// than buried in a `Gesture` body: axis gating, relative (pick-up-the-playhead) movement, and
/// variable scrub speed.
///
/// All three exist because a ten-hour book across ~350 points is roughly 100 seconds per point:
/// absolute seeking means a brushed finger or a page scroll starting on the track throws the
/// listener hours off, and even a careful drag can't land inside the right minute.
public struct ScrubSession: Sendable, Equatable {

  /// How far a drag must travel horizontally before it counts as scrubbing. Below this the session
  /// stays inert, so a bare tap on the track never seeks.
  public static let engagementThreshold: CGFloat = 8

  /// Vertical travel that gives a still-disengaged drag away as a page scroll. Past this the
  /// session refuses the gesture permanently, so a downward drag from the track scrolls the page.
  /// Looser than `engagementThreshold` so a scrub with a little vertical drift still takes.
  public static let refusalThreshold: CGFloat = 12

  /// How much longer the horizontal component must be than the vertical one for a drag to read as
  /// a scrub. A bare `>` treats a 12-by-10 sample as horizontal, which is ambiguous, and on this
  /// track guessing wrong costs hours of position.
  public static let dominanceRatio: CGFloat = 1.5

  /// Scrub resolution, selected by how far the finger has strayed from the track (the vertical
  /// precision gesture the system media scrubbers use).
  public enum Speed: Sendable, Equatable, CaseIterable {
    case full
    case half
    case quarter
    case fine

    /// Track-fraction moved per unit of finger travel.
    public var multiplier: Double {
      switch self {
      case .full: return 1
      case .half: return 0.5
      case .quarter: return 0.25
      case .fine: return 0.1
      }
    }
  }

  public static func speed(verticalDistance: CGFloat) -> Speed {
    switch abs(verticalDistance) {
    case ..<50: return .full
    case ..<100: return .half
    case ..<160: return .quarter
    default: return .fine
    }
  }

  /// Position under the finger, `0...1`. Equal to the pick-up position until the drag engages.
  public private(set) var fraction: Double
  public private(set) var speed: Speed = .full
  /// False until the drag has proved itself horizontal and past `engagementThreshold`. A session
  /// that ends still disengaged must not seek.
  public private(set) var isEngaged = false
  /// Latched once a still-disengaged drag has travelled vertically past `refusalThreshold`. Without
  /// the latch a scroll that drifts sideways mid-flick can still cross into scrubbing halfway down
  /// the screen, which is how a page scroll ends up seeking.
  public private(set) var isRefused = false

  /// Position and total translation at the last point movement started being counted. Reset on
  /// engagement and on every speed change, so a multiplier only applies to travel made at that
  /// speed.
  private var anchorFraction: Double
  private var anchorTranslationWidth: CGFloat = 0

  public init(startFraction: Double) {
    let clamped = startFraction.isFinite ? min(max(startFraction, 0), 1) : 0
    fraction = clamped
    anchorFraction = clamped
  }

  /// Feeds one `DragGesture` change. `translation` is cumulative from touch-down, matching
  /// `DragGesture.Value.translation`.
  public mutating func update(translation: CGSize, trackWidth: CGFloat) {
    guard trackWidth > 0, translation.width.isFinite, translation.height.isFinite else { return }

    if isEngaged == false {
      // Axis gating: a drag that is mostly vertical is the user scrolling the page, not scrubbing,
      // and must leave the position untouched no matter how far it runs.
      guard isRefused == false else { return }
      guard abs(translation.width) >= Self.engagementThreshold,
        abs(translation.width) > abs(translation.height) * Self.dominanceRatio
      else {
        isRefused = abs(translation.height) >= Self.refusalThreshold
        return
      }
      isEngaged = true
      anchorTranslationWidth = translation.width
    }

    let updatedSpeed = Self.speed(verticalDistance: translation.height)
    if updatedSpeed != speed {
      anchorFraction = fraction
      anchorTranslationWidth = translation.width
      speed = updatedSpeed
    }

    let travelled = Double(translation.width - anchorTranslationWidth) / Double(trackWidth)
    fraction = min(max(anchorFraction + travelled * speed.multiplier, 0), 1)
  }
}

/// What the caller renders while a scrub is in flight: where the finger has the playhead, and at
/// what resolution. Copy for the speed stays with the caller (ARCHITECTURE.md).
public struct ScrubPreview: Sendable, Equatable {
  public let fraction: Double
  public let speed: ScrubSession.Speed

  public init(fraction: Double, speed: ScrubSession.Speed) {
    self.fraction = fraction
    self.speed = speed
  }
}
