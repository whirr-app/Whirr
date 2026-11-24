import SwiftUI

extension ReaderAppearanceControls {
  @ViewBuilder
  public var body: some View {
    let palette = theme.palette

    Form {
      ForEach(sections) { section in
        Section {
          ForEach(section.rows) { row in
            self.row(row, palette: palette)
          }
        } header: {
          if let header = section.header {
            Text(header)
              .foregroundStyle(palette.secondaryForegroundColor)
          }
        } footer: {
          if let footer = section.footer {
            Text(footer)
              .foregroundStyle(palette.secondaryForegroundColor)
          }
        }
        .listRowBackground(palette.groupedRowBackgroundColor)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .safeAreaInset(edge: .top, spacing: 0) {
      if let pinnedSample {
        pinnedSample
          // The grouped list's section margin plus its row inset, so the sample's text starts
          // where the rows' names do.
          .padding(.horizontal, WhirrSpacing.medium * 2)
          .padding(.bottom, WhirrSpacing.xSmall)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(palette.groupedBackgroundColor)
          .overlay(alignment: .bottom) { Divider() }
          .accessibilityIdentifier(identifier(Self.sampleIdentifierSuffix) ?? "")
      }
    }
    // The half-sheet's own glass is the essentials page's canvas, so the page shows through it
    // as a change is made; the full-height customise page takes the theme's grouped canvas.
    .background(canvasColor(palette: palette).ignoresSafeArea())
    // The panel keeps the page's own theme rather than the app's: a sepia reader that opens a
    // stock grey settings sheet reads as a different app's screen.
    .tint(palette.accentColor)
    .environment(\.colorScheme, theme == .dark ? .dark : .light)
  }

  @ViewBuilder
  private func row(_ row: ReaderAppearanceRow, palette: ReaderThemePalette) -> some View {
    switch row {
    case .theme:
      themeRow(palette: palette)
        .accessibilityIdentifier(identifier(Self.themesIdentifierSuffix) ?? "")
    case .brightness:
      if let brightness, let descriptor = brightnessSliderDescriptor {
        brightnessRow(brightness, descriptor: descriptor, palette: palette)
          .accessibilityIdentifier(identifier(Self.brightnessIdentifierSuffix) ?? "")
      }
    case .fontFamily:
      fontFamilyRow(palette: palette)
        .accessibilityIdentifier(identifier(Self.fontRowIdentifierSuffix) ?? "")
    case .fontSize:
      textSizeRow(textSizeControlDescriptor, palette: palette)
        .accessibilityIdentifier(identifier(Self.fontSizeIdentifierSuffix) ?? "")
    case .publisherStyles:
      toggleRow(publisherStylesControlDescriptor, palette: palette)
        .accessibilityIdentifier(identifier(Self.publisherStylesIdentifierSuffix) ?? "")
    case .alignment:
      alignmentRow(palette: palette)
        .accessibilityIdentifier(identifier(Self.layoutIdentifierSuffix) ?? "")
    case .lineSpacing:
      sliderRow(
        lineSpacingControlDescriptor, row: row, selection: lineSpacingSelection,
        range: lineSpacingRange, step: lineSpacingStep, palette: palette
      )
      .accessibilityIdentifier(identifier(Self.lineSpacingIdentifierSuffix) ?? "")
    case .wordSpacing:
      sliderRow(
        wordSpacingControlDescriptor, row: row, selection: wordSpacingSelection,
        range: wordSpacingRange, step: wordSpacingStep, palette: palette
      )
      .accessibilityIdentifier(identifier(Self.wordSpacingIdentifierSuffix) ?? "")
    case .letterSpacing:
      sliderRow(
        letterSpacingControlDescriptor, row: row, selection: letterSpacingSelection,
        range: letterSpacingRange, step: letterSpacingStep, palette: palette
      )
      .accessibilityIdentifier(identifier(Self.letterSpacingIdentifierSuffix) ?? "")
    case .paragraphSpacing:
      sliderRow(
        paragraphSpacingControlDescriptor, row: row, selection: paragraphSpacingSelection,
        range: paragraphSpacingRange, step: paragraphSpacingStep, palette: palette
      )
      .accessibilityIdentifier(identifier(Self.paragraphSpacingIdentifierSuffix) ?? "")
    case .hyphenation:
      toggleRow(hyphenationControlDescriptor, palette: palette)
        .accessibilityIdentifier(identifier(Self.hyphenationIdentifierSuffix) ?? "")
    case .margins:
      sliderRow(
        marginsControlDescriptor, row: row, selection: marginsSelection,
        range: marginsRange, step: marginsStep, palette: palette
      )
      .accessibilityIdentifier(identifier(Self.marginsIdentifierSuffix) ?? "")
    case .readingMode:
      readingModeRow(palette: palette)
        .accessibilityIdentifier(identifier(Self.readingModeIdentifierSuffix) ?? "")
    case .customise:
      NavigationLink(value: ReaderAppearanceLevel.customise) {
        Text(customiseLabel)
          .font(Self.bodyTextToken.font)
          .foregroundStyle(palette.foregroundColor)
      }
      .frame(minHeight: WhirrMetric.minimumTouchTarget)
      .accessibilityIdentifier(identifier(Self.customiseIdentifierSuffix) ?? "")
    case .reset:
      if let onReset {
        Button(resetLabel, action: onReset)
          .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
          .disabled(reflowControlsAreDisabled)
          .accessibilityIdentifier(identifier(Self.resetIdentifierSuffix) ?? "")
      }
    }
  }

  /// The symbols at each end of a spacing slider: the setting drawn tight and drawn loose. They
  /// stand in for a printed value.
  public static func sliderEndSymbols(
    for row: ReaderAppearanceRow
  ) -> (minimum: String, maximum: String)? {
    switch row {
    case .lineSpacing, .paragraphSpacing:
      ("arrow.down.and.line.horizontal.and.arrow.up", "arrow.up.and.line.horizontal.and.arrow.down")
    case .wordSpacing, .letterSpacing:
      ("arrow.right.and.line.vertical.and.arrow.left", "arrow.left.and.line.vertical.and.arrow.right")
    case .margins:
      ("rectangle.portrait", "rectangle.portrait.inset.filled")
    case .brightness:
      ("sun.min", "sun.max")
    default:
      nil
    }
  }

  /// A stepped native slider with its name above and a symbol at each end, as Books draws its
  /// spacing controls. It shows no value: the live sample shows the effect, and VoiceOver speaks
  /// the caller's word for the step.
  private func sliderRow(
    _ descriptor: ReaderAppearanceAdjustmentDescriptor,
    row: ReaderAppearanceRow,
    selection: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    palette: ReaderThemePalette
  ) -> some View {
    let symbols = Self.sliderEndSymbols(for: row)
    return VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
      Text(descriptor.label)
        .font(Self.bodyTextToken.font)
        .foregroundStyle(rowLabelColor(isDisabled: descriptor.isDisabled, palette: palette))
      Slider(value: selection, in: range, step: step) {
        Text(descriptor.label)
      } minimumValueLabel: {
        sliderEndSymbol(symbols?.minimum ?? "minus")
      } maximumValueLabel: {
        sliderEndSymbol(symbols?.maximum ?? "plus")
      }
      .foregroundStyle(palette.secondaryForegroundColor)
      .tint(palette.accentColor)
      .accessibilityLabel(descriptor.accessibilityLabel)
      .accessibilityValue(descriptor.accessibilityValue)
    }
    .frame(minHeight: WhirrMetric.minimumTouchTarget)
    .disabled(descriptor.isDisabled)
  }

  /// Every slider's end symbols share one width, so the tracks between them line up down the page.
  static let sliderEndSymbolWidth: CGFloat = 28

  private func sliderEndSymbol(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .frame(width: Self.sliderEndSymbolWidth)
      .accessibilityHidden(true)
  }

  /// Two halves of one row, split by a hairline: the small A steps down and the large A steps up,
  /// as in Books. Plain buttons, because a Form row fires every default-styled button it holds.
  private func textSizeRow(
    _ descriptor: ReaderAppearanceTextSizeDescriptor,
    palette: ReaderThemePalette
  ) -> some View {
    HStack(spacing: 0) {
      textSizeButton(descriptor.decrement, descriptor: descriptor, palette: palette)
      Divider()
        .frame(height: WhirrMetric.minimumTouchTarget * 0.6)
      textSizeButton(descriptor.increment, descriptor: descriptor, palette: palette)
    }
    // A row with no leading text would start its separator under the first glyph.
    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    .disabled(descriptor.isDisabled)
  }

  private func textSizeButton(
    _ cell: ReaderAppearanceTextSizeDescriptor.Cell,
    descriptor: ReaderAppearanceTextSizeDescriptor,
    palette: ReaderThemePalette
  ) -> some View {
    Button(action: cell.perform) {
      Text(cell.glyph)
        .font(.system(size: 17 * cell.glyphScale, weight: .regular, design: .serif))
        .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(
      rowLabelColor(isDisabled: cell.isDisabled || descriptor.isDisabled, palette: palette)
    )
    .disabled(cell.isDisabled)
    .accessibilityLabel(cell.accessibilityLabel)
    .accessibilityValue(descriptor.accessibilityValue)
  }

  /// The theme swatches, laid out as the one row in the panel that is worth showing as colour.
  private func themeRow(palette: ReaderThemePalette) -> some View {
    HStack(spacing: 0) {
      ForEach(themeSwatches) { swatch in
        Button(action: swatch.select) {
          VStack(spacing: WhirrSpacing.xSmall) {
            ZStack {
              Circle()
                .fill(swatch.theme.palette.backgroundColor)
              Circle()
                .stroke(
                  swatch.hasSelectedRing
                    ? palette.accentColor
                    : nonTextContrastColor(
                      preferred: palette.divider,
                      on: swatch.theme.palette.background
                    ).color,
                  lineWidth: swatch.hasSelectedRing ? 2.5 : 1
                )
              if let systemImage = swatch.selectionIndicatorSystemImage {
                Image(systemName: systemImage)
                  .font(.body.weight(.semibold))
                  .foregroundStyle(swatch.theme.palette.foregroundColor)
                  .accessibilityHidden(true)
              }
            }
            .frame(width: WhirrMetric.minimumTouchTarget, height: WhirrMetric.minimumTouchTarget)

            Text(swatch.title)
              .font(Self.sectionTextToken.font)
              .foregroundStyle(
                swatch.isSelected ? palette.foregroundColor : palette.secondaryForegroundColor)
          }
          .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swatch.accessibilityLabel)
        .accessibilityAddTraits(swatch.accessibilityTraits)
      }
    }
    .padding(.vertical, WhirrSpacing.xSmall)
    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(themeAccessibilityLabel)
  }

  private func fontFamilyRow(palette: ReaderThemePalette) -> some View {
    menuRow(
      label: fontLabel,
      value: selectedFontFamilyTitle,
      isDisabled: fontFamilyControlsAreDisabled,
      palette: palette
    ) {
      Picker(fontLabel, selection: fontFamilySelection) {
        ForEach(fontFamilySelections) { option in
          Text(option.title)
            .font(option.family.sampleFont)
            .accessibilityLabel(option.accessibilityLabel)
            .tag(option.family)
        }
      }
      .pickerStyle(.inline)
    }
    .accessibilityLabel(fontFamilyAccessibilityLabel)
    .accessibilityValue(fontFamilyAccessibilityAnnouncement)
  }

  private func alignmentRow(palette: ReaderThemePalette) -> some View {
    menuRow(
      label: alignmentAccessibilityLabel,
      value: selectedAlignmentTitle,
      isDisabled: alignmentControlsAreDisabled,
      palette: palette
    ) {
      Picker(alignmentAccessibilityLabel, selection: alignmentSelection) {
        ForEach(alignmentSelections) { selection in
          Text(selection.title)
            .accessibilityLabel(selection.accessibilityLabel)
            .tag(selection.alignment)
        }
      }
      .pickerStyle(.inline)
    }
    .accessibilityLabel(alignmentAccessibilityLabel)
    .accessibilityValue(alignmentAccessibilityAnnouncement)
  }

  private func readingModeRow(palette: ReaderThemePalette) -> some View {
    let selection = readingModeSelection
    return menuRow(
      label: readingModeAccessibilityLabel,
      value: isScrollMode ? scrollLabel : paginatedLabel,
      isDisabled: readingModeControlIsDisabled,
      palette: palette
    ) {
      Picker(readingModeAccessibilityLabel, selection: selection) {
        Text(paginatedLabel).tag(false)
        Text(scrollLabel).tag(true)
      }
      .pickerStyle(.inline)
    }
    .accessibilityLabel(readingModeAccessibilityLabel)
    .accessibilityValue(readingModeAccessibilityAnnouncement)
  }

  private func toggleRow(
    _ descriptor: ReaderAppearanceToggleDescriptor,
    palette: ReaderThemePalette
  ) -> some View {
    Toggle(
      isOn: Binding(
        get: { descriptor.isOn },
        set: { descriptor.set($0) }
      )
    ) {
      Text(descriptor.label)
        .font(Self.bodyTextToken.font)
        .foregroundStyle(rowLabelColor(isDisabled: descriptor.isDisabled, palette: palette))
    }
    .frame(minHeight: WhirrMetric.minimumTouchTarget)
    .disabled(descriptor.isDisabled)
    .accessibilityLabel(descriptor.accessibilityLabel)
    .accessibilityValue(descriptor.accessibilityValue)
  }

  private func brightnessRow(
    _ selection: Binding<Double>,
    descriptor: ReaderAppearanceSliderDescriptor,
    palette: ReaderThemePalette
  ) -> some View {
    // Drawn like the spacing sliders, with no printed percentage: the screen shows the effect,
    // and VoiceOver still speaks the value.
    let symbols = Self.sliderEndSymbols(for: .brightness)
    return Slider(value: selection, in: descriptor.range) {
      Text(descriptor.label)
    } minimumValueLabel: {
      sliderEndSymbol(symbols?.minimum ?? "minus")
    } maximumValueLabel: {
      sliderEndSymbol(symbols?.maximum ?? "plus")
    }
    .foregroundStyle(palette.secondaryForegroundColor)
    .tint(palette.accentColor)
    .accessibilityLabel(descriptor.accessibilityLabel)
    .accessibilityValue(descriptor.accessibilityValue)
    .frame(minHeight: WhirrMetric.minimumTouchTarget)
  }

  /// A row that behaves as a system menu picker does: the setting's name leading, its current
  /// value and the menu indicator trailing, the whole row opening the menu.
  private func menuRow<Options: View>(
    label: String,
    value: String,
    isDisabled: Bool,
    palette: ReaderThemePalette,
    @ViewBuilder options: () -> Options
  ) -> some View {
    Menu {
      options()
    } label: {
      HStack(spacing: WhirrSpacing.small) {
        Text(label)
          .font(Self.bodyTextToken.font)
          .foregroundStyle(rowLabelColor(isDisabled: isDisabled, palette: palette))
        Spacer(minLength: WhirrSpacing.small)
        Text(value)
          .font(Self.bodyTextToken.font)
          .lineLimit(1)
        Image(systemName: Self.menuIndicatorSystemImage)
          .font(.caption2.weight(.semibold))
          .accessibilityHidden(true)
      }
      .foregroundStyle(palette.secondaryForegroundColor)
      .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
      .contentShape(Rectangle())
    }
    .disabled(isDisabled)
  }

  private func canvasColor(palette: ReaderThemePalette) -> Color {
    level == .essentials ? .clear : palette.groupedBackgroundColor
  }

  /// A row whose control is unavailable drops its name to the secondary role, because a palette
  /// foreground set explicitly is a colour SwiftUI's own disabled dimming can no longer reach.
  private func rowLabelColor(isDisabled: Bool, palette: ReaderThemePalette) -> Color {
    isDisabled ? palette.secondaryForegroundColor : palette.foregroundColor
  }
}
