import SwiftUI

/// A primary scroll host's role in its navigation bar, which picks the top scroll-edge treatment.
/// `.soft` replaces the system backdrop, so a titled screen using it opts out. See
/// `adr/0010-tab-root-titles-stay-on-the-system-default.md`.
nonisolated enum PrimaryScrollEdgeRole: Equatable, Sendable, CaseIterable {
  /// A tab root with no navigation title. Nothing needs protecting, so content passes under a bare
  /// bar and the soft edge keeps the shelves reading to the physical top edge.
  case untitledRoot
  /// A pushed screen whose title and back button must stay legible over artwork moving beneath
  /// them.
  case titled
  /// Selection chrome, which must read from the first frame rather than fading up into legibility.
  case selecting
}

/// The style a role resolves to, as a value a test can compare.
///
/// `ScrollEdgeEffectStyle` is not `Equatable` and `primaryScrollEdgeEffect` returns `some View`, so
/// without this intermediate the mapping could only be pinned by scanning source text. The view
/// helper switches on this alone, so the tested value and the rendered result are one decision.
nonisolated enum PrimaryScrollEdgeStyle: Equatable, Sendable {
  case soft
  case hard
}

nonisolated enum PrimaryScrollEdgePresentation {
  static func style(for role: PrimaryScrollEdgeRole) -> PrimaryScrollEdgeStyle {
    switch role {
    case .untitledRoot: .soft
    case .titled, .selecting: .hard
    }
  }
}

/// Applies the consistent top scroll-edge treatment to Whirr's primary scroll hosts.
///
/// A pass-through, not a `ViewModifier`, whose `body(content:)` would wrap the scroll view the
/// edge effect resolves against. `ItemDetailScrollContentView` (hero under a self-fading inline
/// title) and `PodcastShowView` (accent wash behind the bar) keep `.soft`.
extension View {
  /// Applies the top-edge effect for a host's role.
  func primaryScrollEdgeEffect(role: PrimaryScrollEdgeRole) -> some View {
    scrollEdgeEffectStyle(
      PrimaryScrollEdgePresentation.style(for: role) == .hard ? .hard : .soft, for: .top)
  }

  /// The selection-aware spelling, so hosts that vary only by selection do not each restate the
  /// role mapping. `isSelecting: false` means `.untitledRoot`, so a titled host that also has
  /// selection must call `primaryScrollEdgeEffect(role:)` directly.
  func primaryScrollEdgeEffect(isSelecting: Bool = false) -> some View {
    primaryScrollEdgeEffect(role: isSelecting ? .selecting : .untitledRoot)
  }
}
