import SwiftUI

extension ReaderAppearanceControls {
  public var themeSelection: Binding<ReaderTheme> {
    Binding(get: { theme }, set: { theme = $0 })
  }

  public var fontFamilySelection: Binding<ReaderFontFamily> {
    Binding(get: { fontFamily }, set: { fontFamily = $0 })
  }

  public var fontSizeSelection: Binding<Double> {
    Binding(get: { fontSize }, set: { fontSize = $0 })
  }

  public var publisherStylesSelection: Binding<Bool> {
    Binding(get: { publisherStyles }, set: { publisherStyles = $0 })
  }

  public var alignmentSelection: Binding<ReaderTextAlignment> {
    Binding(get: { alignment }, set: { alignment = $0 })
  }

  public var lineSpacingSelection: Binding<Double> {
    Binding(get: { lineSpacing }, set: { lineSpacing = $0 })
  }

  public var wordSpacingSelection: Binding<Double> {
    Binding(get: { wordSpacing }, set: { wordSpacing = $0 })
  }

  public var letterSpacingSelection: Binding<Double> {
    Binding(get: { letterSpacing }, set: { letterSpacing = $0 })
  }

  public var paragraphSpacingSelection: Binding<Double> {
    Binding(get: { paragraphSpacing }, set: { paragraphSpacing = $0 })
  }

  public var hyphenationSelection: Binding<Bool> {
    Binding(get: { hyphenation }, set: { hyphenation = $0 })
  }

  public var marginsSelection: Binding<Double> {
    Binding(get: { margins }, set: { margins = $0 })
  }

  public var readingModeSelection: Binding<Bool> {
    Binding(get: { isScrollMode }, set: { isScrollMode = $0 })
  }

  public var brightnessSliderDescriptor: ReaderAppearanceSliderDescriptor? {
    guard let brightness else { return nil }
    return ReaderAppearanceSliderDescriptor(
      id: .brightness,
      label: brightnessLabel,
      accessibilityLabel: brightnessAccessibilityLabel,
      valueText: brightnessValue,
      accessibilityValue: brightnessValue,
      range: 0...1,
      isDisabled: false,
      isContinuous: true,
      handler: { value in brightness.wrappedValue = value }
    )
  }

  public var reflowControlsAreDisabled: Bool { isReflowable == false }
  public var fontFamilyControlsAreDisabled: Bool { reflowControlsAreDisabled }
  public var fontSizeStepperIsDisabled: Bool { reflowControlsAreDisabled }
  public var typographyControlsAreDisabled: Bool {
    reflowControlsAreDisabled || publisherStyles
  }
  public var publisherStylesControlsAreDisabled: Bool { reflowControlsAreDisabled }
  public var publisherStylesControlIsDisabled: Bool { publisherStylesControlsAreDisabled }
  public var alignmentControlsAreDisabled: Bool { typographyControlsAreDisabled }
  public var lineSpacingStepperIsDisabled: Bool { typographyControlsAreDisabled }
  public var wordSpacingStepperIsDisabled: Bool { typographyControlsAreDisabled }
  public var letterSpacingStepperIsDisabled: Bool { typographyControlsAreDisabled }
  public var paragraphSpacingStepperIsDisabled: Bool { typographyControlsAreDisabled }
  public var wordSpacingControlsAreDisabled: Bool { wordSpacingStepperIsDisabled }
  public var letterSpacingControlsAreDisabled: Bool { letterSpacingStepperIsDisabled }
  public var paragraphSpacingControlsAreDisabled: Bool { paragraphSpacingStepperIsDisabled }
  public var hyphenationControlsAreDisabled: Bool { typographyControlsAreDisabled }
  public var hyphenationControlIsDisabled: Bool { hyphenationControlsAreDisabled }
  public var marginsStepperIsDisabled: Bool { reflowControlsAreDisabled }
  public var readingModeControlIsDisabled: Bool { reflowControlsAreDisabled }

  public var selectedFontFamilyTitle: String {
    fontFamilyOptions.first { $0.family == fontFamily }?.title ?? fontFamilyAccessibilityLabel
  }

  public var selectedAlignmentTitle: String {
    alignmentOptions.first { $0.alignment == alignment }?.title ?? alignmentAccessibilityLabel
  }

  public var fontFamilyAccessibilityAnnouncement: String {
    accessibilityAnnouncement(for: selectedFontFamilyTitle)
  }

  public var fontSizeAccessibilityAnnouncement: String {
    accessibilityAnnouncement(for: fontSizeAccessibilityValue)
  }

  public var alignmentAccessibilityAnnouncement: String {
    accessibilityAnnouncement(for: selectedAlignmentTitle)
  }

  public var lineSpacingAccessibilityAnnouncement: String {
    accessibilityAnnouncement(for: lineSpacingAccessibilityValue)
  }

  public var wordSpacingAccessibilityAnnouncement: String {
    accessibilityAnnouncement(for: wordSpacingAccessibilityValue)
  }

  public var letterSpacingAccessibilityAnnouncement: String {
    accessibilityAnnouncement(for: letterSpacingAccessibilityValue)
  }

  public var paragraphSpacingAccessibilityAnnouncement: String {
    accessibilityAnnouncement(for: paragraphSpacingAccessibilityValue)
  }

  public var hyphenationAccessibilityAnnouncement: String {
    accessibilityAnnouncement(for: hyphenation ? hyphenationOnValue : hyphenationOffValue)
  }

  public var publisherStylesAccessibilityAnnouncement: String {
    accessibilityAnnouncement(for: publisherStyles ? publisherStylesOnValue : publisherStylesOffValue)
  }

  public var marginsAccessibilityAnnouncement: String {
    accessibilityAnnouncement(for: marginsAccessibilityValue)
  }

  public var readingModeAccessibilityAnnouncement: String {
    accessibilityAnnouncement(for: isScrollMode ? scrollLabel : paginatedLabel)
  }

  public func isSelected(_ option: ReaderThemeOption) -> Bool {
    option.theme == theme
  }

  public func isSelected(_ option: ReaderFontFamilyOption) -> Bool {
    option.family == fontFamily
  }

  public func isSelected(_ option: ReaderTextAlignmentOption) -> Bool {
    option.alignment == alignment
  }

  public var themeSwatches: [ReaderThemeSwatchDescriptor] {
    let selection = themeSelection
    return themeOptions.map { option in
      let selected = isSelected(option)
      return ReaderThemeSwatchDescriptor(
        option: option,
        isSelected: selected,
        accessibilityTraits: selected ? .isButton.union(.isSelected) : .isButton,
        handler: { selection.wrappedValue = option.theme }
      )
    }
  }

  public var fontFamilySelections: [ReaderFontFamilySelectionDescriptor] {
    let selection = fontFamilySelection
    let disabled = fontFamilyControlsAreDisabled
    return fontFamilyOptions.map { option in
      let selected = isSelected(option)
      return ReaderFontFamilySelectionDescriptor(
        option: option,
        accessibilityValue: accessibilityAnnouncement(for: option.title),
        isSelected: selected,
        isDisabled: disabled,
        accessibilityTraits: selected ? .isButton.union(.isSelected) : .isButton,
        handler: {
          guard disabled == false else { return }
          selection.wrappedValue = option.family
        }
      )
    }
  }

  public var alignmentSelections: [ReaderTextAlignmentSelectionDescriptor] {
    let selection = alignmentSelection
    let disabled = alignmentControlsAreDisabled
    return alignmentOptions.map { option in
      let selected = isSelected(option)
      return ReaderTextAlignmentSelectionDescriptor(
        option: option,
        accessibilityValue: accessibilityAnnouncement(for: option.accessibilityLabel),
        isSelected: selected,
        isDisabled: disabled,
        accessibilityTraits: selected ? .isButton.union(.isSelected) : .isButton,
        handler: {
          guard disabled == false else { return }
          selection.wrappedValue = option.alignment
        }
      )
    }
  }

  public var fontSizeControlDescriptor: ReaderAppearanceAdjustmentDescriptor {
    adjustmentDescriptor(
      selection: fontSizeSelection,
      range: fontSizeRange,
      step: fontSizeStep,
      label: fontSizeLabel,
      accessibilityLabel: fontSizeAccessibilityLabel,
      displayValue: fontSizeAccessibilityValue,
      accessibilityValue: fontSizeAccessibilityAnnouncement,
      decrement: fontSizeDecrement,
      increment: fontSizeIncrement,
      isDisabled: fontSizeStepperIsDisabled
    )
  }

  /// Text size as Books draws it: a small A and a large A, each a step, with no value between.
  public var textSizeControlDescriptor: ReaderAppearanceTextSizeDescriptor {
    let stepper = fontSizeControlDescriptor
    return ReaderAppearanceTextSizeDescriptor(
      accessibilityLabel: fontSizeAccessibilityLabel,
      accessibilityValue: fontSizeAccessibilityAnnouncement,
      isDisabled: fontSizeStepperIsDisabled,
      decrement: .init(
        glyph: fontSizeDecrement.text, glyphScale: 0.8,
        accessibilityLabel: fontSizeDecrement.accessibilityLabel,
        isDisabled: stepper.decrementIsDisabled, handler: stepper.decrement),
      increment: .init(
        glyph: fontSizeIncrement.text, glyphScale: 1.5,
        accessibilityLabel: fontSizeIncrement.accessibilityLabel,
        isDisabled: stepper.incrementIsDisabled, handler: stepper.increment))
  }

  public var lineSpacingControlDescriptor: ReaderAppearanceAdjustmentDescriptor {
    adjustmentDescriptor(
      selection: lineSpacingSelection,
      range: lineSpacingRange,
      step: lineSpacingStep,
      label: lineSpacingLabel,
      accessibilityLabel: lineSpacingAccessibilityLabel,
      displayValue: lineSpacingAccessibilityValue,
      accessibilityValue: lineSpacingAccessibilityAnnouncement,
      decrement: lineSpacingDecrement,
      increment: lineSpacingIncrement,
      isDisabled: lineSpacingStepperIsDisabled
    )
  }

  public var wordSpacingControlDescriptor: ReaderAppearanceAdjustmentDescriptor {
    adjustmentDescriptor(
      selection: wordSpacingSelection,
      range: wordSpacingRange,
      step: wordSpacingStep,
      label: wordSpacingLabel,
      accessibilityLabel: wordSpacingAccessibilityLabel,
      displayValue: wordSpacingAccessibilityValue,
      accessibilityValue: wordSpacingAccessibilityAnnouncement,
      decrement: wordSpacingDecrement,
      increment: wordSpacingIncrement,
      isDisabled: wordSpacingStepperIsDisabled
    )
  }

  public var letterSpacingControlDescriptor: ReaderAppearanceAdjustmentDescriptor {
    adjustmentDescriptor(
      selection: letterSpacingSelection,
      range: letterSpacingRange,
      step: letterSpacingStep,
      label: letterSpacingLabel,
      accessibilityLabel: letterSpacingAccessibilityLabel,
      displayValue: letterSpacingAccessibilityValue,
      accessibilityValue: letterSpacingAccessibilityAnnouncement,
      decrement: letterSpacingDecrement,
      increment: letterSpacingIncrement,
      isDisabled: letterSpacingStepperIsDisabled
    )
  }

  public var paragraphSpacingControlDescriptor: ReaderAppearanceAdjustmentDescriptor {
    adjustmentDescriptor(
      selection: paragraphSpacingSelection,
      range: paragraphSpacingRange,
      step: paragraphSpacingStep,
      label: paragraphSpacingLabel,
      accessibilityLabel: paragraphSpacingAccessibilityLabel,
      displayValue: paragraphSpacingAccessibilityValue,
      accessibilityValue: paragraphSpacingAccessibilityAnnouncement,
      decrement: paragraphSpacingDecrement,
      increment: paragraphSpacingIncrement,
      isDisabled: paragraphSpacingStepperIsDisabled
    )
  }

  public var hyphenationControlDescriptor: ReaderAppearanceToggleDescriptor {
    toggleDescriptor(
      id: .hyphenation,
      selection: hyphenationSelection,
      label: hyphenationLabel,
      accessibilityLabel: hyphenationAccessibilityLabel,
      onValue: hyphenationOnValue,
      offValue: hyphenationOffValue,
      isDisabled: hyphenationControlsAreDisabled
    )
  }

  public var publisherStylesControlDescriptor: ReaderAppearanceToggleDescriptor {
    toggleDescriptor(
      id: .publisherStyles,
      selection: publisherStylesSelection,
      label: publisherStylesLabel,
      accessibilityLabel: publisherStylesAccessibilityLabel,
      onValue: publisherStylesOnValue,
      offValue: publisherStylesOffValue,
      isDisabled: publisherStylesControlsAreDisabled
    )
  }

  public var marginsControlDescriptor: ReaderAppearanceAdjustmentDescriptor {
    adjustmentDescriptor(
      selection: marginsSelection,
      range: marginsRange,
      step: marginsStep,
      label: marginsLabel,
      accessibilityLabel: marginsAccessibilityLabel,
      displayValue: marginsAccessibilityValue,
      accessibilityValue: marginsAccessibilityAnnouncement,
      decrement: marginsDecrement,
      increment: marginsIncrement,
      isDisabled: marginsStepperIsDisabled
    )
  }

  public var reflowControlDescriptors: [ReaderAppearanceControlDescriptor] {
    [
      ReaderAppearanceControlDescriptor(
        id: .fontFamily,
        accessibilityLabel: fontFamilyAccessibilityLabel,
        accessibilityValue: fontFamilyAccessibilityAnnouncement,
        isDisabled: fontFamilyControlsAreDisabled
      ),
      ReaderAppearanceControlDescriptor(
        id: .fontSize,
        accessibilityLabel: fontSizeAccessibilityLabel,
        accessibilityValue: fontSizeAccessibilityAnnouncement,
        isDisabled: fontSizeStepperIsDisabled
      ),
      ReaderAppearanceControlDescriptor(
        id: .publisherStyles,
        accessibilityLabel: publisherStylesAccessibilityLabel,
        accessibilityValue: publisherStylesAccessibilityAnnouncement,
        isDisabled: publisherStylesControlsAreDisabled
      ),
      ReaderAppearanceControlDescriptor(
        id: .alignment,
        accessibilityLabel: alignmentAccessibilityLabel,
        accessibilityValue: alignmentAccessibilityAnnouncement,
        isDisabled: alignmentControlsAreDisabled
      ),
      ReaderAppearanceControlDescriptor(
        id: .lineSpacing,
        accessibilityLabel: lineSpacingAccessibilityLabel,
        accessibilityValue: lineSpacingAccessibilityAnnouncement,
        isDisabled: lineSpacingStepperIsDisabled
      ),
      ReaderAppearanceControlDescriptor(
        id: .wordSpacing,
        accessibilityLabel: wordSpacingAccessibilityLabel,
        accessibilityValue: wordSpacingAccessibilityAnnouncement,
        isDisabled: wordSpacingStepperIsDisabled
      ),
      ReaderAppearanceControlDescriptor(
        id: .letterSpacing,
        accessibilityLabel: letterSpacingAccessibilityLabel,
        accessibilityValue: letterSpacingAccessibilityAnnouncement,
        isDisabled: letterSpacingStepperIsDisabled
      ),
      ReaderAppearanceControlDescriptor(
        id: .paragraphSpacing,
        accessibilityLabel: paragraphSpacingAccessibilityLabel,
        accessibilityValue: paragraphSpacingAccessibilityAnnouncement,
        isDisabled: paragraphSpacingStepperIsDisabled
      ),
      ReaderAppearanceControlDescriptor(
        id: .hyphenation,
        accessibilityLabel: hyphenationAccessibilityLabel,
        accessibilityValue: hyphenationAccessibilityAnnouncement,
        isDisabled: hyphenationControlsAreDisabled
      ),
      ReaderAppearanceControlDescriptor(
        id: .margins,
        accessibilityLabel: marginsAccessibilityLabel,
        accessibilityValue: marginsAccessibilityAnnouncement,
        isDisabled: marginsStepperIsDisabled
      ),
      ReaderAppearanceControlDescriptor(
        id: .readingMode,
        accessibilityLabel: readingModeAccessibilityLabel,
        accessibilityValue: readingModeAccessibilityAnnouncement,
        isDisabled: readingModeControlIsDisabled
      ),
    ]
  }

  /// The identifier a control carries, or nil when the caller did not namespace this panel.
  public func identifier(_ suffix: String) -> String? {
    identifierPrefix.map { "\($0).\(suffix)" }
  }

  /// The sections this instance draws.
  public var sections: [ReaderAppearanceSection] { sections(for: level) }

  /// The sample the customise page pins above its scrolling rows. It is not a row: a sample that
  /// scrolls away is gone by the time the slider it demonstrates is reached.
  public var pinnedSample: AnyView? { level == .customise ? sample : nil }

  /// The panel's grouped structure. The first level is Books' half-sheet: text size, brightness,
  /// theme, and the way deeper. The customise level holds everything else; its font group needs
  /// no header because each of its rows already names itself.
  public func sections(for level: ReaderAppearanceLevel) -> [ReaderAppearanceSection] {
    let fixedLayoutUnavailable = reflowControlsAreDisabled ? disabledAccessibilityValue : nil
    if level == .essentials {
      return [
        ReaderAppearanceSection(
          id: .essentials,
          header: nil,
          footer: fixedLayoutUnavailable,
          rows: [.fontSize] + (brightness == nil ? [] : [.brightness]) + [.theme, .customise])
      ]
    }
    // Alignment and line spacing have no effect while publisher styles are on. The explicit
    // toggle stays truthful, and this footer makes that dependency legible.
    let typographyFooter =
      reflowControlsAreDisabled
      ? disabledAccessibilityValue
      : publisherStyles
        ? publisherStylesFooter
        : nil
    var sections: [ReaderAppearanceSection] = [
      ReaderAppearanceSection(
        id: .text, header: nil, footer: fixedLayoutUnavailable, rows: [.fontFamily]),
      ReaderAppearanceSection(
        id: .typography, header: typographyLabel, footer: typographyFooter,
        rows: [
          .publisherStyles, .alignment, .lineSpacing, .wordSpacing, .letterSpacing,
          .paragraphSpacing, .hyphenation,
        ]),
      ReaderAppearanceSection(
        id: .layout, header: layoutLabel, footer: fixedLayoutUnavailable,
        rows: [.margins, .readingMode]),
    ]
    if onReset != nil {
      sections.append(ReaderAppearanceSection(id: .reset, header: nil, footer: nil, rows: [.reset]))
    }
    return sections
  }

  private func adjustmentDescriptor(
    selection: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    label: String,
    accessibilityLabel: String,
    displayValue: String,
    accessibilityValue: String,
    decrement: ReaderAppearanceCellLabel,
    increment: ReaderAppearanceCellLabel,
    isDisabled: Bool
  ) -> ReaderAppearanceAdjustmentDescriptor {
    let currentValue = selection.wrappedValue
    let decrementIsDisabled = isDisabled || currentValue <= range.lowerBound
    let incrementIsDisabled = isDisabled || currentValue >= range.upperBound
    let cellAccessibilityTraits: AccessibilityTraits = .isButton
    let cells = [
      ReaderAppearanceControlCellDescriptor(
        id: .decrement,
        label: decrement.text,
        accessibilityLabel: decrement.accessibilityLabel,
        accessibilityValue: accessibilityValue,
        isDisabled: decrementIsDisabled,
        accessibilityTraits: cellAccessibilityTraits,
        handler: {
          Self.adjust(selection, by: -step, in: range, isDisabled: isDisabled)
        }
      ),
      ReaderAppearanceControlCellDescriptor(
        id: .value,
        label: displayValue,
        accessibilityLabel: accessibilityLabel,
        accessibilityValue: accessibilityValue,
        isDisabled: isDisabled,
        accessibilityTraits: [],
        handler: {}
      ),
      ReaderAppearanceControlCellDescriptor(
        id: .increment,
        label: increment.text,
        accessibilityLabel: increment.accessibilityLabel,
        accessibilityValue: accessibilityValue,
        isDisabled: incrementIsDisabled,
        accessibilityTraits: cellAccessibilityTraits,
        handler: {
          Self.adjust(selection, by: step, in: range, isDisabled: isDisabled)
        }
      ),
    ]

    return ReaderAppearanceAdjustmentDescriptor(
      label: label,
      accessibilityLabel: accessibilityLabel,
      displayValue: displayValue,
      accessibilityValue: accessibilityValue,
      isDisabled: isDisabled,
      decrementIsDisabled: decrementIsDisabled,
      incrementIsDisabled: incrementIsDisabled,
      cells: cells,
      dividerRole: theme.palette.divider,
      controlFillRole: theme.palette.controlFill,
      selectedControlFillRole: theme.palette.selectedControlFill,
      decrementHandler: {
        Self.adjust(selection, by: -step, in: range, isDisabled: isDisabled)
      },
      incrementHandler: {
        Self.adjust(selection, by: step, in: range, isDisabled: isDisabled)
      }
    )
  }

  private func toggleDescriptor(
    id: ReaderAppearanceControlDescriptor.ID,
    selection: Binding<Bool>,
    label: String,
    accessibilityLabel: String,
    onValue: String,
    offValue: String,
    isDisabled: Bool
  ) -> ReaderAppearanceToggleDescriptor {
    let isOn = selection.wrappedValue
    let value = isOn ? onValue : offValue
    return ReaderAppearanceToggleDescriptor(
      id: id,
      label: label,
      accessibilityLabel: accessibilityLabel,
      isOn: isOn,
      onValue: onValue,
      offValue: offValue,
      accessibilityValue: accessibilityAnnouncement(for: value),
      isDisabled: isDisabled,
      handler: { value in
        guard isDisabled == false else { return }
        selection.wrappedValue = value
      }
    )
  }

  private static func adjust(
    _ selection: Binding<Double>,
    by step: Double,
    in range: ClosedRange<Double>,
    isDisabled: Bool
  ) {
    guard isDisabled == false, step != 0 else { return }
    let currentValue = selection.wrappedValue
    let nextValue = min(max(currentValue + step, range.lowerBound), range.upperBound)
    guard nextValue != currentValue else { return }
    selection.wrappedValue = nextValue
  }

  private func accessibilityAnnouncement(for value: String) -> String {
    reflowControlsAreDisabled ? "\(value). \(disabledAccessibilityValue)" : value
  }
}
