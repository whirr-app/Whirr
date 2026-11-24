import SnapshotTesting
import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Design system components")
@MainActor
struct ComponentTests {

  // MARK: - Item list row

  @Test("item list row exposes title, author, cover slot, and progress slot")
  func itemListRowExposesTitleAuthorCoverAndProgressSlots() {
    let row = ItemListRow(title: "Project Hail Mary", author: "Andy Weir") {
      Color.clear
    } progress: {
      Text("42%")
    }

    #expect(row.title == "Project Hail Mary")
    #expect(row.author == "Andy Weir")

    let mirror = Mirror(reflecting: row)
    let coverChild = mirror.children.first { $0.label == "cover" }
    let progressChild = mirror.children.first { $0.label == "progress" }

    #expect(coverChild != nil)
    #expect(progressChild != nil)
    #expect(coverChild.map { type(of: $0.value) == Color.self } == true)
    #expect(progressChild.map { type(of: $0.value) == Text.self } == true)
  }

  // MARK: - Media item summary row

  @Test("media item summary row renders title, subtitle, and metadata with its accessibility label")
  func mediaItemSummaryRowRendersSummaryAndAccessibilityLabel() {
    let row = MediaItemSummaryRow(
      title: "Project Hail Mary",
      subtitle: "Andy Weir",
      metadata: "Audiobook · 2.4 GB",
      accessibilityLabel: "Project Hail Mary, Andy Weir, Audiobook · 2.4 GB",
      coverSize: 56,
      cover: { Color.clear },
      inlineContent: { EmptyView() },
      trailingContent: { EmptyView() }
    )

    #expect(row.visibleText == ["Project Hail Mary", "Andy Weir", "Audiobook · 2.4 GB"])
    #expect(row.hasSubtitle)
    #expect(row.accessibilityLabel == "Project Hail Mary, Andy Weir, Audiobook · 2.4 GB")
  }

  @Test("media item summary row omits a nil subtitle")
  func mediaItemSummaryRowOmitsNilSubtitle() {
    let row = MediaItemSummaryRow(
      title: "Project Hail Mary",
      subtitle: nil,
      metadata: "Audiobook",
      accessibilityLabel: "Project Hail Mary, Audiobook",
      coverSize: 56,
      cover: { Color.clear },
      inlineContent: { EmptyView() },
      trailingContent: { EmptyView() }
    )

    #expect(row.visibleText == ["Project Hail Mary", "Audiobook"])
    #expect(row.hasSubtitle == false)
  }

  @Test("media item summary row renders inline and trailing slot content")
  func mediaItemSummaryRowRendersInlineAndTrailingSlotContent() {
    let row = MediaItemSummaryRow(
      title: "Project Hail Mary",
      subtitle: "Andy Weir",
      metadata: "Audiobook",
      accessibilityLabel: "Project Hail Mary, Andy Weir, Audiobook",
      coverSize: 56,
      cover: { Text("Cover") },
      inlineContent: { Text("Offline") },
      trailingContent: { Text("42%") }
    )

    let mirror = Mirror(reflecting: row)
    let coverChild = mirror.children.first { $0.label == "cover" }
    let inlineChild = mirror.children.first { $0.label == "inlineContent" }
    let trailingChild = mirror.children.first { $0.label == "trailingContent" }

    #expect(coverChild.map { type(of: $0.value) == Text.self } == true)
    #expect(inlineChild.map { type(of: $0.value) == Text.self } == true)
    #expect(trailingChild.map { type(of: $0.value) == Text.self } == true)
  }

  // MARK: - Cover placeholder

  @Test("cover placeholder carries the caller-supplied accessibility label")
  func coverPlaceholderCarriesCallerSuppliedLabel() {
    let placeholder = CoverPlaceholder(accessibilityLabel: "The Way of Kings cover")
    #expect(placeholder.accessibilityLabel == "The Way of Kings cover")
  }

  @Test("cover placeholder accepts no label for decorative use")
  func coverPlaceholderAcceptsNoLabel() {
    let placeholder = CoverPlaceholder()
    #expect(placeholder.accessibilityLabel == nil)
  }

  @Test("cover placeholder stays blank while artwork is still loading")
  func coverPlaceholderStaysBlankWhileLoading() {
    let placeholder = CoverPlaceholder(
      accessibilityLabel: "Walden cover", title: "Walden", author: "Thoreau", state: .loading)
    #expect(placeholder.generatedArt == nil)
  }

  @Test("cover placeholder generates art once artwork is known to be missing")
  func coverPlaceholderGeneratesArtWhenMissing() {
    let placeholder = CoverPlaceholder(
      accessibilityLabel: "Walden cover", title: "Walden", author: "Thoreau", state: .missing)
    #expect(placeholder.generatedArt?.displayTitle == "Walden")
    #expect(placeholder.generatedArt?.displayAuthor == "Thoreau")
  }

  @Test("cover placeholder stays blank when missing artwork has no title to set")
  func coverPlaceholderStaysBlankWithoutTitle() {
    #expect(CoverPlaceholder(title: "   ", state: .missing).generatedArt == nil)
    #expect(CoverPlaceholder(state: .missing).generatedArt == nil)
  }

  // MARK: - State views (copy always comes from the caller, never hardcoded)

  @Test("loading state view renders only caller-supplied copy")
  func loadingStateViewRendersCallerSuppliedCopy() {
    let view = LoadingStateView(message: "Syncing your library…")
    #expect(view.message == "Syncing your library…")
    assertSnapshot(of: view, as: .dump)
  }

  @Test("empty state view renders only caller-supplied copy")
  func emptyStateViewRendersCallerSuppliedCopy() {
    let view = EmptyStateView(
      title: "No audiobooks yet",
      message: "Items you add to your library will show up here.",
      systemImage: "books.vertical"
    )
    #expect(view.title == "No audiobooks yet")
    #expect(view.message == "Items you add to your library will show up here.")
    #expect(view.systemImage == "books.vertical")
    assertSnapshot(of: view, as: .dump)
  }

  @Test("empty state renders an optional action only when supplied")
  func emptyStateRendersOptionalAction() {
    var invoked = 0
    let withAction = EmptyStateView(
      title: "No downloads", message: "Download something to see it here.", systemImage: "arrow.down",
      actionLabel: "Browse Library", action: { invoked += 1 })
    #expect(withAction.hasAction)
    #expect(withAction.actionLabel == "Browse Library")
    #expect(String(reflecting: type(of: withAction.body)).contains("Button"))
    withAction.action?()
    #expect(invoked == 1)

    let withoutAction = EmptyStateView(
      title: "No downloads", message: "Download something to see it here.", systemImage: "arrow.down")
    #expect(withoutAction.hasAction == false)
    #expect(withoutAction.actionLabel == nil)
    #expect(withoutAction.action == nil)
  }

  @Test("error state view renders caller-supplied copy and an optional retry action")
  func errorStateViewRendersCallerSuppliedCopyAndRetryAction() {
    var retried = false
    let view = ErrorStateView(
      title: "Couldn't load your library",
      message: "Check your connection and try again.",
      systemImage: "exclamationmark.triangle",
      retryTitle: "Try Again",
      retryAction: { retried = true }
    )

    #expect(view.title == "Couldn't load your library")
    #expect(view.message == "Check your connection and try again.")
    #expect(view.retryTitle == "Try Again")

    view.retryAction?()
    #expect(retried)
  }

  @Test("error state view allows no retry action")
  func errorStateViewAllowsNoRetryAction() {
    let view = ErrorStateView(
      title: "Couldn't load your library",
      message: "Check your connection and try again.",
      systemImage: "exclamationmark.triangle"
    )
    #expect(view.retryTitle == nil)
    #expect(view.retryAction == nil)
  }

  // MARK: - Glass fallback decision (pure logic, no rendering required)

  @Test("glass policy uses glass only when available and transparency isn't reduced")
  func glassPolicyUsesGlassOnlyWhenAvailableAndTransparencyIsNotReduced() {
    #expect(
      GlassEffectPolicy.decide(isGlassAvailable: true, prefersReducedTransparency: false)
        == GlassEffectDecision(usesGlass: true, reason: .none))
    #expect(
      GlassEffectPolicy.decide(isGlassAvailable: true, prefersReducedTransparency: true)
        == GlassEffectDecision(usesGlass: false, reason: .reducedTransparency))
    #expect(
      GlassEffectPolicy.decide(isGlassAvailable: false, prefersReducedTransparency: false)
        == GlassEffectDecision(usesGlass: false, reason: .unavailablePlatform))
    #expect(
      GlassEffectPolicy.decide(isGlassAvailable: false, prefersReducedTransparency: true)
        == GlassEffectDecision(usesGlass: false, reason: .reducedTransparency))
  }

  @Test("glass container falls back to non-glass material when transparency is reduced")
  func glassContainerFallsBackForReducedTransparency() {
    let container = GlassContainer(
      forcedDecision: GlassEffectPolicy.decide(isGlassAvailable: true, prefersReducedTransparency: true)
    ) {
      Text("content")
    }
    #expect(container.branch == .fallbackMaterial)
  }

  @Test("glass container falls back to non-glass material pre-macOS-26/pre-iOS-26")
  func glassContainerFallsBackForUnavailablePlatform() {
    let container = GlassContainer(
      forcedDecision: GlassEffectPolicy.decide(isGlassAvailable: false, prefersReducedTransparency: false)
    ) {
      Text("content")
    }
    #expect(container.branch == .fallbackMaterial)
  }

  @Test("glass container uses the real glass path when available and transparency is not reduced")
  func glassContainerUsesGlassWhenAvailable() {
    let container = GlassContainer(
      forcedDecision: GlassEffectPolicy.decide(isGlassAvailable: true, prefersReducedTransparency: false)
    ) {
      Text("content")
    }
    #expect(container.branch == .glass)
  }

  @Test("glass container takes a caller-supplied shape and keeps the rounded rectangle by default")
  func glassContainerTakesACallerSuppliedShape() {
    let capsule = GlassContainer(in: Capsule()) { Text("content") }
    #expect(type(of: capsule) == GlassContainer<Text, Capsule>.self)
    let defaulted = GlassContainer { Text("content") }
    #expect(type(of: defaulted) == GlassContainer<Text, RoundedRectangle>.self)
  }

  // MARK: - Glass Reduce Motion fallback

  @Test("glass container disables its transition animation under Reduce Motion")
  func glassContainerDisablesAnimationUnderReduceMotion() {
    #expect(GlassContainer<Text, RoundedRectangle>.transitionAnimation(reduceMotion: true) == nil)
  }

  @Test("glass container animates its transition when motion is not reduced")
  func glassContainerAnimatesWhenMotionIsNotReduced() {
    #expect(GlassContainer<Text, RoundedRectangle>.transitionAnimation(reduceMotion: false) != nil)
  }

  // MARK: - Shell status indicator

  /// The glyph carries no text of its own, so its accessibility label has to be the whole title.
  /// The message and its remedy only exist once the popover is open.
  @Test("shell status indicator labels itself with the caller-supplied title alone")
  func shellStatusIndicatorLabelsItselfWithTitle() {
    let indicator = ShellStatusIndicatorView(
      title: "Reconnect to Audiobookshelf",
      message: "Existing downloads remain available. Reconnect to download or sync.",
      systemImage: "person.crop.circle.badge.exclamationmark",
      actionTitle: "Reconnect",
      onAction: {}
    )
    #expect(indicator.accessibilityLabel == "Reconnect to Audiobookshelf")
  }

  @Test("shell status indicator forwards its explanation's action")
  func shellStatusIndicatorForwardsItsAction() {
    var acted = false
    let indicator = ShellStatusIndicatorView(
      title: "Title", message: "Message", systemImage: "wifi.slash",
      actionTitle: "Retry", onAction: { acted = true }
    )
    indicator.onAction()
    #expect(acted)
  }

  @Test("shell status indicator holds its action until the explanation popover has gone")
  func shellStatusIndicatorDefersActionUntilPopoverDisappears() {
    var handoff = ShellStatusActionHandoff()
    handoff.isExplanationPresented = true

    handoff.requestAction()
    #expect(handoff.isExplanationPresented == false)
    // Still mid-dismissal: the action may present its own sheet, which UIKit refuses while the
    // popover is on screen.
    #expect(handoff.isActionPending)

    let acts = handoff.explanationDidDisappear()
    #expect(acts)
    #expect(handoff.isActionPending == false)
  }

  @Test("shell status indicator does not act when the popover is dismissed without the button")
  func shellStatusIndicatorIgnoresPlainDismissal() {
    var handoff = ShellStatusActionHandoff()
    handoff.isExplanationPresented = true
    handoff.isExplanationPresented = false
    let acts = handoff.explanationDidDisappear()
    #expect(acts == false)
  }

  @Test("shell status indicator's explanation action meets the 44pt minimum hit target")
  func shellStatusIndicatorActionMeetsMinimumHitTarget() {
    let indicator = ShellStatusIndicatorView(
      title: "Title", message: "Message", systemImage: "wifi.slash",
      actionTitle: "Retry", onAction: {}
    )
    #expect(indicator.actionButtonMinHeight >= WhirrMetric.minimumTouchTarget)
  }

  @Test("shell status indicator semantic snapshot captures only caller-supplied copy")
  func shellStatusIndicatorSemanticSnapshot() {
    let indicator = ShellStatusIndicatorView(
      title: "Reconnect to Audiobookshelf",
      message: "Existing downloads remain available. Reconnect to download or sync.",
      systemImage: "person.crop.circle.badge.exclamationmark",
      actionTitle: "Reconnect",
      actionAccessibilityHint: "Opens the sign-in sheet to reconnect to the server",
      onAction: {}
    )
    assertSnapshot(of: semanticSurface(of: indicator), as: .dump)
  }

}
