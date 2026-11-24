import SwiftUI

/// A browse section's title and optional disclosure action. The whole heading row is the tap
/// target: a trailing chevron communicates that it opens a more detailed view without introducing
/// a second, competing text label such as “See All”. Home, Podcasts, and Search share this type so
/// browse headings cannot drift into surface-specific affordances again.
public struct BrowseSectionHeaderView: View {
  public let title: String
  public let accessibilityHint: String?
  public let onSelect: (() -> Void)?

  public init(
    title: String,
    accessibilityHint: String? = nil,
    onSelect: (() -> Void)? = nil
  ) {
    self.title = title
    self.accessibilityHint = accessibilityHint
    self.onSelect = onSelect
  }

  public var isShowingDisclosure: Bool { onSelect != nil }

  public var actionMinHeight: CGFloat { WhirrMetric.minimumTouchTarget }

  @ViewBuilder
  public var body: some View {
    if let onSelect {
      Button(action: onSelect) {
        heading(showsDisclosure: true)
          .frame(maxWidth: .infinity, minHeight: actionMinHeight, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(title)
      .accessibilityHint(accessibilityHint ?? "")
      // Both traits, not one: this row is the section's heading and it also opens the full list.
      // Dropping the header trait because the row is tappable is what left the rotor with nothing
      // to land on, which is the fastest way through a screen of shelves and the one a reader is
      // most likely to reach for here.
      .accessibilityAddTraits(.isHeader)
    } else {
      heading(showsDisclosure: false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
  }

  private func heading(showsDisclosure: Bool) -> some View {
    HStack {
      Text(title)
        .font(WhirrTypeToken.display.font)
        .foregroundStyle(.primary)

      if showsDisclosure {
        Spacer(minLength: WhirrSpacing.small)
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.secondary)
      }
    }
  }
}
