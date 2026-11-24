import SwiftUI

/// Which presentation path a `GlassContainer` resolved to. Exposed so tests can assert the
/// wrapper picked the correct branch without rendering.
public enum GlassContainerBranch: Sendable, Equatable {
  case glass
  case fallbackMaterial
}

/// Shared glass surface wrapper (ARCHITECTURE.md §6). Glass siblings share one container so
/// "glass can't sample glass" never bites callers. The Reduce Transparency and pre-iOS-26 /
/// pre-macOS-26 fallbacks live here, so callers need no `#available` guard around `glassEffect`.
public struct GlassContainer<Content: View, Shape: InsettableShape>: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private let content: Content
  private let shape: Shape
  private let forcedDecision: GlassEffectDecision?

  /// `shape` bounds both the glass and its fallback material so the two branches keep one
  /// outline.
  public init(in shape: Shape, @ViewBuilder content: () -> Content) {
    self.content = content()
    self.shape = shape
    self.forcedDecision = nil
  }

  /// Test-only escape hatch: forces the fallback decision so `ComponentTests` can assert
  /// both fallback paths deterministically, independent of the environment or host OS
  /// version. Not part of the public API surface.
  init(forcedDecision: GlassEffectDecision, in shape: Shape, @ViewBuilder content: () -> Content) {
    self.content = content()
    self.shape = shape
    self.forcedDecision = forcedDecision
  }

  var decision: GlassEffectDecision {
    if let forcedDecision {
      return forcedDecision
    }
    if #available(iOS 26.0, macOS 26.0, *) {
      return GlassEffectPolicy.decide(isGlassAvailable: true, prefersReducedTransparency: reduceTransparency)
    }
    return GlassEffectPolicy.decide(isGlassAvailable: false, prefersReducedTransparency: reduceTransparency)
  }

  var branch: GlassContainerBranch {
    decision.usesGlass ? .glass : .fallbackMaterial
  }

  /// The glass/fallback transition animates by default but must be suppressed for Reduce Motion
  /// (ARCHITECTURE.md §6). A pure function, so it is testable without a host renderer.
  static func transitionAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .default
  }

  public var body: some View {
    Group {
      if #available(iOS 26.0, macOS 26.0, *), decision.usesGlass {
        GlassEffectContainer {
          content
            .glassEffect(.regular, in: shape)
        }
      } else {
        content
          .background(.thinMaterial, in: shape)
      }
    }
    .animation(Self.transitionAnimation(reduceMotion: reduceMotion), value: branch)
  }
}

extension GlassContainer where Shape == RoundedRectangle {
  public static var defaultShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: WhirrSpacing.medium)
  }

  public init(@ViewBuilder content: () -> Content) {
    self.init(in: Self.defaultShape, content: content)
  }

  init(forcedDecision: GlassEffectDecision, @ViewBuilder content: () -> Content) {
    self.init(forcedDecision: forcedDecision, in: Self.defaultShape, content: content)
  }
}
