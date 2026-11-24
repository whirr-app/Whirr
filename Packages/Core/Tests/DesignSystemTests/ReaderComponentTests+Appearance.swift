import SnapshotTesting
import SwiftUI
import Testing

@testable import DesignSystem

@MainActor
extension ReaderComponentTests {
  // MARK: - Appearance controls

  @Test("reader appearance controls drive every binding exactly once")
  func readerAppearanceControlsDriveEveryBindingExactlyOnce() {
    var theme = ReaderTheme.light
    var fontFamily = ReaderFontFamily.publisher
    var alignment = ReaderTextAlignment.publisherDefault
    var fontSize = 1.0
    var publisherStyles = false
    var lineSpacing = 1.0
    var wordSpacing = 0.0
    var letterSpacing = 0.0
    var paragraphSpacing = 0.0
    var hyphenation = false
    var margins = 0.0
    var isScrollMode = false
    var themeWrites = 0
    var fontFamilyWrites = 0
    var alignmentWrites = 0
    var fontSizeWrites = 0
    var publisherStylesWrites = 0
    var lineSpacingWrites = 0
    var wordSpacingWrites = 0
    var letterSpacingWrites = 0
    var paragraphSpacingWrites = 0
    var hyphenationWrites = 0
    var marginsWrites = 0
    var readingModeWrites = 0
    let controls = makeAppearanceControls(
      theme: Binding(
        get: { theme },
        set: {
          theme = $0
          themeWrites += 1
        }),
      fontFamily: Binding(
        get: { fontFamily },
        set: {
          fontFamily = $0
          fontFamilyWrites += 1
        }),
      alignment: Binding(
        get: { alignment },
        set: {
          alignment = $0
          alignmentWrites += 1
        }),
      fontSize: Binding(
        get: { fontSize },
        set: {
          fontSize = $0
          fontSizeWrites += 1
        }),
      publisherStyles: Binding(
        get: { publisherStyles },
        set: {
          publisherStyles = $0
          publisherStylesWrites += 1
        }),
      lineSpacing: Binding(
        get: { lineSpacing },
        set: {
          lineSpacing = $0
          lineSpacingWrites += 1
        }),
      wordSpacing: Binding(
        get: { wordSpacing },
        set: {
          wordSpacing = $0
          wordSpacingWrites += 1
        }),
      letterSpacing: Binding(
        get: { letterSpacing },
        set: {
          letterSpacing = $0
          letterSpacingWrites += 1
        }),
      paragraphSpacing: Binding(
        get: { paragraphSpacing },
        set: {
          paragraphSpacing = $0
          paragraphSpacingWrites += 1
        }),
      hyphenation: Binding(
        get: { hyphenation },
        set: {
          hyphenation = $0
          hyphenationWrites += 1
        }),
      margins: Binding(
        get: { margins },
        set: {
          margins = $0
          marginsWrites += 1
        }),
      isScrollMode: Binding(
        get: { isScrollMode },
        set: {
          isScrollMode = $0
          readingModeWrites += 1
        })
    )

    controls.themeSwatches.first { $0.theme == .dark }?.select()
    controls.fontFamilySelections.first { $0.family == .sansSerif }?.select()
    controls.fontSizeControlDescriptor.increment()
    controls.alignmentSelections.first { $0.alignment == .justify }?.select()
    controls.lineSpacingControlDescriptor.increment()
    controls.wordSpacingControlDescriptor.increment()
    controls.letterSpacingControlDescriptor.increment()
    controls.paragraphSpacingControlDescriptor.increment()
    controls.hyphenationControlDescriptor.toggle()
    controls.publisherStylesControlDescriptor.toggle()
    controls.marginsControlDescriptor.increment()
    controls.readingModeSelection.wrappedValue = true

    #expect(theme == .dark)
    #expect(fontFamily == .sansSerif)
    #expect(alignment == .justify)
    #expect(fontSize == 1.125)
    #expect(publisherStyles)
    #expect(lineSpacing == 1.1)
    #expect(wordSpacing == 1.0)
    #expect(letterSpacing == 1.0)
    #expect(paragraphSpacing == 1.0)
    #expect(hyphenation)
    #expect(margins == 0.25)
    #expect(isScrollMode)
    #expect(themeWrites == 1)
    #expect(fontFamilyWrites == 1)
    #expect(fontSizeWrites == 1)
    #expect(alignmentWrites == 1)
    #expect(lineSpacingWrites == 1)
    #expect(wordSpacingWrites == 1)
    #expect(letterSpacingWrites == 1)
    #expect(paragraphSpacingWrites == 1)
    #expect(hyphenationWrites == 1)
    #expect(marginsWrites == 1)
    #expect(publisherStylesWrites == 1)
    #expect(readingModeWrites == 1)
  }

  @Test("brightness is a live continuous theme slider and remains available for fixed layout")
  func brightnessIsALiveContinuousThemeSliderAndRemainsAvailableForFixedLayout() {
    var brightness = 0.42
    var writes = 0
    let controls = makeAppearanceControls(
      brightness: Binding(
        get: { brightness },
        set: {
          brightness = $0
          writes += 1
        }),
      brightnessValue: "42%",
      isReflowable: false
    )

    let descriptor = controls.brightnessSliderDescriptor
    #expect(descriptor?.id == .brightness)
    #expect(descriptor?.label == "Brightness")
    #expect(descriptor?.accessibilityLabel == "Screen brightness")
    #expect(descriptor?.valueText == "42%")
    #expect(descriptor?.accessibilityValue == "42%")
    #expect(descriptor?.range == 0...1)
    #expect(descriptor?.isContinuous == true)
    #expect(descriptor?.isDisabled == false)
    #expect(
      controls.sections(for: .essentials).first?.rows
        == [.fontSize, .brightness, .theme, .customise])
    #expect(controls.reflowControlDescriptors.contains { $0.id.rawValue == "brightness" } == false)

    descriptor?.set(0.63)
    #expect(brightness == 0.63)
    #expect(writes == 1)
  }

  @Test("brightness has no row when its screen capability is absent")
  func brightnessHasNoRowWhenItsScreenCapabilityIsAbsent() {
    let controls = makeAppearanceControls()

    #expect(controls.brightnessSliderDescriptor == nil)
    #expect(controls.sections(for: .essentials).first?.rows == [.fontSize, .theme, .customise])
  }

  @Test("reader appearance controls indicate selected themes and font rows")
  func readerAppearanceControlsIndicateSelectedThemesAndFontRows() {
    var theme = ReaderTheme.sepia
    var fontFamily = ReaderFontFamily.serif
    var alignment = ReaderTextAlignment.left
    let controls = makeAppearanceControls(
      theme: Binding(get: { theme }, set: { theme = $0 }),
      fontFamily: Binding(get: { fontFamily }, set: { fontFamily = $0 }),
      alignment: Binding(get: { alignment }, set: { alignment = $0 })
    )

    #expect(controls.isSelected(ReaderThemeOption(theme: .sepia, title: "Sepia", accessibilityLabel: "Sepia theme")))
    #expect(
      controls.isSelected(ReaderThemeOption(theme: .dark, title: "Dark", accessibilityLabel: "Dark theme")) == false)
    #expect(
      controls.isSelected(ReaderFontFamilyOption(family: .serif, title: "Serif", accessibilityLabel: "Serif font")))
    #expect(
      controls.isSelected(
        ReaderFontFamilyOption(family: .publisher, title: "Publisher", accessibilityLabel: "Publisher font")) == false)
    #expect(controls.isSelected(ReaderTextAlignmentOption(alignment: .left, title: "Left", accessibilityLabel: "Left")))
    #expect(
      controls.isSelected(
        ReaderTextAlignmentOption(
          alignment: .publisherDefault,
          title: "Publisher default",
          accessibilityLabel: "Publisher default")) == false)
  }

  @Test("reader appearance controls joined cells respect both boundaries")
  func readerAppearanceControlsJoinedCellsRespectBothBoundaries() {
    var minimumFontSize = 0.75
    var minimumWrites = 0
    let minimumControls = makeAppearanceControls(
      fontSize: Binding(
        get: { minimumFontSize },
        set: {
          minimumFontSize = $0
          minimumWrites += 1
        }),
      fontSizeAccessibilityValue: "0 points"
    )

    #expect(minimumControls.fontSizeControlDescriptor.decrementIsDisabled)
    #expect(minimumControls.fontSizeControlDescriptor.valueText == "0 points")
    minimumControls.fontSizeControlDescriptor.decrement()
    #expect(minimumFontSize == 0.75)
    #expect(minimumWrites == 0)

    var maximumFontSize = 2.0
    var maximumWrites = 0
    let maximumControls = makeAppearanceControls(
      fontSize: Binding(
        get: { maximumFontSize },
        set: {
          maximumFontSize = $0
          maximumWrites += 1
        }),
      fontSizeAccessibilityValue: "8 points"
    )

    #expect(maximumControls.fontSizeControlDescriptor.incrementIsDisabled)
    #expect(maximumControls.fontSizeControlDescriptor.valueText == "8 points")
    maximumControls.fontSizeControlDescriptor.increment()
    #expect(maximumFontSize == 2.0)
    #expect(maximumWrites == 0)
    #expect(maximumControls.fontSizeControlDescriptor.cells.count == 3)
    #expect(
      maximumControls.fontSizeControlDescriptor.cells.map(\.id)
        == [.decrement, .value, .increment])

    var minimumLineSpacing = 0.8
    var minimumLineSpacingWrites = 0
    let minimumLineSpacingControls = makeAppearanceControls(
      lineSpacing: Binding(
        get: { minimumLineSpacing },
        set: {
          minimumLineSpacing = $0
          minimumLineSpacingWrites += 1
        }),
      lineSpacingAccessibilityValue: "0.8 lines"
    )
    #expect(minimumLineSpacingControls.lineSpacingControlDescriptor.decrementIsDisabled)
    #expect(minimumLineSpacingControls.lineSpacingControlDescriptor.valueText == "0.8 lines")
    minimumLineSpacingControls.lineSpacingControlDescriptor.decrement()
    #expect(minimumLineSpacing == 0.8)
    #expect(minimumLineSpacingWrites == 0)

    var maximumLineSpacing = 2.0
    var maximumLineSpacingWrites = 0
    let maximumLineSpacingControls = makeAppearanceControls(
      lineSpacing: Binding(
        get: { maximumLineSpacing },
        set: {
          maximumLineSpacing = $0
          maximumLineSpacingWrites += 1
        }),
      lineSpacingAccessibilityValue: "2 lines"
    )
    #expect(maximumLineSpacingControls.lineSpacingControlDescriptor.incrementIsDisabled)
    #expect(maximumLineSpacingControls.lineSpacingControlDescriptor.valueText == "2 lines")
    maximumLineSpacingControls.lineSpacingControlDescriptor.increment()
    #expect(maximumLineSpacing == 2.0)
    #expect(maximumLineSpacingWrites == 0)

    var minimumMargins = 0.0
    var minimumMarginsWrites = 0
    let minimumMarginsControls = makeAppearanceControls(
      margins: Binding(
        get: { minimumMargins },
        set: {
          minimumMargins = $0
          minimumMarginsWrites += 1
        }),
      marginsAccessibilityValue: "0 margins"
    )
    #expect(minimumMarginsControls.marginsControlDescriptor.decrementIsDisabled)
    #expect(minimumMarginsControls.marginsControlDescriptor.valueText == "0 margins")
    minimumMarginsControls.marginsControlDescriptor.decrement()
    #expect(minimumMargins == 0.0)
    #expect(minimumMarginsWrites == 0)

    var maximumMargins = 1.0
    var maximumMarginsWrites = 0
    let maximumMarginsControls = makeAppearanceControls(
      margins: Binding(
        get: { maximumMargins },
        set: {
          maximumMargins = $0
          maximumMarginsWrites += 1
        }),
      marginsAccessibilityValue: "4 margins"
    )
    #expect(maximumMarginsControls.marginsControlDescriptor.incrementIsDisabled)
    #expect(maximumMarginsControls.marginsControlDescriptor.valueText == "4 margins")
    maximumMarginsControls.marginsControlDescriptor.increment()
    #expect(maximumMargins == 1.0)
    #expect(maximumMarginsWrites == 0)
  }

  @Test("fixed-layout appearance controls disable every reflow-dependent descriptor")
  func fixedLayoutAppearanceControlsDisableEveryReflowDependentDescriptor() {
    let controls = makeAppearanceControls(isReflowable: false)
    let expectedIDs: Set<ReaderAppearanceControlDescriptor.ID> = [
      .fontFamily,
      .fontSize,
      .publisherStyles,
      .alignment,
      .lineSpacing,
      .wordSpacing,
      .letterSpacing,
      .paragraphSpacing,
      .hyphenation,
      .margins,
      .readingMode,
    ]

    #expect(controls.reflowControlsAreDisabled)
    #expect(controls.fontFamilyControlsAreDisabled)
    #expect(controls.fontSizeStepperIsDisabled)
    #expect(controls.publisherStylesControlsAreDisabled)
    #expect(controls.alignmentControlsAreDisabled)
    #expect(controls.lineSpacingStepperIsDisabled)
    #expect(controls.wordSpacingStepperIsDisabled)
    #expect(controls.letterSpacingStepperIsDisabled)
    #expect(controls.paragraphSpacingStepperIsDisabled)
    #expect(controls.hyphenationControlsAreDisabled)
    #expect(controls.marginsStepperIsDisabled)
    #expect(controls.readingModeControlIsDisabled)
    #expect(Set(controls.reflowControlDescriptors.map(\.id)) == expectedIDs)
    #expect(controls.reflowControlDescriptors.allSatisfy { $0.isDisabled })
    #expect(
      controls.reflowControlDescriptors.allSatisfy {
        $0.accessibilityValue.hasSuffix("Unavailable for fixed-layout books")
      })
    #expect(controls.fontSizeAccessibilityAnnouncement == "18 points. Unavailable for fixed-layout books")
    #expect(controls.lineSpacingAccessibilityAnnouncement == "1.4 lines. Unavailable for fixed-layout books")
    #expect(controls.wordSpacingAccessibilityAnnouncement == "Default. Unavailable for fixed-layout books")
    #expect(controls.letterSpacingAccessibilityAnnouncement == "Default. Unavailable for fixed-layout books")
    #expect(controls.paragraphSpacingAccessibilityAnnouncement == "Default. Unavailable for fixed-layout books")
    #expect(controls.hyphenationAccessibilityAnnouncement == "Off. Unavailable for fixed-layout books")
    #expect(controls.publisherStylesAccessibilityAnnouncement == "Off. Unavailable for fixed-layout books")
    #expect(controls.alignmentAccessibilityAnnouncement == "Left. Unavailable for fixed-layout books")
    #expect(controls.marginsAccessibilityAnnouncement == "0 margins. Unavailable for fixed-layout books")
    #expect(controls.fontSizeControlDescriptor.cells.allSatisfy { $0.isDisabled })
    #expect(controls.lineSpacingControlDescriptor.cells.allSatisfy { $0.isDisabled })
    #expect(controls.wordSpacingControlDescriptor.cells.allSatisfy { $0.isDisabled })
    #expect(controls.letterSpacingControlDescriptor.cells.allSatisfy { $0.isDisabled })
    #expect(controls.paragraphSpacingControlDescriptor.cells.allSatisfy { $0.isDisabled })
    #expect(controls.marginsControlDescriptor.cells.allSatisfy { $0.isDisabled })
    #expect(controls.alignmentSelections.allSatisfy { $0.isDisabled })
  }

  @Test("reader appearance controls expose non-color selection indicators")
  func readerAppearanceControlsExposeNonColorSelectionIndicators() {
    let controls = makeAppearanceControls(theme: .constant(.sepia), alignment: .constant(.justify))
    let selectedTheme = controls.themeSwatches.first { $0.theme == .sepia }
    let selectedAlignment = controls.alignmentSelections.first { $0.alignment == .justify }

    #expect(selectedTheme?.hasSelectedRing == true)
    #expect(selectedTheme?.selectionIndicatorSystemImage == "checkmark")
    #expect(selectedTheme?.accessibilityTraits.contains(.isSelected) == true)
    #expect(selectedAlignment?.hasSelectedIndicator == true)
    #expect(selectedAlignment?.selectionIndicatorSystemImage == "checkmark")
    #expect(selectedAlignment?.accessibilityTraits.contains(.isSelected) == true)
  }

  @Test("reader appearance controls expose exactly three themes and alignment choices")
  func readerAppearanceControlsExposeExactlyThreeThemesAndAlignmentChoices() {
    let controls = makeAppearanceControls()

    #expect(controls.themeSwatches.count == 3)
    #expect(controls.themeSwatches.map(\.theme) == [.light, .sepia, .dark])
    #expect(controls.alignmentSelections.count == 3)
    #expect(
      controls.alignmentSelections.map(\.alignment)
        == [.publisherDefault, .left, .justify])
  }

  @Test("reader appearance controls expose evaluated numeric accessibility values")
  func readerAppearanceControlsExposeEvaluatedNumericAccessibilityValues() {
    let controls = makeAppearanceControls(
      fontSizeAccessibilityValue: "18 points",
      lineSpacingAccessibilityValue: "1.4 lines",
      wordSpacingAccessibilityValue: "0.25em",
      letterSpacingAccessibilityValue: "0.25em",
      paragraphSpacingAccessibilityValue: "0.5em",
      marginsAccessibilityValue: "2 margins"
    )

    #expect(controls.fontSizeControlDescriptor.valueText == "18 points")
    #expect(controls.lineSpacingControlDescriptor.valueText == "1.4 lines")
    #expect(controls.wordSpacingControlDescriptor.valueText == "0.25em")
    #expect(controls.letterSpacingControlDescriptor.valueText == "0.25em")
    #expect(controls.paragraphSpacingControlDescriptor.valueText == "0.5em")
    #expect(controls.marginsControlDescriptor.valueText == "2 margins")
    #expect(controls.fontSizeAccessibilityAnnouncement == "18 points")
    #expect(controls.lineSpacingAccessibilityAnnouncement == "1.4 lines")
    #expect(controls.marginsAccessibilityAnnouncement == "2 margins")
    #expect(controls.fontSizeControlDescriptor.valueText.contains("Int(") == false)
    #expect(controls.lineSpacingControlDescriptor.valueText.contains("Int(") == false)
    #expect(controls.wordSpacingControlDescriptor.valueText.contains("Int(") == false)
    #expect(controls.letterSpacingControlDescriptor.valueText.contains("Int(") == false)
    #expect(controls.paragraphSpacingControlDescriptor.valueText.contains("Int(") == false)
    #expect(controls.marginsControlDescriptor.valueText.contains("Int(") == false)
  }

  @Test("reader appearance toggle descriptors carry caller values and actions")
  func readerAppearanceToggleDescriptorsCarryCallerValuesAndActions() {
    var publisherStyles = false
    var hyphenation = false
    var publisherStylesWrites = 0
    var hyphenationWrites = 0
    let controls = makeAppearanceControls(
      publisherStyles: Binding(
        get: { publisherStyles },
        set: {
          publisherStyles = $0
          publisherStylesWrites += 1
        }),
      hyphenation: Binding(
        get: { hyphenation },
        set: {
          hyphenation = $0
          hyphenationWrites += 1
        })
    )

    #expect(controls.publisherStylesControlDescriptor.id == .publisherStyles)
    #expect(controls.publisherStylesControlDescriptor.valueText == "Off")
    #expect(controls.publisherStylesControlDescriptor.accessibilityValue == "Off")
    #expect(controls.hyphenationControlDescriptor.id == .hyphenation)
    #expect(controls.hyphenationControlDescriptor.valueText == "Off")
    #expect(controls.hyphenationControlDescriptor.accessibilityValue == "Off")

    controls.hyphenationControlDescriptor.toggle()
    controls.publisherStylesControlDescriptor.toggle()
    #expect(publisherStyles)
    #expect(hyphenation)
    #expect(publisherStylesWrites == 1)
    #expect(hyphenationWrites == 1)

    #expect(controls.typographyControlsAreDisabled)
    #expect(controls.alignmentControlsAreDisabled)
    #expect(controls.wordSpacingStepperIsDisabled)
    #expect(controls.hyphenationControlsAreDisabled)
    #expect(
      controls.sections(for: .customise).first { $0.id == .typography }?.footer
        == "Publisher styles footer")
    #expect(controls.hyphenationControlDescriptor.accessibilityValue == "On")

    controls.hyphenationControlDescriptor.toggle()
    #expect(hyphenation)
    #expect(hyphenationWrites == 1)
  }

  @Test("fixed-layout appearance controls are disabled and announce their unavailable state")
  func fixedLayoutAppearanceControlsAreDisabledAndAnnounceUnavailableState() {
    let controls = makeAppearanceControls(isReflowable: false)

    #expect(controls.reflowControlsAreDisabled)
    #expect(controls.fontFamilyControlsAreDisabled)
    #expect(controls.fontSizeStepperIsDisabled)
    #expect(controls.publisherStylesControlsAreDisabled)
    #expect(controls.alignmentControlsAreDisabled)
    #expect(controls.lineSpacingStepperIsDisabled)
    #expect(controls.wordSpacingStepperIsDisabled)
    #expect(controls.letterSpacingStepperIsDisabled)
    #expect(controls.paragraphSpacingStepperIsDisabled)
    #expect(controls.hyphenationControlsAreDisabled)
    #expect(controls.marginsStepperIsDisabled)
    #expect(controls.readingModeControlIsDisabled)
    #expect(controls.fontSizeAccessibilityAnnouncement == "18 points. Unavailable for fixed-layout books")
    #expect(controls.lineSpacingAccessibilityAnnouncement == "1.4 lines. Unavailable for fixed-layout books")
    #expect(controls.wordSpacingAccessibilityAnnouncement == "Default. Unavailable for fixed-layout books")
    #expect(controls.letterSpacingAccessibilityAnnouncement == "Default. Unavailable for fixed-layout books")
    #expect(controls.paragraphSpacingAccessibilityAnnouncement == "Default. Unavailable for fixed-layout books")
    #expect(controls.hyphenationAccessibilityAnnouncement == "Off. Unavailable for fixed-layout books")
    #expect(controls.publisherStylesAccessibilityAnnouncement == "Off. Unavailable for fixed-layout books")
    #expect(controls.alignmentAccessibilityAnnouncement == "Left. Unavailable for fixed-layout books")
    #expect(controls.marginsAccessibilityAnnouncement == "0 margins. Unavailable for fixed-layout books")
  }

  @Test("a disabled adjustment row shows its value, never its spoken announcement")
  func disabledAdjustmentRowsShowTheirValueWithoutTheAnnouncement() {
    let controls = makeAppearanceControls(isReflowable: false)

    // The unavailable note belongs to VoiceOver and the section footer. As the row's value it
    // would put a sentence where a number goes and wrap the row to four lines.
    #expect(controls.fontSizeControlDescriptor.valueText == "18 points")
    #expect(controls.lineSpacingControlDescriptor.valueText == "1.4 lines")
    #expect(controls.marginsControlDescriptor.valueText == "0 margins")
    #expect(
      controls.fontSizeControlDescriptor.cells
        .first { $0.id == .value }?.label == "18 points")
    #expect(
      controls.fontSizeControlDescriptor.accessibilityValue
        == "18 points. Unavailable for fixed-layout books")
  }

  @Test("the first level holds the everyday controls, as Books' half-sheet does")
  func essentialsLevelHoldsTheEverydayControls() {
    let controls = makeAppearanceControls(brightness: .constant(0.5))
    let sections = controls.sections(for: .essentials)

    #expect(sections.map(\.id) == [.essentials])
    #expect(sections.flatMap(\.rows) == [.fontSize, .brightness, .theme, .customise])
    #expect(sections.allSatisfy { $0.footer == nil })
    #expect(controls.sections == sections)
  }

  @Test("the customise level groups the rest like the app's settings list")
  func customiseLevelGroupsTheRestLikeTheSettingsList() {
    let controls = makeAppearanceControls(level: .customise)
    let sections = controls.sections

    #expect(sections.map(\.id) == [.text, .typography, .layout])
    // A group of self-naming rows takes no header, as in the app's own settings list.
    #expect(sections.map(\.header) == [nil, "Typography", "Layout"])
    #expect(
      sections.flatMap(\.rows) == [
        .fontFamily, .publisherStyles, .alignment, .lineSpacing,
        .wordSpacing, .letterSpacing, .paragraphSpacing, .hyphenation, .margins, .readingMode,
      ])
    #expect(sections.allSatisfy { $0.footer == nil })
  }

  @Test("text size is a small-A, large-A pair that steps within its bounds")
  func textSizeIsASmallAndLargeAPair() {
    var size = 1.0
    let controls = makeAppearanceControls(
      fontSize: Binding(get: { size }, set: { size = $0 }))
    let pair = controls.textSizeControlDescriptor

    #expect(pair.decrement.glyphScale < pair.increment.glyphScale)
    #expect(pair.decrement.accessibilityLabel == "Decrease font size")
    #expect(pair.increment.accessibilityLabel == "Increase font size")
    #expect(pair.accessibilityValue == "18 points")

    pair.increment.perform()
    #expect(size == 1.125)
    pair.decrement.perform()
    pair.decrement.perform()
    #expect(size == 0.875)

    size = 2.0
    #expect(controls.textSizeControlDescriptor.increment.isDisabled)
    size = 0.75
    #expect(controls.textSizeControlDescriptor.decrement.isDisabled)
  }

  @Test("the customise level pins the live sample above its rows and closes with reset")
  func customiseLevelPinsItsSampleAndClosesWithReset() {
    var resets = 0
    let controls = makeAppearanceControls(
      level: .customise, sample: AnyView(Text("Sample")), onReset: { resets += 1 })

    // The sample stays in view above the scrolling rows, so it is not one of them.
    #expect(controls.sections.map(\.id) == [.text, .typography, .layout, .reset])
    #expect(controls.pinnedSample != nil)
    #expect(controls.sections.last?.rows == [.reset])
    #expect(controls.resetLabel == "Reset to defaults")

    controls.onReset?()
    #expect(resets == 1)
  }

  @Test("spacing and margin rows are sliders with a symbol at each end and no value")
  func spacingRowsAreSymbolEndedSliders() {
    let rows: [ReaderAppearanceRow] = [
      .lineSpacing, .paragraphSpacing, .wordSpacing, .letterSpacing, .margins,
    ]
    for row in rows {
      let symbols = ReaderAppearanceControls.sliderEndSymbols(for: row)
      #expect(symbols != nil)
      #expect(symbols?.minimum != symbols?.maximum)
    }
    #expect(ReaderAppearanceControls.sliderEndSymbols(for: .fontSize) == nil)
  }

  @Test("brightness is a symbol-ended slider with no printed value")
  func brightnessIsASymbolEndedSlider() {
    let symbols = ReaderAppearanceControls.sliderEndSymbols(for: .brightness)
    #expect(symbols?.minimum == "sun.min")
    #expect(symbols?.maximum == "sun.max")
  }

  @Test("only the customise level pins a sample")
  func essentialsLevelPinsNoSample() {
    let controls = makeAppearanceControls(level: .essentials, sample: AnyView(Text("Sample")))
    #expect(controls.pinnedSample == nil)
  }

  @Test("the customise row carries the caller's label")
  func customiseRowCarriesTheCallersLabel() {
    #expect(makeAppearanceControls().customiseLabel == "Customise")
  }

  @Test("a fixed-layout book explains its disabled rows in the footer below them")
  func fixedLayoutAppearanceControlsExplainThemselvesInAFooter() {
    let controls = makeAppearanceControls(isReflowable: false)
    func footer(_ id: ReaderAppearanceSection.ID) -> String? {
      (controls.sections(for: .essentials) + controls.sections(for: .customise))
        .first { $0.id == id }?.footer
    }

    // Text size is the one reflow control on the first level; theme and brightness keep working.
    #expect(footer(.essentials) == "Unavailable for fixed-layout books")
    #expect(footer(.text) == "Unavailable for fixed-layout books")
    #expect(footer(.typography) == "Unavailable for fixed-layout books")
    #expect(footer(.layout) == "Unavailable for fixed-layout books")
  }

  @Test("publisher styles explain why typography rows are disabled")
  func publisherStylesExplainWhyTypographyRowsAreDisabled() {
    let sections = makeAppearanceControls(publisherStyles: .constant(true))
      .sections(for: .customise)
    func footer(_ id: ReaderAppearanceSection.ID) -> String? {
      sections.first { $0.id == id }?.footer
    }

    #expect(footer(.text) == nil)
    #expect(footer(.typography) == "Publisher styles footer")
    #expect(footer(.layout) == nil)
  }

  @Test("reader grouped rows sit lighter than their canvas", arguments: ReaderTheme.allCases)
  func readerGroupedRowsSitLighterThanTheirCanvas(theme: ReaderTheme) {
    let palette = theme.palette
    let surfaces = [palette.background, palette.chromeBackground]

    // The system's grouped list puts a lighter card on a darker canvas in both appearances, and
    // the panel earns its native look only by following that relationship in every reading theme.
    #expect(surfaces.contains(palette.groupedRowBackground))
    #expect(surfaces.contains(palette.groupedBackground))
    #expect(palette.groupedRowBackground.relativeLuminance > palette.groupedBackground.relativeLuminance)
  }

  @Test("reader appearance controls semantic snapshot")
  func readerAppearanceControlsSemanticSnapshot() {
    let controls = makeAppearanceControls()
    assertSnapshot(of: semanticSurface(of: controls), as: .dump)
  }
}
