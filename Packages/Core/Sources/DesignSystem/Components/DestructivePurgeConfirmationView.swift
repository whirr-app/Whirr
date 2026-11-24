import SwiftUI

/// The destructive purge confirmation for `StorageModel.pendingPurgeConfirmation`'s single-item
/// or purge-all flow. It uses explicit destructive copy, never a bare "Are you sure?", and
/// forwards confirm and cancel as two separate actions so a caller cannot conflate them. The
/// confirm button carries the `.destructive` role, so the action is not conveyed by colour alone.
public struct DestructivePurgeConfirmationView: View {
  public let title: String
  public let message: String
  public let confirmLabel: String
  public let confirmAccessibilityHint: String
  public let cancelLabel: String
  public let onConfirm: () -> Void
  public let onCancel: () -> Void

  public init(
    title: String,
    message: String,
    confirmLabel: String,
    confirmAccessibilityHint: String,
    cancelLabel: String,
    onConfirm: @escaping () -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.title = title
    self.message = message
    self.confirmLabel = confirmLabel
    self.confirmAccessibilityHint = confirmAccessibilityHint
    self.cancelLabel = cancelLabel
    self.onConfirm = onConfirm
    self.onCancel = onCancel
  }

  public var accessibilityLabel: String { "\(title). \(message)" }
  public var confirmButtonMinHeight: CGFloat { WhirrMetric.minimumTouchTarget }
  public var cancelButtonMinHeight: CGFloat { WhirrMetric.minimumTouchTarget }

  public var body: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.small) {
      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        Text(title)
          .font(WhirrTypeToken.headline.font)
        Text(message)
          .font(WhirrTypeToken.body.font)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(accessibilityLabel)

      HStack(spacing: WhirrSpacing.small) {
        Button(cancelLabel, role: .cancel, action: onCancel)
          .frame(minHeight: cancelButtonMinHeight)

        Button(confirmLabel, role: .destructive, action: onConfirm)
          .frame(minHeight: confirmButtonMinHeight)
          .accessibilityHint(confirmAccessibilityHint)
      }
    }
    .padding(WhirrSpacing.medium)
  }
}
