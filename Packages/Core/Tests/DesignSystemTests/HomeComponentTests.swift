import SnapshotTesting
import SwiftUI
import Testing

@testable import DesignSystem

// Home screen components: badge, card, section header, filter chips. All stateless and
// value-driven, with no Persistence/AppModel import. Assertions are over plain values and
// computed properties, as in `DownloadComponentTests`; no rendering harness is wired for these
// targets.
@Suite("Home screen components")
@MainActor
struct HomeComponentTests {

  // MARK: - Media kind badge

  @Test(
    "media kind badge's symbol differs per kind: audiobook = headphones, podcast = radio waves, ebook = book",
    arguments: [
      (MediaKindBadge.audiobook, "headphones"),
      (MediaKindBadge.podcast, "antenna.radiowaves.left.and.right"),
      (MediaKindBadge.ebook, "book"),
    ]
  )
  func mediaKindBadgeSymbolDiffersPerKind(kind: MediaKindBadge, systemImage: String) {
    let badge = MediaKindBadgeView(kind: kind, label: "Audiobook")
    #expect(badge.systemImage == systemImage)
    // The kind itself carries the symbol, so a surface that pictures a media kind without drawing
    // a badge (a filtered empty state) can't drift from the badge's own choice.
    #expect(kind.symbolName == systemImage)
  }

  @Test("media kind badge symbols are pairwise distinct across every kind")
  func mediaKindBadgeSymbolsAreDistinctAcrossKinds() {
    let symbols = Set(MediaKindBadge.allCases.map { MediaKindBadgeView(kind: $0, label: "x").systemImage })
    #expect(symbols.count == MediaKindBadge.allCases.count)
  }

  @Test("media kind badge exposes the caller-supplied label as its accessibility label")
  func mediaKindBadgeExposesCallerSuppliedLabel() {
    let badge = MediaKindBadgeView(kind: .podcast, label: "Podcast")
    #expect(badge.label == "Podcast")
    #expect(badge.accessibilityLabel == "Podcast")
  }

  @Test("a source mark joins the card's one utterance, and no mark adds nothing")
  func sourceMarkJoinsTheCombinedUtterance() {
    func card(sourceMark: (symbol: String, label: String)?) -> HomeCardView<Color> {
      HomeCardView(
        title: "Empire",
        subtitle: "Goalhanger",
        badgeKind: .podcast,
        badgeLabel: "Podcast",
        sourceMarkSymbol: sourceMark?.symbol,
        sourceMarkLabel: sourceMark?.label,
        cover: { Color.clear },
        onSelect: {}
      )
    }
    #expect(
      card(sourceMark: ("server.rack", "On your server")).accessibilityLabel
        == "Empire. Goalhanger. Podcast. On your server")
    #expect(card(sourceMark: nil).accessibilityLabel == "Empire. Goalhanger. Podcast")
  }

  @Test("media kind badge semantic snapshot")
  func mediaKindBadgeSemanticSnapshot() {
    let badge = MediaKindBadgeView(kind: .ebook, label: "eBook")
    assertSnapshot(of: badge, as: .dump)
  }

  // MARK: - Home card

  @Test("playback progress bar clamps out-of-range and non-finite fractions")
  func playbackProgressBarClampsFractions() {
    // Asserted through an instance, not the static helper: the point is that the bar itself
    // normalizes before SwiftUI sees the value, not merely that a pure function exists.
    #expect(PlaybackProgressBar(fraction: -0.4).clampedFraction == 0)
    #expect(PlaybackProgressBar(fraction: 1.4).clampedFraction == 1)
    #expect(PlaybackProgressBar(fraction: .infinity).clampedFraction == 1)
    #expect(PlaybackProgressBar(fraction: -.infinity).clampedFraction == 0)
    #expect(PlaybackProgressBar(fraction: .nan).clampedFraction == 0)
    #expect(PlaybackProgressBar(fraction: .nan).accessibilityValueText == "0%")
  }

  @Test("playback progress bar exposes one percentage accessibility value")
  func playbackProgressBarExposesAccessibilityValue() {
    let bar = PlaybackProgressBar(fraction: 0.426)
    #expect(bar.clampedFraction == 0.426)
    #expect(PlaybackProgressBar.progressTint == WhirrColorToken.textPrimary.color)
    #expect(bar.accessibilityLabel == "Playback progress")
    #expect(bar.accessibilityValueText == "43%")
  }

  @Test("home card's progress bar tint follows the wash accent and falls back to the shared tint")
  func homeCardProgressTintFollowsWashAccent() {
    func card(wash: CoverWash?) -> HomeCardView<Color> {
      HomeCardView(
        title: "Project Hail Mary",
        subtitle: "Andy Weir",
        badgeKind: .audiobook,
        badgeLabel: "Audiobook",
        progressFraction: 0.5,
        wash: wash,
        cover: { Color.clear },
        onSelect: {}
      )
    }
    let washed = card(wash: CoverWash.from(hue: 0.4, saturation: 0.8, brightness: 0.6))
    #expect(washed.progressBarTint != PlaybackProgressBar.progressTint)
    // Neutral washes carry no accent, so the bar keeps the shared tint, same as no wash at all.
    #expect(card(wash: .neutral).progressBarTint == PlaybackProgressBar.progressTint)
    #expect(card(wash: nil).progressBarTint == PlaybackProgressBar.progressTint)
  }

  @Test("a home card holds the bar's line when its shelf reserves it, so mixed shelves keep one height")
  func homeCardHoldsTheBarLineWhenReserved() {
    func card(progressFraction: Double?, reservesProgressLine: Bool) -> HomeCardView<Color> {
      HomeCardView(
        title: "Episode",
        subtitle: "Show",
        badgeKind: .podcast,
        badgeLabel: "Podcast",
        progressFraction: progressFraction,
        reservesProgressLine: reservesProgressLine,
        cover: { Color.clear },
        onSelect: {}
      )
    }

    // A started card and an unstarted card on a reserving shelf both give the line its space; only
    // the started one draws the bar into it.
    #expect(card(progressFraction: 0.4, reservesProgressLine: true).holdsProgressLine)
    #expect(card(progressFraction: 0.4, reservesProgressLine: true).drawsProgressBar)
    #expect(card(progressFraction: nil, reservesProgressLine: true).holdsProgressLine)
    #expect(card(progressFraction: nil, reservesProgressLine: true).drawsProgressBar == false)
    // A shelf that does not reserve keeps today's layout.
    #expect(card(progressFraction: nil, reservesProgressLine: false).holdsProgressLine == false)
    #expect(card(progressFraction: 0.4, reservesProgressLine: false).holdsProgressLine)
  }

  @Test("a home card can show its held line as an empty track instead of a gap")
  func homeCardShowsTheHeldLineAsAnEmptyTrack() {
    func card(progressFraction: Double?, showsEmptyTrack: Bool) -> HomeCardView<Color> {
      HomeCardView(
        title: "Episode",
        subtitle: "Show",
        badgeKind: .podcast,
        badgeLabel: "Podcast",
        progressFraction: progressFraction,
        reservesProgressLine: true,
        showsEmptyProgressTrack: showsEmptyTrack,
        cover: { Color.clear },
        onSelect: {}
      )
    }

    #expect(card(progressFraction: nil, showsEmptyTrack: true).drawsEmptyProgressTrack)
    #expect(card(progressFraction: nil, showsEmptyTrack: true).drawsProgressBar == false)
    // A held line stays a blank gap unless the shelf asks for the track.
    #expect(card(progressFraction: nil, showsEmptyTrack: false).drawsEmptyProgressTrack == false)
    // A started card draws its own bar, never the empty track.
    #expect(card(progressFraction: 0.4, showsEmptyTrack: true).drawsEmptyProgressTrack == false)
  }

  @Test("home card composes title, subtitle, badge label, and caption into one accessibility utterance")
  func homeCardComposesOneAccessibilityUtterance() {
    let card = HomeCardView(
      title: "Project Hail Mary",
      subtitle: "Andy Weir",
      badgeKind: .audiobook,
      badgeLabel: "Audiobook",
      progressFraction: 0.5,
      trailingCaption: "6h 50m left",
      cover: { Color.clear },
      onSelect: {}
    )
    #expect(
      card.accessibilityLabel
        == "Project Hail Mary. Andy Weir. Audiobook. 6h 50m left")
  }

  @Test("home card's accessibility utterance omits an empty trailing caption rather than adding a trailing separator")
  func homeCardAccessibilityUtteranceOmitsEmptyCaption() {
    let card = HomeCardView(
      title: "Project Hail Mary",
      subtitle: "Andy Weir",
      badgeKind: .audiobook,
      badgeLabel: "Audiobook",
      trailingCaption: "",
      cover: { Color.clear },
      onSelect: {}
    )
    #expect(card.accessibilityLabel == "Project Hail Mary. Andy Weir. Audiobook")
  }

  @Test("home card's accessibility utterance omits a nil trailing caption")
  func homeCardAccessibilityUtteranceOmitsNilCaption() {
    let card = HomeCardView(
      title: "Project Hail Mary",
      subtitle: "Andy Weir",
      badgeKind: .ebook,
      badgeLabel: "eBook",
      cover: { Color.clear },
      onSelect: {}
    )
    #expect(card.accessibilityLabel == "Project Hail Mary. Andy Weir. eBook")
  }

  @Test(
    "home card clamps an out-of-range progress fraction to 0...1",
    arguments: [(-0.4, 0.0), (0.0, 0.0), (0.42, 0.42), (1.0, 1.0), (1.8, 1.0)]
  )
  func homeCardClampsProgressFraction(input: Double, expected: Double) {
    let card = HomeCardView(
      title: "Title", subtitle: "Author", badgeKind: .audiobook, badgeLabel: "Audiobook",
      progressFraction: input, cover: { Color.clear }, onSelect: {}
    )
    #expect(card.progressFraction == expected)
  }

  @Test("home card carries no progress bar at all when the caller supplies no fraction")
  func homeCardCarriesNoProgressWhenFractionIsNil() {
    let card = HomeCardView(
      title: "Title", subtitle: "Author", badgeKind: .podcast, badgeLabel: "Podcast",
      cover: { Color.clear }, onSelect: {}
    )
    #expect(card.progressFraction == nil)
  }

  @Test("home card reserves two title lines and one subtitle line unless the caller says otherwise")
  func homeCardReservesTwoTitleLinesBeforeSubtitleAndProgress() {
    let card = HomeCardView(
      title: "Title", subtitle: "Author", badgeKind: .podcast, badgeLabel: "Podcast",
      cover: { Color.clear }, onSelect: {}
    )
    #expect(card.titleLineLimit == 2)
    #expect(card.subtitleLineLimit == 1)
  }

  @Test("home card exposes its caller-supplied cover slot generically")
  func homeCardExposesCoverSlotGenerically() {
    let card = HomeCardView(
      title: "Title", subtitle: "Author", badgeKind: .audiobook, badgeLabel: "Audiobook",
      cover: { Text("cover") }, onSelect: {}
    )
    let mirror = Mirror(reflecting: card)
    let coverChild = mirror.children.first { $0.label == "cover" }
    #expect(coverChild != nil)
    #expect(coverChild.map { type(of: $0.value) == Text.self } == true)
  }

  @Test("home card forwards its tap action")
  func homeCardForwardsTapAction() {
    var selected = false
    let card = HomeCardView(
      title: "Title", subtitle: "Author", badgeKind: .audiobook, badgeLabel: "Audiobook",
      cover: { Color.clear }, onSelect: { selected = true }
    )
    card.onSelect()
    #expect(selected)
  }

  @Test("home card's accessibility utterance names the finished state last")
  func homeCardAccessibilityUtteranceNamesFinishedState() {
    let card = HomeCardView(
      title: "Project Hail Mary",
      subtitle: "Andy Weir",
      badgeKind: .audiobook,
      badgeLabel: "Audiobook",
      finishedLabel: "Finished",
      cover: { Color.clear },
      onSelect: {}
    )
    #expect(card.accessibilityLabel == "Project Hail Mary. Andy Weir. Audiobook. Finished")
    #expect(card.isFinished)
  }

  /// A continuation card's caption already reads "Finished" for a finished title, so the mark must
  /// not make VoiceOver say it twice.
  @Test("home card says the finished state once when the caption already carries it")
  func homeCardAccessibilityUtteranceDoesNotRepeatTheFinishedState() {
    let card = HomeCardView(
      title: "Project Hail Mary",
      subtitle: "Andy Weir",
      badgeKind: .audiobook,
      badgeLabel: "Audiobook",
      trailingCaption: "Finished",
      finishedLabel: "Finished",
      cover: { Color.clear },
      onSelect: {}
    )
    #expect(card.accessibilityLabel == "Project Hail Mary. Andy Weir. Audiobook. Finished")
  }

  @Test("a card with no finished label is not finished")
  func homeCardWithoutFinishedLabelIsNotFinished() {
    let card = HomeCardView(
      title: "Title", subtitle: "Author", badgeKind: .audiobook, badgeLabel: "Audiobook",
      cover: { Color.clear }, onSelect: {}
    )
    #expect(card.isFinished == false)
  }

  @Test("home card semantic snapshot: in-progress audiobook")
  func homeCardSemanticSnapshotInProgress() {
    let card = HomeCardView(
      title: "Project Hail Mary", subtitle: "Andy Weir", badgeKind: .audiobook, badgeLabel: "Audiobook",
      progressFraction: 0.42, trailingCaption: "6h 50m left", cover: { Color.clear }, onSelect: {}
    )
    assertSnapshot(of: card, as: .dump)
  }

  @Test("home card semantic snapshot: no progress")
  func homeCardSemanticSnapshotNoProgress() {
    let card = HomeCardView(
      title: "Project Hail Mary", subtitle: "Andy Weir", badgeKind: .ebook, badgeLabel: "eBook",
      cover: { Color.clear }, onSelect: {}
    )
    assertSnapshot(of: card, as: .dump)
  }

  // MARK: - Section header

  @Test("section header exposes its title and hides disclosure when no action is supplied")
  func sectionHeaderHidesDisclosureWhenNotSupplied() {
    let header = BrowseSectionHeaderView(title: "Continue Listening")
    #expect(header.title == "Continue Listening")
    #expect(header.isShowingDisclosure == false)
  }

  @Test("section header shows disclosure when its destination is supplied")
  func sectionHeaderShowsDisclosureWhenDestinationIsSupplied() {
    var tapped = false
    let header = BrowseSectionHeaderView(
      title: "Recently Added", accessibilityHint: "Shows all recently added titles.",
      onSelect: { tapped = true }
    )
    #expect(header.isShowingDisclosure)
    header.onSelect?()
    #expect(tapped)
  }

  @Test("section header disclosure action meets the 44pt minimum hit target")
  func sectionHeaderDisclosureMeetsMinimumHitTarget() {
    let header = BrowseSectionHeaderView(
      title: "Downloads", accessibilityHint: "Shows all downloads.", onSelect: {}
    )
    #expect(header.actionMinHeight >= WhirrMetric.minimumTouchTarget)
  }

  @Test("section header semantic snapshot: with disclosure")
  func sectionHeaderSemanticSnapshotWithDisclosure() {
    let header = BrowseSectionHeaderView(
      title: "Continue Listening", accessibilityHint: "Shows everything in Continue Listening.",
      onSelect: {}
    )
    assertSnapshot(of: header, as: .dump)
  }

  @Test("section header semantic snapshot: without disclosure")
  func sectionHeaderSemanticSnapshotWithoutDisclosure() {
    let header = BrowseSectionHeaderView(title: "Downloads")
    assertSnapshot(of: header, as: .dump)
  }

  // MARK: - Media filter picker

  @Test("filter picker defaults to the segmented style")
  func filterPickerDefaultsToSegmentedStyle() {
    let picker = MediaFilterPicker(
      title: "Filter", labels: ["All", "Audiobooks", "Podcasts", "eBooks"], selectedIndex: 0,
      onSelect: { _ in })
    #expect(picker.style == .segmented)
  }

  @Test("filter picker reports which index is selected")
  func filterPickerReportsSelectedIndex() {
    let picker = MediaFilterPicker(
      title: "Filter", labels: ["All", "Audiobooks", "Podcasts", "eBooks"], selectedIndex: 2,
      onSelect: { _ in })
    #expect(picker.isSelected(2))
    #expect(!picker.isSelected(0))
    #expect(!picker.isSelected(1))
    #expect(!picker.isSelected(3))
  }

  @Test("filter picker exposes disabled chip indices")
  func filterPickerDisabledIndices() {
    let picker = MediaFilterPicker(
      title: "Show source", labels: ["Followed", "On your server"], selectedIndex: 1,
      style: .chips, disabledIndices: [0], onSelect: { _ in })
    #expect(picker.isDisabled(0))
    #expect(!picker.isDisabled(1))
  }

  @Test("filter picker's selection binding reads the currently selected index")
  func filterPickerSelectionBindingReadsSelectedIndex() {
    let picker = MediaFilterPicker(
      title: "Filter", labels: ["All", "Audiobooks", "Podcasts", "eBooks"], selectedIndex: 2,
      onSelect: { _ in })
    #expect(picker.selection.wrappedValue == 2)
  }

  /// The segmented control drives selection through the binding, so the binding (not a tap
  /// handler) has to forward the new index rather than the previously selected one.
  @Test("filter picker's selection binding forwards the newly chosen index")
  func filterPickerSelectionBindingForwardsChosenIndex() {
    var chosenIndex: Int?
    let picker = MediaFilterPicker(
      title: "Filter", labels: ["All", "Audiobooks", "Podcasts", "eBooks"], selectedIndex: 0,
      onSelect: { chosenIndex = $0 }
    )
    picker.selection.wrappedValue = 3
    #expect(chosenIndex == 3)
  }

  /// A chip row can borrow the screen's cover accent for its selected capsule; unset, it stays on
  /// brand ink (as Home and the Podcasts root draw).
  ///
  /// The tint passes through the pairing resolver, so what comes back is a fill an ink can be laid
  /// on. A deep red survives unchanged, so it samples the plumbing; a pale tint does not, which is
  /// the second case. The ratios belong to `CoverAccentFillContrastTests`.
  @Test("chips take a caller's selection tint and default to brand ink")
  func filterPickerChipSelectionTint() {
    let tinted = Color(red: 0.55, green: 0.09, blue: 0.13)
    let accented = MediaFilterPicker(
      title: "Filter", labels: ["All", "Unplayed"], selectedIndex: 0, style: .chips,
      selectionTint: tinted, onSelect: { _ in })
    #expect(accented.selectionFill == tinted)

    let pale = Color(red: 0.98, green: 0.92, blue: 0.42)
    let paleChips = MediaFilterPicker(
      title: "Filter", labels: ["All", "Unplayed"], selectedIndex: 0, style: .chips,
      selectionTint: pale, onSelect: { _ in })
    #expect(
      paleChips.selectionInk != WhirrColorToken.editorialBackground.color,
      "a pale tint still takes the paper ink that failed on it")

    let plain = MediaFilterPicker(
      title: "Filter", labels: ["All", "Unplayed"], selectedIndex: 0, style: .chips,
      onSelect: { _ in })
    #expect(plain.selectionFill == WhirrColorToken.brandInk.color)
    #expect(plain.selectionInk == WhirrColorToken.editorialBackground.color)
  }

  /// The ambient item-detail page's style. Its whole reason for existing is that the labels are on
  /// the metadata ladder, so the mapping onto it is the part worth pinning: selected ink is the
  /// title's own level, and the tab not chosen is a step back rather than the floor, which would
  /// read as disabled beside it.
  @Test("underline tabs put both states on the metadata ladder")
  func filterPickerUnderlineProminence() {
    #expect(MediaFilterPicker.underlineProminence(isSelected: true) == .primary)
    #expect(MediaFilterPicker.underlineProminence(isSelected: false) == .tertiary)
    #expect(
      MediaFilterPicker.underlineProminence(isSelected: true).emphasisRank
        > MediaFilterPicker.underlineProminence(isSelected: false).emphasisRank)
    #expect(
      MediaFilterPicker.underlineProminence(isSelected: false).emphasisRank
        > WhirrMetadataProminence.quinary.emphasisRank,
      "an unselected tab is a control, not the dimmest thing on the page")

    let picker = MediaFilterPicker(
      title: "Detail Tab", labels: ["Chapters", "History"], selectedIndex: 1, style: .underline,
      onSelect: { _ in })
    #expect(picker.style == .underline)
    #expect(picker.isSelected(1))
  }

  @Test("chip selection motion is shared and respects Reduce Motion")
  func filterPickerChipSelectionMotion() {
    #expect(MediaFilterPicker.chipSelectionAnimation(reduceMotion: false) != nil)
    #expect(MediaFilterPicker.chipSelectionAnimation(reduceMotion: true) == nil)
  }

  /// The underline rule does not travel between segments, so it does not borrow the chip's spring.
  /// The tab content it labels swaps instantly; a rule travelling for a third of a second while
  /// the list rebuilds reads as lag rather than as motion.
  @Test("underline selection has its own motion, distinct from the chips'")
  func filterPickerUnderlineSelectionMotion() {
    #expect(MediaFilterPicker.underlineSelectionAnimation(reduceMotion: false) != nil)
    #expect(MediaFilterPicker.underlineSelectionAnimation(reduceMotion: true) == nil)
    #expect(
      MediaFilterPicker.underlineSelectionAnimation(reduceMotion: false)
        != MediaFilterPicker.chipSelectionAnimation(reduceMotion: false))
  }

  @Test("filter picker semantic snapshot")
  func filterPickerSemanticSnapshot() {
    let picker = MediaFilterPicker(
      title: "Filter", labels: ["All", "Audiobooks", "Podcasts", "eBooks"], selectedIndex: 1,
      onSelect: { _ in })
    assertSnapshot(of: picker, as: .dump)
  }

  // MARK: - Filter button

  /// The toolbar keeps one native `Menu` surface and expresses selection with SF Symbols' matched
  /// outline/fill pair. This is what lets the system-owned glass morph into the menu without the
  /// source changing control shape underneath it.
  @Test("the toolbar funnel uses matched outline and fill symbols")
  func filterGlyphsUseMatchedOutlineAndFillSymbols() {
    #expect(
      FilterButtonPresentation.symbolName(isActive: false)
        == "line.3.horizontal.decrease.circle")
    #expect(
      FilterButtonPresentation.symbolName(isActive: true)
        == "line.3.horizontal.decrease.circle.fill")
  }

  @Test("the toolbar funnel reflects the active state without changing the menu surface")
  func filterButtonGlyphReflectsState() {
    let active = FilterButton(accessibilityLabel: "Filters, 2 active", isActive: true) { EmptyView() }
    let inactive = FilterButton(accessibilityLabel: "Filters", isActive: false) { EmptyView() }

    #expect(active.symbolName == "line.3.horizontal.decrease.circle.fill")
    #expect(inactive.symbolName == "line.3.horizontal.decrease.circle")
    #expect(active.isActive)
    #expect(inactive.isActive == false)
  }

  @Test("the filter button exposes the caller-supplied accessibility label unchanged")
  func filterButtonExposesCallerSuppliedAccessibilityLabel() {
    // Dimension-aware wording is tested where the filter vocabulary exists. This target imports
    // no AppModel, so the component can only be handed a finished string.
    let button = FilterButton(accessibilityLabel: "Filters, 2 active", isActive: true) {
      Text("row")
    }
    #expect(button.accessibilityLabel == "Filters, 2 active")
    #expect(button.isActive)
    #expect(button.symbolName == "line.3.horizontal.decrease.circle.fill")
  }

  @Test("the filter button is constructible with no menu rows at all")
  func filterButtonIsConstructibleWithoutRows() {
    let button = FilterButton(accessibilityLabel: "Filters", isActive: false) { EmptyView() }
    #expect(button.symbolName == "line.3.horizontal.decrease.circle")
  }
}
