import SwiftUI

/// A value-driven theme swatch descriptor. The view uses the same descriptor that tests can use to
/// exercise selection without rendering a host application.
public struct ReaderThemeSwatchDescriptor: Identifiable {
  public let theme: ReaderTheme
  public let title: String
  public let accessibilityLabel: String
  public let isSelected: Bool
  public let hasSelectedRing: Bool
  public let selectionIndicatorSystemImage: String?
  public let accessibilityTraits: AccessibilityTraits

  private let handler: () -> Void

  public var id: ReaderTheme { theme }

  init(
    option: ReaderThemeOption,
    isSelected: Bool,
    accessibilityTraits: AccessibilityTraits,
    handler: @escaping () -> Void
  ) {
    self.theme = option.theme
    self.title = option.title
    self.accessibilityLabel = option.accessibilityLabel
    self.isSelected = isSelected
    self.hasSelectedRing = isSelected
    self.selectionIndicatorSystemImage = isSelected ? "checkmark" : nil
    self.accessibilityTraits = accessibilityTraits
    self.handler = handler
  }

  public func select() {
    handler()
  }
}

/// A value-driven font-family selection descriptor for the font menu.
public struct ReaderFontFamilySelectionDescriptor: Identifiable {
  public let family: ReaderFontFamily
  public let title: String
  public let accessibilityLabel: String
  public let accessibilityValue: String
  public let isSelected: Bool
  public let isDisabled: Bool
  public let selectionIndicatorSystemImage: String?
  public let accessibilityTraits: AccessibilityTraits

  private let handler: () -> Void

  public var id: ReaderFontFamily { family }

  init(
    option: ReaderFontFamilyOption,
    accessibilityValue: String,
    isSelected: Bool,
    isDisabled: Bool,
    accessibilityTraits: AccessibilityTraits,
    handler: @escaping () -> Void
  ) {
    self.family = option.family
    self.title = option.title
    self.accessibilityLabel = option.accessibilityLabel
    self.accessibilityValue = accessibilityValue
    self.isSelected = isSelected
    self.isDisabled = isDisabled
    self.selectionIndicatorSystemImage = isSelected ? "checkmark" : nil
    self.accessibilityTraits = accessibilityTraits
    self.handler = handler
  }

  public func select() {
    handler()
  }
}

/// A value-driven alignment selection descriptor. Selected alignment has both a selected trait and
/// a check glyph so its state is not conveyed by fill color alone.
public struct ReaderTextAlignmentSelectionDescriptor: Identifiable {
  public let alignment: ReaderTextAlignment
  public let title: String
  public let accessibilityLabel: String
  public let accessibilityValue: String
  public let isSelected: Bool
  public let isDisabled: Bool
  public let hasSelectedIndicator: Bool
  public let selectionIndicatorSystemImage: String?
  public let accessibilityTraits: AccessibilityTraits

  private let handler: () -> Void

  public var id: ReaderTextAlignment { alignment }

  init(
    option: ReaderTextAlignmentOption,
    accessibilityValue: String,
    isSelected: Bool,
    isDisabled: Bool,
    accessibilityTraits: AccessibilityTraits,
    handler: @escaping () -> Void
  ) {
    self.alignment = option.alignment
    self.title = option.title
    self.accessibilityLabel = option.accessibilityLabel
    self.accessibilityValue = accessibilityValue
    self.isSelected = isSelected
    self.isDisabled = isDisabled
    self.hasSelectedIndicator = isSelected
    self.selectionIndicatorSystemImage = isSelected ? "checkmark" : nil
    self.accessibilityTraits = accessibilityTraits
    self.handler = handler
  }

  public func select() {
    handler()
  }
}

/// One cell in a joined minus/value/plus control.
public struct ReaderAppearanceControlCellDescriptor: Identifiable {
  public enum ID: String, CaseIterable, Sendable {
    case decrement
    case value
    case increment
  }

  public let id: ID
  public let label: String
  public let accessibilityLabel: String
  public let accessibilityValue: String
  public let isDisabled: Bool
  public let accessibilityTraits: AccessibilityTraits
  public let minimumHitTarget: CGFloat

  private let handler: () -> Void

  init(
    id: ID,
    label: String,
    accessibilityLabel: String,
    accessibilityValue: String,
    isDisabled: Bool,
    accessibilityTraits: AccessibilityTraits,
    handler: @escaping () -> Void
  ) {
    self.id = id
    self.label = label
    self.accessibilityLabel = accessibilityLabel
    self.accessibilityValue = accessibilityValue
    self.isDisabled = isDisabled
    self.accessibilityTraits = accessibilityTraits
    self.minimumHitTarget = WhirrMetric.minimumTouchTarget
    self.handler = handler
  }

  public func invoke() {
    handler()
  }
}

/// A compact joined control descriptor. Its cells retain the actual binding actions, boundary
/// state, and palette roles used by the rendered control.
public struct ReaderAppearanceAdjustmentDescriptor {
  public let label: String
  public let accessibilityLabel: String
  /// What the row shows. Separate from `accessibilityValue`, which carries the unavailable
  /// announcement a fixed-layout book appends for VoiceOver.
  public let displayValue: String
  public let accessibilityValue: String
  public let isDisabled: Bool
  public let decrementIsDisabled: Bool
  public let incrementIsDisabled: Bool
  public let cells: [ReaderAppearanceControlCellDescriptor]
  public let borderWidth: CGFloat
  public let dividerRole: WhirrRGBColor
  public let controlFillRole: WhirrRGBColor
  public let selectedControlFillRole: WhirrRGBColor

  private let decrementHandler: () -> Void
  private let incrementHandler: () -> Void

  init(
    label: String,
    accessibilityLabel: String,
    displayValue: String,
    accessibilityValue: String,
    isDisabled: Bool,
    decrementIsDisabled: Bool,
    incrementIsDisabled: Bool,
    cells: [ReaderAppearanceControlCellDescriptor],
    dividerRole: WhirrRGBColor,
    controlFillRole: WhirrRGBColor,
    selectedControlFillRole: WhirrRGBColor,
    decrementHandler: @escaping () -> Void,
    incrementHandler: @escaping () -> Void
  ) {
    self.label = label
    self.accessibilityLabel = accessibilityLabel
    self.displayValue = displayValue
    self.accessibilityValue = accessibilityValue
    self.isDisabled = isDisabled
    self.decrementIsDisabled = decrementIsDisabled
    self.incrementIsDisabled = incrementIsDisabled
    self.cells = cells
    self.borderWidth = 1
    self.dividerRole = dividerRole
    self.controlFillRole = controlFillRole
    self.selectedControlFillRole = selectedControlFillRole
    self.decrementHandler = decrementHandler
    self.incrementHandler = incrementHandler
  }

  public var valueText: String { displayValue }

  public func decrement() {
    decrementHandler()
  }

  public func increment() {
    incrementHandler()
  }
}

/// A joined adjustment cell's visible glyph and its spoken label. The two differ: the
/// cell reads "A−" on screen and "Decrease font size" to VoiceOver.
public struct ReaderAppearanceCellLabel: Sendable, Equatable {
  public let text: String
  public let accessibilityLabel: String

  public init(text: String, accessibilityLabel: String) {
    self.text = text
    self.accessibilityLabel = accessibilityLabel
  }
}

/// The reflow-dependent control matrix. The descriptor keeps the unavailable announcement
/// testable for every control without coupling DesignSystem to the reader model.
public struct ReaderAppearanceControlDescriptor: Identifiable {
  public enum ID: String, CaseIterable, Sendable {
    case fontFamily
    case fontSize
    case publisherStyles
    case alignment
    case lineSpacing
    case wordSpacing
    case letterSpacing
    case paragraphSpacing
    case hyphenation
    case margins
    case readingMode
  }

  public let id: ID
  public let accessibilityLabel: String
  public let accessibilityValue: String
  public let isDisabled: Bool
}

/// A value-driven toggle descriptor. The value text remains caller-owned so a reader can localize
/// its on/off terminology while DesignSystem still carries the unavailable announcement.
public struct ReaderAppearanceToggleDescriptor: Identifiable {
  public let id: ReaderAppearanceControlDescriptor.ID
  public let label: String
  public let accessibilityLabel: String
  public let valueText: String
  public let accessibilityValue: String
  public let isOn: Bool
  public let isDisabled: Bool
  public let onValue: String
  public let offValue: String

  private let handler: (Bool) -> Void

  init(
    id: ReaderAppearanceControlDescriptor.ID,
    label: String,
    accessibilityLabel: String,
    isOn: Bool,
    onValue: String,
    offValue: String,
    accessibilityValue: String,
    isDisabled: Bool,
    handler: @escaping (Bool) -> Void
  ) {
    self.id = id
    self.label = label
    self.accessibilityLabel = accessibilityLabel
    self.valueText = isOn ? onValue : offValue
    self.accessibilityValue = accessibilityValue
    self.isOn = isOn
    self.isDisabled = isDisabled
    self.onValue = onValue
    self.offValue = offValue
    self.handler = handler
  }

  public func set(_ value: Bool) {
    handler(value)
  }

  public func toggle() {
    handler(!isOn)
  }
}

/// One row of the appearance panel's grouped list, in the order the panel lays them out.
public enum ReaderAppearanceRow: String, CaseIterable, Identifiable, Sendable, Equatable {
  case theme
  case brightness
  case fontFamily
  case fontSize
  case publisherStyles
  case alignment
  case lineSpacing
  case wordSpacing
  case letterSpacing
  case paragraphSpacing
  case hyphenation
  case margins
  case readingMode
  case customise
  case reset

  public var id: Self { self }
}

/// The two pages of the appearance panel, after Books: the everyday controls in a half-sheet, and
/// everything else one push deeper. Also the navigation value that pushes the second page.
public enum ReaderAppearanceLevel: Hashable, Sendable {
  case essentials
  case customise
}

/// The small-A, large-A text-size pair. It shows no value; VoiceOver speaks the caller's.
public struct ReaderAppearanceTextSizeDescriptor {
  public struct Cell {
    public let glyph: String
    /// The glyph's size relative to body text, so the pair reads as smaller and larger.
    public let glyphScale: Double
    public let accessibilityLabel: String
    public let isDisabled: Bool
    private let handler: () -> Void

    public init(
      glyph: String, glyphScale: Double, accessibilityLabel: String, isDisabled: Bool,
      handler: @escaping () -> Void
    ) {
      self.glyph = glyph
      self.glyphScale = glyphScale
      self.accessibilityLabel = accessibilityLabel
      self.isDisabled = isDisabled
      self.handler = handler
    }

    public func perform() {
      guard isDisabled == false else { return }
      handler()
    }
  }

  public let accessibilityLabel: String
  public let accessibilityValue: String
  public let isDisabled: Bool
  public let decrement: Cell
  public let increment: Cell
}

/// A continuous slider row. Its value is caller-owned so the reader can provide live device state
/// and localized copy without making DesignSystem depend on ReaderCore or AppModel.
public struct ReaderAppearanceSliderDescriptor: Identifiable {
  public let id: ReaderAppearanceRow
  public let label: String
  public let accessibilityLabel: String
  public let valueText: String
  public let accessibilityValue: String
  public let range: ClosedRange<Double>
  public let isDisabled: Bool
  public let isContinuous: Bool

  private let handler: (Double) -> Void

  init(
    id: ReaderAppearanceRow,
    label: String,
    accessibilityLabel: String,
    valueText: String,
    accessibilityValue: String,
    range: ClosedRange<Double>,
    isDisabled: Bool,
    isContinuous: Bool,
    handler: @escaping (Double) -> Void
  ) {
    self.id = id
    self.label = label
    self.accessibilityLabel = accessibilityLabel
    self.valueText = valueText
    self.accessibilityValue = accessibilityValue
    self.range = range
    self.isDisabled = isDisabled
    self.isContinuous = isContinuous
    self.handler = handler
  }

  public func set(_ value: Double) {
    guard isDisabled == false else { return }
    handler(min(max(value, range.lowerBound), range.upperBound))
  }
}

/// One group of rows in the appearance panel. The panel is a grouped list like the app's own
/// settings screen, so its structure is a value the tests can read without rendering a host.
public struct ReaderAppearanceSection: Identifiable, Sendable, Equatable {
  public enum ID: String, CaseIterable, Sendable {
    case essentials
    case theme
    case text
    case typography
    case layout
    case reset
  }

  public let id: ID
  /// `nil` renders the group without a header, which is what a set of self-naming rows wants.
  public let header: String?
  /// Carries the caller's unavailable announcement when this group holds disabled rows, so a
  /// fixed-layout book says why its controls are greyed out where they are greyed out.
  public let footer: String?
  public let rows: [ReaderAppearanceRow]
}
