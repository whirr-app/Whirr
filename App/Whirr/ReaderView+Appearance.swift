import AppModel
import DesignSystem
import Persistence
import ReaderCore
import SwiftUI

extension ReaderView {
  var appearanceSheet: some View {
    panelSheet(title: ReaderCopy.appearance, isPresented: $isShowingAppearance) {
      appearanceControls(level: .essentials)
        // Clear glass is for the half-sheet over the page. At full height there is no page left
        // to see, and the glass only lenses the blurred page into a stray inset panel.
        .background {
          if appearanceDetent == .large {
            palette.groupedBackgroundColor.ignoresSafeArea()
          }
        }
        .navigationDestination(for: ReaderAppearanceLevel.self) { level in
          appearanceControls(level: level)
            .navigationTitle(ReaderCopy.customise)
            // The deeper page is a full list; Books grows its sheet for it too.
            .onAppear { appearanceDetent = .large }
            .animation(.smooth, value: appearanceDetent)
            .task { sampleText = await (renderer as? ReadiumEPUBRenderer)?.sampleParagraphs() }
        }
    }
  }

  private func appearanceControls(level: ReaderAppearanceLevel) -> some View {
    // Hoisted so the long initializer below stays cheap to type-check.
    let sample: AnyView? =
      ReaderPresentation.showsTypographySample(level: level, detent: appearanceDetent)
      ? AnyView(typographySample) : nil
    let onReset: (() -> Void)? = level == .customise ? { resetTypography() } : nil
    return ReaderAppearanceControls(
      theme: $draftTheme,
      themeOptions: [
        ReaderThemeOption(
          theme: .light, title: ReaderCopy.light, accessibilityLabel: ReaderCopy.lightTheme),
        ReaderThemeOption(
          theme: .sepia, title: ReaderCopy.sepia, accessibilityLabel: ReaderCopy.sepiaTheme),
        ReaderThemeOption(
          theme: .dark, title: ReaderCopy.dark, accessibilityLabel: ReaderCopy.darkTheme),
      ],
      themeLabel: ReaderCopy.themes,
      themeAccessibilityLabel: ReaderCopy.readerTheme,
      fontFamily: $draftFontFamily,
      fontFamilyOptions: [
        ReaderFontFamilyOption(
          family: .publisher, title: ReaderCopy.publisher, accessibilityLabel: ReaderCopy.publisherFont),
        ReaderFontFamilyOption(
          family: .serif, title: ReaderCopy.serif, accessibilityLabel: ReaderCopy.serifFont),
        ReaderFontFamilyOption(
          family: .sansSerif, title: ReaderCopy.sansSerif, accessibilityLabel: ReaderCopy.sansSerifFont),
        ReaderFontFamilyOption(
          family: .monospaced, title: ReaderCopy.monospaced, accessibilityLabel: ReaderCopy.monospacedFont),
        ReaderFontFamilyOption(
          family: .openDyslexic, title: ReaderCopy.openDyslexic,
          accessibilityLabel: ReaderCopy.openDyslexicFont),
      ],
      fontLabel: ReaderCopy.font,
      fontFamilyAccessibilityLabel: ReaderCopy.readerFont,
      fontSize: $draftFontSize,
      fontSizeRange: 0...Double(ReaderPreferences.fontSizeStepBounds.upperBound),
      fontSizeStep: 1,
      fontSizeLabel: ReaderCopy.fontSize,
      fontSizeAccessibilityLabel: ReaderCopy.fontSize,
      fontSizeAccessibilityValue: ReaderCopy.fontSizeValue(step: Int(draftFontSize.rounded())),
      fontSizeDecrement: ReaderAppearanceCellLabel(
        text: ReaderCopy.decreaseFontSizeGlyph, accessibilityLabel: ReaderCopy.decreaseFontSize),
      fontSizeIncrement: ReaderAppearanceCellLabel(
        text: ReaderCopy.increaseFontSizeGlyph, accessibilityLabel: ReaderCopy.increaseFontSize),
      publisherStyles: $draftPublisherStyles,
      publisherStylesLabel: ReaderCopy.publisherStyles,
      publisherStylesAccessibilityLabel: ReaderCopy.publisherStyles,
      publisherStylesOnValue: ReaderCopy.on,
      publisherStylesOffValue: ReaderCopy.off,
      alignment: $draftAlignment,
      alignmentOptions: [
        ReaderTextAlignmentOption(
          alignment: .publisherDefault, title: ReaderCopy.publisherDefault,
          accessibilityLabel: ReaderCopy.publisherDefaultAlignment),
        ReaderTextAlignmentOption(
          alignment: .left, title: ReaderCopy.left, accessibilityLabel: ReaderCopy.leftAlignment),
        ReaderTextAlignmentOption(
          alignment: .justify, title: ReaderCopy.justify,
          accessibilityLabel: ReaderCopy.justifiedAlignment),
      ],
      layoutLabel: ReaderCopy.layout,
      alignmentAccessibilityLabel: ReaderCopy.textAlignment,
      lineSpacing: $draftLineSpacing,
      lineSpacingRange: 0...Double(ReaderPreferences.lineSpacingStepBounds.upperBound),
      lineSpacingStep: 1,
      lineSpacingLabel: ReaderCopy.lineSpacing,
      lineSpacingAccessibilityLabel: ReaderCopy.lineSpacing,
      lineSpacingAccessibilityValue: ReaderCopy.lineSpacingValue(
        step: Int(draftLineSpacing.rounded())),
      lineSpacingDecrement: ReaderAppearanceCellLabel(
        text: ReaderCopy.decreaseGlyph, accessibilityLabel: ReaderCopy.decreaseLineSpacing),
      lineSpacingIncrement: ReaderAppearanceCellLabel(
        text: ReaderCopy.increaseGlyph, accessibilityLabel: ReaderCopy.increaseLineSpacing),
      wordSpacing: $draftWordSpacing,
      wordSpacingRange: 0...Double(ReaderPreferences.wordSpacingStepBounds.upperBound),
      wordSpacingStep: 1,
      wordSpacingLabel: ReaderCopy.wordSpacing,
      wordSpacingAccessibilityLabel: ReaderCopy.wordSpacing,
      wordSpacingAccessibilityValue: ReaderCopy.wordSpacingValue(
        step: Int(draftWordSpacing.rounded())),
      wordSpacingDecrement: ReaderAppearanceCellLabel(
        text: ReaderCopy.decreaseGlyph, accessibilityLabel: ReaderCopy.decreaseWordSpacing),
      wordSpacingIncrement: ReaderAppearanceCellLabel(
        text: ReaderCopy.increaseGlyph, accessibilityLabel: ReaderCopy.increaseWordSpacing),
      letterSpacing: $draftLetterSpacing,
      letterSpacingRange: 0...Double(ReaderPreferences.letterSpacingStepBounds.upperBound),
      letterSpacingStep: 1,
      letterSpacingLabel: ReaderCopy.letterSpacing,
      letterSpacingAccessibilityLabel: ReaderCopy.letterSpacing,
      letterSpacingAccessibilityValue: ReaderCopy.letterSpacingValue(
        step: Int(draftLetterSpacing.rounded())),
      letterSpacingDecrement: ReaderAppearanceCellLabel(
        text: ReaderCopy.decreaseGlyph, accessibilityLabel: ReaderCopy.decreaseLetterSpacing),
      letterSpacingIncrement: ReaderAppearanceCellLabel(
        text: ReaderCopy.increaseGlyph, accessibilityLabel: ReaderCopy.increaseLetterSpacing),
      paragraphSpacing: $draftParagraphSpacing,
      paragraphSpacingRange: 0...Double(ReaderPreferences.paragraphSpacingStepBounds.upperBound),
      paragraphSpacingStep: 1,
      paragraphSpacingLabel: ReaderCopy.paragraphSpacing,
      paragraphSpacingAccessibilityLabel: ReaderCopy.paragraphSpacing,
      paragraphSpacingAccessibilityValue: ReaderCopy.paragraphSpacingValue(
        step: Int(draftParagraphSpacing.rounded())),
      paragraphSpacingDecrement: ReaderAppearanceCellLabel(
        text: ReaderCopy.decreaseGlyph, accessibilityLabel: ReaderCopy.decreaseParagraphSpacing),
      paragraphSpacingIncrement: ReaderAppearanceCellLabel(
        text: ReaderCopy.increaseGlyph, accessibilityLabel: ReaderCopy.increaseParagraphSpacing),
      hyphenation: $draftHyphenation,
      hyphenationLabel: ReaderCopy.hyphenation,
      hyphenationAccessibilityLabel: ReaderCopy.hyphenation,
      hyphenationOnValue: ReaderCopy.on,
      hyphenationOffValue: ReaderCopy.off,
      margins: $draftMargins,
      marginsRange: 0...Double(ReaderPreferences.marginsStepBounds.upperBound),
      marginsStep: 1,
      marginsLabel: ReaderCopy.margins,
      marginsAccessibilityLabel: ReaderCopy.margins,
      marginsAccessibilityValue: ReaderCopy.marginsValue(step: Int(draftMargins.rounded())),
      marginsDecrement: ReaderAppearanceCellLabel(
        text: ReaderCopy.decreaseGlyph, accessibilityLabel: ReaderCopy.decreaseMargins),
      marginsIncrement: ReaderAppearanceCellLabel(
        text: ReaderCopy.increaseGlyph, accessibilityLabel: ReaderCopy.increaseMargins),
      isScrollMode: $draftScrollMode,
      paginatedLabel: ReaderCopy.pages,
      scrollLabel: ReaderCopy.scroll,
      readingModeAccessibilityLabel: ReaderCopy.readingMode,
      isReflowable: model.reflowControlsEnabled,
      disabledAccessibilityValue: ReaderCopy.fixedLayoutUnavailable,
      typographyLabel: ReaderCopy.typography,
      publisherStylesFooter: ReaderCopy.publisherStylesFooter,
      brightness: brightnessSelection,
      brightnessLabel: ReaderCopy.brightness,
      brightnessAccessibilityLabel: ReaderCopy.readerBrightness,
      brightnessValue: ReaderCopy.brightnessValue(brightnessLevelForDisplay),
      customiseLabel: ReaderCopy.customise,
      level: level,
      sample: sample,
      resetLabel: ReaderCopy.resetTypography,
      onReset: onReset,
      identifierPrefix: ReaderAccessibilityID.appearancePanel
    )
    .onChange(of: draftTheme) { _, _ in submitAppearance() }
    .onChange(of: draftFontFamily) { _, _ in submitAppearance() }
    .onChange(of: draftAlignment) { _, _ in submitAppearance() }
    .onChange(of: draftFontSize) { _, _ in submitAppearance() }
    .onChange(of: draftPublisherStyles) { _, _ in submitAppearance() }
    .onChange(of: draftLineSpacing) { _, _ in submitAppearance() }
    .onChange(of: draftWordSpacing) { _, _ in submitAppearance() }
    .onChange(of: draftLetterSpacing) { _, _ in submitAppearance() }
    .onChange(of: draftParagraphSpacing) { _, _ in submitAppearance() }
    .onChange(of: draftHyphenation) { _, _ in submitAppearance() }
    .onChange(of: draftMargins) { _, _ in submitAppearance() }
    .onChange(of: draftScrollMode) { _, _ in submitAppearance() }
  }

  func beginAppearanceEdit() {
    syncAppearanceDraft(with: model.preferences)
    appearanceDetent = .medium
    isShowingAppearance = true
  }

  private var brightnessLevelForDisplay: Double {
    brightnessController?.overrideLevel ?? brightnessLevel
  }

  private var brightnessSelection: Binding<Double>? {
    guard let brightnessController else { return nil }
    return Binding(
      get: { brightnessController.overrideLevel ?? brightnessLevel },
      set: { level in
        brightnessController.setOverride(level)
        brightnessLevel = brightnessController.overrideLevel ?? level
      }
    )
  }

  func syncAppearanceDraft(with preferences: ReaderPreferences) {
    draftTheme = ReaderPresentation.designTheme(
      for: preferences.theme, systemScheme: systemColorScheme)
    draftFontFamily = ReaderPresentation.designFont(for: preferences.fontFamily)
    draftAlignment = ReaderPresentation.designAlignment(for: preferences.textAlignment)
    draftFontSize = Double(preferences.fontSizeStep)
    draftPublisherStyles = preferences.publisherStyles
    draftLineSpacing = Double(preferences.lineSpacingStep)
    draftWordSpacing = Double(preferences.wordSpacingStep)
    draftLetterSpacing = Double(preferences.letterSpacingStep)
    draftParagraphSpacing = Double(preferences.paragraphSpacingStep)
    draftHyphenation = preferences.hyphenation
    draftMargins = Double(preferences.marginsStep)
    draftScrollMode = preferences.isScrollMode
  }

  /// Submits one whole preference value. A theme tap must not reset margins, alignment or reading
  /// mode, and it converts a `.system` reader to the swatch they just chose.
  private var typographySample: some View {
    ReaderTypographySample(
      text: sampleText ?? ReaderCopy.typographySampleFallback,
      preferences: draftPreferences,
      palette: draftTheme.palette)
  }

  /// Typography only: the theme, brightness, and reading mode stay as the reader left them.
  private func resetTypography() {
    let next = draftPreferences.resettingTypography()
    syncAppearanceDraft(with: next)
    Task { await model.updatePreferences(next) }
  }

  private func submitAppearance() {
    Task { await model.updatePreferences(draftPreferences) }
  }

  /// The panel's current choices as one whole preference value.
  private var draftPreferences: ReaderPreferences {
    ReaderPreferences(
      theme: ReaderPresentation.coreTheme(for: draftTheme),
      fontFamily: ReaderPresentation.coreFont(for: draftFontFamily),
      fontSizeStep: Int(draftFontSize.rounded()),
      lineSpacingStep: Int(draftLineSpacing.rounded()),
      marginsStep: Int(draftMargins.rounded()),
      readingMode: draftScrollMode ? .scroll : .paginated,
      textAlignment: ReaderPresentation.coreAlignment(for: draftAlignment),
      wordSpacingStep: Int(draftWordSpacing.rounded()),
      letterSpacingStep: Int(draftLetterSpacing.rounded()),
      paragraphSpacingStep: Int(draftParagraphSpacing.rounded()),
      hyphenation: draftHyphenation,
      publisherStyles: draftPublisherStyles,
      // Chosen by tapping the footer, not in this panel.
      footerReadout: model.preferences.footerReadout,
      reflowable: model.preferences.reflowable
    )
  }

}
