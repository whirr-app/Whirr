import SwiftUI

/// Applies the SwiftUI side of `SheetViewPresentation`. The policy decides; this modifier
/// translates that into detents, sizing and the drag-indicator contract for App-owned sheet hosts.
struct AdaptiveSheetPresentationModifier: ViewModifier {
  let role: SheetViewPresentation.Role
  let compactDetents: Set<PresentationDetent>
  let contentInteraction: PresentationContentInteraction

  /// The *window's* size class, not this sheet's: see `EnvironmentValues.windowHorizontalSizeClass`
  /// for why a sheet cannot size itself from the size class it is about to change.
  @Environment(\.windowHorizontalSizeClass) private var windowHorizontalSizeClass

  @ViewBuilder
  func body(content: Content) -> some View {
    switch SheetViewPresentation.mode(for: windowHorizontalSizeClass, role: role) {
    // `contentInteraction` is `.automatic` unless a caller opts out. `.scrolls` prioritises the
    // content's scroll over the detent interaction, and these sheets fill with scrolling content,
    // so a multi-detent sheet would lose the swipe to `.large` and keep only the grabber.
    // `.automatic` expands first and scrolls after.
    case .compactDetents:
      content
        .presentationDetents(compactDetents)
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(contentInteraction)
    case .compactLarge:
      content
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationContentInteraction(contentInteraction)
    case .regularPage:
      content
        .presentationSizing(.page.fitted(horizontal: false, vertical: true))
        .presentationDragIndicator(.hidden)
    case .regularForm:
      content
        // Plain `.form`, not `.form.fitted(vertical: true)`: this role hosts scrolling content
        // (a chapter list, a settings form) whose ideal height is one row, so fitting collapses
        // the sheet to a single row. The fixed form height is the standard iPad shape and lets
        // the content scroll inside it.
        .presentationSizing(.form)
        .presentationDragIndicator(.hidden)
    case .regularFitted:
      content
        .presentationSizing(.fitted)
        .presentationDragIndicator(.hidden)
    case .regularFullPage:
      content
        .presentationSizing(.page)
        .presentationDragIndicator(.hidden)
    case .exempt:
      content
    }
  }
}

extension View {
  /// Resolves the shared sheet policy in the presented content's local size-class environment.
  /// Compact callers supply the detents that belong to their surface; regular callers never carry
  /// those detents across and instead receive the role's fitted sizing.
  func adaptiveSheetPresentation(
    role: SheetViewPresentation.Role,
    compactDetents: Set<PresentationDetent> = [.medium, .large],
    contentInteraction: PresentationContentInteraction = .automatic
  ) -> some View {
    modifier(
      AdaptiveSheetPresentationModifier(
        role: role, compactDetents: compactDetents, contentInteraction: contentInteraction))
  }
}
