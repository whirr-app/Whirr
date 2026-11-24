import Foundation

/// Why a glass surface fell back to a non-glass presentation, if it did.
public enum GlassFallbackReason: Sendable, Equatable {
  case reducedTransparency
  case unavailablePlatform
  case none
}

/// The resolved outcome of `GlassEffectPolicy.decide`. A plain value, so `ComponentTests` can
/// assert both fallback paths without a host renderer.
public struct GlassEffectDecision: Sendable, Equatable {
  public let usesGlass: Bool
  public let reason: GlassFallbackReason

  public init(usesGlass: Bool, reason: GlassFallbackReason) {
    self.usesGlass = usesGlass
    self.reason = reason
  }
}

/// Pure decision logic for whether a glass surface should render. Free of SwiftUI so both
/// fallback paths (ARCHITECTURE.md §6) are testable without rendering. Reduce Transparency always
/// wins, then platform/OS-version availability.
public enum GlassEffectPolicy {
  public static func decide(isGlassAvailable: Bool, prefersReducedTransparency: Bool) -> GlassEffectDecision {
    if prefersReducedTransparency {
      return GlassEffectDecision(usesGlass: false, reason: .reducedTransparency)
    }
    guard isGlassAvailable else {
      return GlassEffectDecision(usesGlass: false, reason: .unavailablePlatform)
    }
    return GlassEffectDecision(usesGlass: true, reason: .none)
  }
}
