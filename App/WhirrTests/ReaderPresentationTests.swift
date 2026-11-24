import AppModel
import DesignSystem
import ReaderCore
import SwiftUI
import Testing

@testable import Whirr

@Suite("Reader presentation")
@MainActor
struct ReaderPresentationTests {
  @Test("tap zones map center to chrome and edges to page turns")
  func tapZonesMapToReaderIntents() {
    #expect(ReaderPresentation.intent(for: .left) == .turnPage(.left))
    #expect(ReaderPresentation.intent(for: .center) == .toggleChrome)
    #expect(ReaderPresentation.intent(for: .right) == .turnPage(.right))
  }

  @Test("reader intents carry ReaderCore screen-side directions")
  func readerIntentsCarryReaderCoreDirections() {
    let left: ReaderCore.ReaderPageDirection = .left
    #expect(ReaderPresentation.intent(for: .left) == .turnPage(left))
  }

  @Test("reader themes map explicitly between ReaderCore and DesignSystem")
  func readerThemeMappingIsExplicit() {
    #expect(ReaderPresentation.designTheme(for: ReaderCore.ReaderTheme.light, systemScheme: .dark) == .light)
    #expect(ReaderPresentation.designTheme(for: ReaderCore.ReaderTheme.sepia, systemScheme: .dark) == .sepia)
    #expect(ReaderPresentation.designTheme(for: ReaderCore.ReaderTheme.dark, systemScheme: .light) == .dark)
    #expect(ReaderPresentation.designTheme(for: ReaderCore.ReaderTheme.system, systemScheme: .light) == .light)
    #expect(ReaderPresentation.designTheme(for: ReaderCore.ReaderTheme.system, systemScheme: .dark) == .dark)

    #expect(ReaderPresentation.coreTheme(for: DesignSystem.ReaderTheme.light) == .light)
    #expect(ReaderPresentation.coreTheme(for: DesignSystem.ReaderTheme.sepia) == .sepia)
    #expect(ReaderPresentation.coreTheme(for: DesignSystem.ReaderTheme.dark) == .dark)
  }

  @Test("text alignments map explicitly between ReaderCore and DesignSystem")
  func readerAlignmentMappingIsExplicit() {
    for alignment in ReaderCore.ReaderTextAlignment.allCases {
      #expect(
        ReaderPresentation.coreAlignment(for: ReaderPresentation.designAlignment(for: alignment))
          == alignment)
    }
    #expect(
      ReaderPresentation.designAlignment(for: ReaderCore.ReaderTextAlignment.justify) == .justify)
    #expect(ReaderPresentation.coreAlignment(for: DesignSystem.ReaderTextAlignment.left) == .left)
  }

  @Test("a system reader preselects the resolved swatch, and one tap converts it (decision 3)")
  func systemThemeConvertsToTheResolvedSwatchOnFirstTap() {
    // The panel never shows a `.system` swatch, so the draft resolves first…
    let preselected = ReaderPresentation.designTheme(
      for: ReaderCore.ReaderTheme.system, systemScheme: .dark)
    #expect(preselected == .dark)

    // …and submitting that same preselection is what converts the stored theme, exactly once.
    let converted = ReaderPresentation.coreTheme(for: preselected)
    #expect(converted == ReaderCore.ReaderTheme.dark)
    #expect(converted != ReaderCore.ReaderTheme.system)
    #expect(
      ReaderPresentation.coreTheme(
        for: ReaderPresentation.designTheme(
          for: converted, systemScheme: .light)) == converted)
  }

  @Test("the reader declares the same window scheme the shell resolves for it")
  func readerWindowSchemeMatchesTheShellResolution() {
    // Sepia is a reading surface, not a dark appearance: the status bar has to stay dark-on-light.
    #expect(ReaderPresentation.windowScheme(for: DesignSystem.ReaderTheme.light) == .light)
    #expect(ReaderPresentation.windowScheme(for: DesignSystem.ReaderTheme.sepia) == .light)
    #expect(ReaderPresentation.windowScheme(for: DesignSystem.ReaderTheme.dark) == .dark)

    // The cover declares its own scheme because a presenting view's preference does not reach a
    // full-screen cover's status bar; the two must never disagree.
    for theme in DesignSystem.ReaderTheme.allCases {
      #expect(
        CoverAmbientPresentation.windowColorScheme(
          appPreference: .dark, presentedReaderTheme: theme)
          == ReaderPresentation.windowScheme(for: theme))
    }
  }

  @Test("the status bar follows the reader chrome")
  func statusBarFollowsReaderChrome() {
    #expect(ReaderPresentation.isStatusBarHidden(chromeVisible: true) == false)
    #expect(ReaderPresentation.isStatusBarHidden(chromeVisible: false))
  }

  @Test("the system toolbars follow the reader chrome")
  func toolbarsFollowReaderChrome() {
    #expect(ReaderPresentation.toolbarVisibility(chromeVisible: true) == .visible)
    #expect(ReaderPresentation.toolbarVisibility(chromeVisible: false) == .hidden)
  }

  @Test("the reader menu offers search only for a searchable book")
  func readerMenuFollowsSearchability() {
    #expect(
      ReaderPresentation.menuActions(isSearchable: true, isFinishOfferVisible: false)
        == [.contents, .search])
    #expect(
      ReaderPresentation.menuActions(isSearchable: false, isFinishOfferVisible: false)
        == [.contents])
  }

  @Test("appearance has its own button, folding into the menu while the finish offer takes the room")
  func appearanceFoldsIntoTheMenuForTheFinishOffer() {
    #expect(ReaderPresentation.showsAppearanceButton(isFinishOfferVisible: false))
    #expect(ReaderPresentation.showsAppearanceButton(isFinishOfferVisible: true) == false)
    #expect(
      ReaderPresentation.menuActions(isSearchable: true, isFinishOfferVisible: true)
        == [.contents, .search, .appearance])
    #expect(
      ReaderPresentation.menuActions(isSearchable: false, isFinishOfferVisible: true)
        == [.contents, .appearance])
  }

  @Test("the rail takes the bottom bar's spare width, within bounds")
  func railTakesTheSpareWidth() {
    let phone = ReaderPresentation.railWidth(containerWidth: 402, showsFinishOffer: false)
    let withOffer = ReaderPresentation.railWidth(containerWidth: 402, showsFinishOffer: true)
    #expect(phone > withOffer)
    // The system bar's own margins, the menu button, and the spacer take 140 on a phone, and the
    // appearance button beside the menu takes more; a rail any wider is folded into an overflow
    // menu instead of drawn.
    #expect(phone <= 402 - 140 - ReaderPresentation.appearanceButtonWidth)
    #expect(withOffer >= 88)
    #expect(ReaderPresentation.railWidth(containerWidth: 1366, showsFinishOffer: false) == 560)
    #expect(ReaderPresentation.railWidth(containerWidth: 0, showsFinishOffer: false) == 88)
    // Even the narrowest rail leaves a usable track inside its capsule.
    #expect(
      ReaderPresentation.railWidth(containerWidth: 0, showsFinishOffer: false)
        - 2 * ReaderPresentation.railCapsuleInset >= 44)
  }

  @Test("the rail stops at the page's trailing edge wherever the bar places it")
  func railFitsTheRoomTheBarLeavesIt() {
    // A half-open iPhone Duo confines the bottom bar to the right half. The page is still 867
    // points wide, so the rail asks for 560, and the bar starts it at x = 501: it ran under the
    // vertical bar's controls and off the screen.
    let halfOpen = ReaderPresentation.railWidth(
      containerWidth: 867, showsFinishOffer: false, railLeading: 500.67, pageTrailing: 867)
    #expect(halfOpen == 366)

    // Fully open, the bar centres the 560-point rail at x = 164 and the room after it is wider.
    #expect(
      ReaderPresentation.railWidth(
        containerWidth: 867, showsFinishOffer: false, railLeading: 163.67, pageTrailing: 867)
        == 560)
    // Unfolding from half-open: the narrowed rail is centred further left, and the room it then
    // reports lets it grow back to full width.
    #expect(
      ReaderPresentation.railWidth(
        containerWidth: 867, showsFinishOffer: false, railLeading: 260, pageTrailing: 867)
        == 560)
    // A phone's rail sits at the bar's leading margin with the buttons after it: the bar's own
    // arithmetic is the tighter bound, so measuring changes nothing.
    #expect(
      ReaderPresentation.railWidth(
        containerWidth: 402, showsFinishOffer: false, railLeading: 20, pageTrailing: 402)
        == ReaderPresentation.railWidth(containerWidth: 402, showsFinishOffer: false))
    // Before the rail has a place, and in a measurement that leaves no room, the floor holds.
    #expect(
      ReaderPresentation.railWidth(
        containerWidth: 867, showsFinishOffer: false, railLeading: nil, pageTrailing: 867) == 560)
    #expect(
      ReaderPresentation.railWidth(
        containerWidth: 867, showsFinishOffer: false, railLeading: 900, pageTrailing: 867) == 88)
  }

  @Test("the typography sample shows only on a full-height customise page")
  func typographySampleNeedsTheFullHeightCustomisePage() {
    #expect(ReaderPresentation.showsTypographySample(level: .customise, detent: .large))
    // At half height the page itself is in view above the sheet, and a pinned sample would take
    // nearly all of the sheet's height from the controls.
    #expect(ReaderPresentation.showsTypographySample(level: .customise, detent: .medium) == false)
    #expect(ReaderPresentation.showsTypographySample(level: .essentials, detent: .large) == false)
  }

  @Test("every reader menu action keeps its accessibility identifier")
  func readerMenuActionsKeepTheirIdentifiers() {
    #expect(ReaderMenuAction.contents.accessibilityIdentifier == ReaderAccessibilityID.toc)
    #expect(ReaderMenuAction.search.accessibilityIdentifier == ReaderAccessibilityID.search)
    #expect(ReaderMenuAction.appearance.accessibilityIdentifier == ReaderAccessibilityID.appearance)
  }

  @Test("closing restores the app theme before dismissing the reader cover")
  func closingRestoresAppThemeBeforeDismissingCover() {
    var events: [String] = []

    ReaderPresentation.dismiss(
      onThemeChange: { theme in events.append(theme == nil ? "app-theme" : "reader-theme") },
      dismissCover: { events.append("dismiss") })

    #expect(events == ["app-theme", "dismiss"])
  }

  @Test("the appearance panel's controls are namespaced under the App-owned prefix")
  func appearanceControlIdentifiersAreNamespaced() {
    let suffixes = [
      ReaderAppearanceControls.fontRowIdentifierSuffix,
      ReaderAppearanceControls.fontSizeIdentifierSuffix,
      ReaderAppearanceControls.themesIdentifierSuffix,
      ReaderAppearanceControls.layoutIdentifierSuffix,
      ReaderAppearanceControls.lineSpacingIdentifierSuffix,
      ReaderAppearanceControls.marginsIdentifierSuffix,
      ReaderAppearanceControls.readingModeIdentifierSuffix,
    ]
    let identifiers = suffixes.map(ReaderAccessibilityID.appearanceControl)

    #expect(Set(identifiers).count == suffixes.count)
    for identifier in identifiers {
      #expect(identifier.hasPrefix("\(ReaderAccessibilityID.appearancePanel)."))
    }
    // The panels' headers are the system's own navigation bars now, so the only identified
    // surfaces left are the two sheets and the control panel inside one of them.
    #expect(
      Set([
        ReaderAccessibilityID.appearancePanel, ReaderAccessibilityID.appearanceSheet,
        ReaderAccessibilityID.tocSheet, ReaderAccessibilityID.searchSheet,
      ]).count == 4)
  }

  @Test("reader accessibility order includes chrome, page, and VoiceOver turns")
  func accessibilityContractIsComplete() {
    #expect(
      ReaderAccessibilityID.order == [
        ReaderAccessibilityID.screen,
        ReaderAccessibilityID.back,
        ReaderAccessibilityID.menu,
        ReaderAccessibilityID.toc,
        ReaderAccessibilityID.search,
        ReaderAccessibilityID.appearance,
        ReaderAccessibilityID.page,
        ReaderAccessibilityID.progress,
      ])
    #expect(ReaderAccessibilityID.previousPage != ReaderAccessibilityID.nextPage)
    #expect(ReaderPresentation.isFullScreenCover == true)
  }
}

@Suite("Reader presentation relay")
struct ReaderPresentationRelayTests {
  private static func item(_ id: String) -> ReaderPresentationItem {
    ReaderPresentationItem(itemID: id, title: id, category: .ebook)
  }

  @Test("with no card standing the reader is raised straight away")
  func withoutACardTheReaderIsRaisedImmediately() {
    var relay = ReaderPresentationRelay()

    let immediate = relay.request(Self.item("a"), itemDetailPresented: false)

    #expect(immediate == Self.item("a"))
    #expect(relay.pending == nil)
  }

  @Test("Read from the regular-width card parks the reader until the card has gone")
  func readFromTheCardWaitsForItsDismissal() {
    var relay = ReaderPresentationRelay()

    #expect(relay.request(Self.item("a"), itemDetailPresented: true) == nil)
    #expect(relay.pending == Self.item("a"))
    #expect(relay.itemDetailDismissed() == Self.item("a"))
  }

  @Test("a released reader is not raised again by the next card's dismissal")
  func aReleasedReaderIsNotRaisedTwice() {
    var relay = ReaderPresentationRelay()

    _ = relay.request(Self.item("a"), itemDetailPresented: true)
    _ = relay.itemDetailDismissed()

    #expect(relay.pending == nil)
    #expect(relay.itemDetailDismissed() == nil)
  }

  @Test("dismissing a card nobody read from raises nothing")
  func anOrdinaryCardDismissalRaisesNothing() {
    var relay = ReaderPresentationRelay()

    #expect(relay.itemDetailDismissed() == nil)
  }

  @Test("only the last Read is honoured, and it never survives an immediate one")
  func theLastRequestWins() {
    var relay = ReaderPresentationRelay()

    _ = relay.request(Self.item("a"), itemDetailPresented: true)
    _ = relay.request(Self.item("b"), itemDetailPresented: true)
    #expect(relay.itemDetailDismissed() == Self.item("b"))

    _ = relay.request(Self.item("c"), itemDetailPresented: true)
    #expect(relay.request(Self.item("d"), itemDetailPresented: false) == Self.item("d"))
    #expect(relay.pending == nil)
  }
}
