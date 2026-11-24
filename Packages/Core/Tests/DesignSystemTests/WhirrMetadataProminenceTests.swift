import SwiftUI
import Testing

@testable import DesignSystem

/// The player and the item-detail hero print the same credits (author, series, narrator), so one
/// token decides their level for both. Different levels would make the same author look like two
/// different kinds of thing depending on the screen.
@Suite("Metadata prominence")
struct WhirrMetadataProminenceTests {

  /// The level itself. Full primary under an already-primary title leaves three consecutive credit
  /// lines at one level, with no entry point and a wash of white.
  @Test("credit names sit below the title, not level with it")
  func creditNamesAreBelowTheTitle() {
    for credit in [
      WhirrMetadataProminence.authorName, .seriesName, .narratorName,
    ] {
      #expect(credit != .primary)
      #expect(WhirrMetadataProminence.primary.emphasisRank > credit.emphasisRank)
    }
  }

  /// The credits recede from each other rather than sharing one level, which would make the block
  /// a slab of equal-weight lines with nothing saying which to read first.
  @Test("author, series and narrator step down from each other")
  func theCreditsStepDown() {
    #expect(
      WhirrMetadataProminence.authorName.emphasisRank
        > WhirrMetadataProminence.seriesName.emphasisRank)
    #expect(
      WhirrMetadataProminence.seriesName.emphasisRank
        > WhirrMetadataProminence.narratorName.emphasisRank)
    #expect(WhirrMetadataProminence.narratorName.opacity > WhirrMetadataProminence.floor)
  }

  /// The break the eye enters the block by. An even ladder from the title down would put the
  /// author within a few percent of the title (the wash-of-white failure), so the gap above the
  /// credits has to be wider than any gap inside them.
  @Test("the widest gap is between the title and the first credit")
  func theTitleBreakIsTheWidestStep() {
    let titleToAuthor =
      WhirrMetadataProminence.primary.opacity - WhirrMetadataProminence.authorName.opacity
    let withinCredits =
      WhirrMetadataProminence.authorName.opacity - WhirrMetadataProminence.seriesName.opacity

    #expect(titleToAuthor > withinCredits)
  }

  /// A name is a control and the words around it ("Narrated by", the separating commas) are not,
  /// so the name has to outrank its lead-in. Brightness is the only channel carrying that, since
  /// the credits are not accent-tinted.
  @Test("every credit name outranks the lead-in beside it")
  func creditNamesOutrankTheirLeadIn() {
    for credit in [
      WhirrMetadataProminence.authorName, .seriesName, .narratorName,
    ] {
      #expect(credit.emphasisRank > WhirrMetadataProminence.creditLeadIn.emphasisRank)
    }
  }

  /// The ladder's actual values. The ambient page's scrim is sized against them, so changing one
  /// without re-deriving `CoverPalette.detailScrimFloor` would drop the page below WCAG AA.
  @Test("the ink ladder descends 1.00 / 0.88 / 0.80 / 0.72 / 0.64")
  func theLadderHasFiveRungs() {
    #expect(WhirrMetadataProminence.primary.opacity == 1.0)
    #expect(WhirrMetadataProminence.secondary.opacity == 0.88)
    #expect(WhirrMetadataProminence.tertiary.opacity == 0.8)
    #expect(WhirrMetadataProminence.quaternary.opacity == 0.72)
    #expect(WhirrMetadataProminence.quinary.opacity == 0.64)
    #expect(WhirrMetadataProminence.floor == WhirrMetadataProminence.quinary.opacity)
  }

  /// Rank and opacity are two statements of one hierarchy; nothing stops them being edited apart.
  @Test("brighter rungs rank higher, with no ties")
  func rankAndOpacityAgree() {
    let ordered = [
      WhirrMetadataProminence.quinary, .quaternary, .tertiary, .secondary, .primary,
    ]
    for (dimmer, brighter) in zip(ordered, ordered.dropFirst()) {
      #expect(brighter.opacity > dimmer.opacity)
      #expect(brighter.emphasisRank > dimmer.emphasisRank)
    }
  }

  /// Why the roles carry explicit opacities rather than `HierarchicalShapeStyle`. Its third level
  /// is white at roughly 0.30, and pure black is the most favourable ground there is: failing
  /// there means failing on every cover, under any scrim. The floor rung clears the same bar on
  /// the same ground with room to spare.
  @Test("the hierarchical scale's third level cannot reach AA on any ground")
  func theSystemTertiaryLevelIsUnreachable() {
    let black = WhirrRGBColor(0, 0, 0)
    func whiteInk(_ opacity: Double) -> WhirrRGBColor {
      WhirrRGBColor(opacity, opacity, opacity)
    }

    #expect(contrastRatio(whiteInk(0.30), black) < 4.5)
    #expect(contrastRatio(whiteInk(WhirrMetadataProminence.floor), black) >= 4.5)
  }

  /// The two roles on the floor rung. There is no room below the floor to separate them by
  /// brightness, so the lead-in leans on weight and the stat on size.
  @Test("the lead-in and the hero's stat share the floor rung")
  func theFloorRungCarriesTheLeadInAndTheStat() {
    #expect(WhirrMetadataProminence.creditLeadIn.opacity == WhirrMetadataProminence.floor)
    #expect(WhirrMetadataProminence.heroStat.opacity == WhirrMetadataProminence.floor)
    // The stat's lead is one rung up from what supports it, and no brighter than the dimmest
    // credit, so the staircase from author down through the stat block keeps descending.
    #expect(
      WhirrMetadataProminence.heroStatLead.emphasisRank
        > WhirrMetadataProminence.heroStat.emphasisRank)
    #expect(
      WhirrMetadataProminence.heroStatLead.emphasisRank
        <= WhirrMetadataProminence.narratorName.emphasisRank)
    #expect(WhirrMetadataProminence.narratorName.opacity > WhirrMetadataProminence.floor)
  }

  /// The player's chapter row. On the unmanaged hierarchical scale it measures 3.5-3.7:1 against
  /// the player's wash (the hero lead-in's failure, on the lighter of the two ambient gradients).
  @Test("the player's chapter row sits on the floor rung, below the byline")
  func thePlayerChapterRowIsOnTheFloorRung() {
    #expect(WhirrMetadataProminence.playerChapterRow.opacity == WhirrMetadataProminence.floor)
    #expect(
      WhirrMetadataProminence.playerByline.emphasisRank
        > WhirrMetadataProminence.playerChapterRow.emphasisRank)
  }

  /// The Up Next row on the player's page. The creator-or-show line is set in caption under a
  /// headline title, so size already marks it as supporting; it takes a credit rung rather than the
  /// floor. The "Next" eyebrow and the row's other labels take the floor, below the line they label.
  @Test("the Up Next row's subtitle sits between its title and its labels")
  func theQueueRowStepsDownFromTitleToLabel() {
    #expect(
      WhirrMetadataProminence.primary.emphasisRank
        > WhirrMetadataProminence.queueRowSubtitle.emphasisRank)
    #expect(
      WhirrMetadataProminence.queueRowSubtitle.emphasisRank
        > WhirrMetadataProminence.queueRowLabel.emphasisRank)
  }

}
