import SwiftUI

public enum MediaFilterPickerStyle: Equatable, Sendable {
  case segmented
  case chips
  /// Labels on the metadata ladder with a rule under the selected one, and no fill anywhere.
  ///
  /// For a picker on an ambient page, where the system segmented control cannot join the ladder:
  /// its own track and pure-white selected pill are brighter than the title ink above it, on a
  /// ground solved for the ladder's rungs. The rule is ink, not the accent, which
  /// `WhirrMetadataProminence` reserves for the two focal actions (Resume, play/pause disc).
  case underline
}

/// The Home and Library screens' media-kind filter: All / Audiobooks / Podcasts / eBooks.
///
/// A system segmented control (four options, inside the HIG's five-segment limit on iPhone), so it
/// follows light/dark appearance, Dynamic Type and Increase Contrast without owning a colour.
///
/// Labels are caller-supplied strings, not `MediaFilter` cases: this target imports no `AppModel`
/// (ARCHITECTURE.md layering). The App target maps `MediaFilter.allCases`/
/// `MediaFilterCopy.label(for:)` to `labels` and reads the chosen index back the same way.
public struct MediaFilterPicker: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public let title: String
  public let labels: [String]
  public let selectedIndex: Int
  public let style: MediaFilterPickerStyle
  /// What fills the selected chip, for a screen that has a colour of its own to spend. Nil keeps
  /// brand ink, which is what the screens with no cover to draw from use.
  public let selectionTint: Color?
  /// Chips that show but refuse the tap: a source the page cannot offer right now. Rendered
  /// dimmed and reported disabled to assistive technology.
  public let disabledIndices: Set<Int>
  public let onSelect: (Int) -> Void

  public init(
    title: String,
    labels: [String],
    selectedIndex: Int,
    style: MediaFilterPickerStyle = .segmented,
    selectionTint: Color? = nil,
    disabledIndices: Set<Int> = [],
    onSelect: @escaping (Int) -> Void
  ) {
    self.title = title
    self.labels = labels
    self.selectedIndex = selectedIndex
    self.style = style
    self.selectionTint = selectionTint
    self.disabledIndices = disabledIndices
    self.onSelect = onSelect
  }

  public func isSelected(_ index: Int) -> Bool { index == selectedIndex }

  public func isDisabled(_ index: Int) -> Bool { disabledIndices.contains(index) }

  /// The selected chip's fill and the ink laid on it, decided together.
  ///
  /// A borrowed cover accent can fall under 4.5:1 against a fixed ink (the yellow-to-cyan arc in
  /// the light appearance), so it goes through the resolver. `brandInk` on paper is the app's own
  /// pinned pair and keeps its exact values.
  private var selectionColors: (fill: Color, ink: Color) {
    guard let selectionTint else {
      return (WhirrColorToken.brandInk.color, WhirrColorToken.editorialBackground.color)
    }
    return legibleAccentColors(for: selectionTint)
  }

  public var selectionFill: Color { selectionColors.fill }

  /// The ink for the selected chip. Unselected chips are not on the accent at all, so they keep
  /// the page's secondary text colour.
  public var selectionInk: Color { selectionColors.ink }

  /// The ladder rung an underline tab's label is drawn at. Unselected tabs sit a step down: far
  /// enough back that the selected one reads as chosen, not so far that the others look disabled.
  public static func underlineProminence(isSelected: Bool) -> WhirrMetadataProminence {
    isSelected ? .primary : .tertiary
  }

  /// The rule does not travel between segments. The tab content swaps instantly and the list
  /// underneath rebuilds, so a sliding rule would animate a move the page does not make. It
  /// changes place in one step, with a short fade to avoid snapping.
  public static func underlineSelectionAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.12)
  }

  /// Owned by the shared control so Home, Podcasts and podcast-show filters stay in step even when
  /// their scroll containers use different animation transactions.
  public static func chipSelectionAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .snappy(duration: 0.35)
  }

  /// A derived binding, not stored state: the model owns the current filter, so a write reports
  /// the new index outward instead of forking a second copy.
  public var selection: Binding<Int> {
    Binding(get: { selectedIndex }, set: { onSelect($0) })
  }

  public var body: some View {
    switch style {
    case .segmented:
      Picker(title, selection: selection) {
        ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
          Text(label).tag(index)
        }
      }
      .pickerStyle(.segmented)
    case .underline:
      UnderlineTabStrip(
        title: title, labels: labels, selectedIndex: selectedIndex, reduceMotion: reduceMotion,
        onSelect: onSelect)
    case .chips:
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: WhirrSpacing.xSmall) {
          ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
            let isDisabled = isDisabled(index)
            Button {
              guard isDisabled == false else { return }
              onSelect(index)
            } label: {
              Text(label)
                .font(.subheadline.weight(isSelected(index) ? .semibold : .regular))
                .foregroundStyle(
                  isSelected(index) ? selectionInk : WhirrColorToken.textSecondary.color
                )
                .padding(.horizontal, WhirrSpacing.small)
                .padding(.vertical, WhirrSpacing.xSmall)
                .background(
                  isSelected(index) ? selectionFill : Color.absSecondarySystemFill,
                  in: Capsule()
                )
                .opacity(isDisabled ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected(index) ? .isSelected : [])
            .disabled(isDisabled)
          }
        }
        .padding(.horizontal, WhirrSpacing.medium)
        .animation(
          Self.chipSelectionAnimation(reduceMotion: reduceMotion), value: selectedIndex)
      }
      .accessibilityElement(children: .contain)
      .accessibilityLabel(title)
    }
  }
}

/// `MediaFilterPickerStyle.underline`'s body. Extracted so its layout constants and state are not
/// stored properties of `MediaFilterPicker`, whose stored properties are what its semantic
/// snapshot records.
private struct UnderlineTabStrip: View {
  let title: String
  let labels: [String]
  let selectedIndex: Int
  let reduceMotion: Bool
  let onSelect: (Int) -> Void

  private static let ruleHeight: CGFloat = 2
  /// Splits either side of the label, so the rule runs a little past the word it underlines.
  private static let labelInset: CGFloat = WhirrSpacing.xSmall
  /// Subheadline text is about 20pt tall, which this pads out to the touch minimum. It also sets
  /// the strip's height, and therefore where the rule and the baseline meet.
  private static let labelPadding: CGFloat = WhirrSpacing.small

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
        let isSelected = index == selectedIndex
        Button {
          onSelect(index)
        } label: {
          Text(label)
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(
              MediaFilterPicker.underlineProminence(isSelected: isSelected).adaptiveStyle
            )
            .multilineTextAlignment(.center)
            .padding(.horizontal, Self.labelInset)
            .padding(.vertical, Self.labelPadding)
            // Attached before the segment's width is imposed, so the rule is the label's width
            // and not the segment's.
            .overlay(alignment: .bottom) {
              // One rule per segment, appearing in place. See `underlineSelectionAnimation`.
              Capsule()
                .fill(Color.primary)
                .frame(height: Self.ruleHeight)
                .opacity(isSelected ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
      }
    }
    .animation(
      MediaFilterPicker.underlineSelectionAnimation(reduceMotion: reduceMotion),
      value: selectedIndex
    )
    // No baseline under the strip: a full-width rule with the selected tab's rule on it reads as
    // one broken line, since both are the same ink at nearly the same weight.
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }
}
