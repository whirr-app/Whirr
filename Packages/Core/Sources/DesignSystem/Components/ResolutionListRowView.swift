import SwiftUI

/// One open item in the resolution center (progress conflict, skew confirmation, dead letter, or
/// paused-auth download): title, message and icon plus its ordered per-kind actions.
/// `ResolutionCenterCopy.actions(for:)` owns which actions each kind gets. Actions forward by
/// index rather than embedding a closure per action, so `actions` stays an `Equatable` value.
public struct ResolutionListRowView: View {
  /// One action offered for this row, e.g. "Keep This Device's Progress" or the destructive
  /// "Overwrite" confirmation. `isDestructive` renders as a real button role, so a destructive
  /// action is never distinguished by colour alone.
  public struct Action: Sendable, Equatable {
    public let label: String
    public let accessibilityHint: String
    public let isDestructive: Bool

    public init(label: String, accessibilityHint: String, isDestructive: Bool = false) {
      self.label = label
      self.accessibilityHint = accessibilityHint
      self.isDestructive = isDestructive
    }
  }

  public let title: String
  public let message: String
  public let systemImage: String
  public let actions: [Action]
  public let onSelectAction: (Int) -> Void

  public init(
    title: String,
    message: String,
    systemImage: String,
    actions: [Action],
    onSelectAction: @escaping (Int) -> Void
  ) {
    self.title = title
    self.message = message
    self.systemImage = systemImage
    self.actions = actions
    self.onSelectAction = onSelectAction
  }

  public var accessibilityLabel: String { "\(title). \(message)" }
  public var actionButtonMinHeight: CGFloat { WhirrMetric.minimumTouchTarget }

  public var body: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        Label(title, systemImage: systemImage)
          .font(WhirrTypeToken.headline.font)
        Text(message)
          .font(WhirrTypeToken.body.font)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(accessibilityLabel)

      HStack(spacing: WhirrSpacing.small) {
        ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
          Button(action.label, role: action.isDestructive ? .destructive : nil) {
            onSelectAction(index)
          }
          .frame(minHeight: actionButtonMinHeight)
          .accessibilityHint(action.accessibilityHint)
        }
      }
    }
    .padding(WhirrSpacing.medium)
  }
}
