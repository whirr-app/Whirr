import SwiftUI

/// The five prominence opacities as a value, so a surface whose ground cannot carry the standard
/// ladder can carry a lifted one instead of constraining its ground to suit.
///
/// `WhirrMetadataProminence` states the standard rungs; `ADR 0004` states why they are not the
/// only ones. Pinning the page's lightness so the dimmest standard rung clears AA at every hue
/// fixed the light band's floor at OKLab lightness 0.75 and left Dark appearance nowhere to dim a
/// bright cover to. Instead the page picks its lightness and the ladder adapts.
public struct WhirrMetadataLadder: Sendable, Equatable {
  /// The dimmest rung, and the alpha every contrast guarantee about this ladder is taken at.
  public let floor: Double

  /// The ladder every non-ambient surface uses. Uneven: title to author is the widest gap
  /// because that is the break the eye has to find.
  public static let standard = WhirrMetadataLadder(floor: WhirrMetadataProminence.floor)

  private init(floor: Double) {
    self.floor = floor
  }

  /// The standard ladder mapped affinely into `[floor, 1]`.
  ///
  /// Affine, not clamped: `max(opacity, floor)` at a floor of 0.80 would collapse quinary,
  /// quaternary and tertiary onto one value. The affine map keeps every rung distinct and in
  /// proportion, so the title-to-author break stays the widest gap, at the cost of a smaller
  /// absolute separation on a deeper page.
  ///
  /// A floor at or below the standard one returns the standard ladder unchanged.
  public static func liftingFloor(to floor: Double) -> WhirrMetadataLadder {
    guard floor > WhirrMetadataProminence.floor else { return .standard }
    return WhirrMetadataLadder(floor: min(floor, 1))
  }

  /// This ladder's opacity for a rung of the shared hierarchy.
  public func opacity(for prominence: WhirrMetadataProminence) -> Double {
    let standard = prominence.opacity
    guard floor > WhirrMetadataProminence.floor else { return standard }
    // Both ladders are anchored at 1.0, so the map is a scaling of each rung's distance below it.
    let compression = (1 - floor) / (1 - WhirrMetadataProminence.floor)
    return 1 - (1 - standard) * compression
  }
}

extension EnvironmentValues {
  /// The ladder the metadata hierarchy on this surface is drawn at.
  ///
  /// Read by `WhirrMetadataProminence.adaptiveStyle` at resolve time rather than passed down
  /// through every credit view. Surfaces that publish an ambient canvas publish its ladder the
  /// same way as its tint, so no call site needs to know more than one ladder exists.
  @Entry public var whirrMetadataLadder: WhirrMetadataLadder = .standard
}
