import AppModel
import DesignSystem
import SwiftUI

extension View {
  /// The one alert a list shows for its rows' failed context-menu actions, plus the transient
  /// banners it shows for successful queue and Saved for Later mutations. Attached once per screen,
  /// not once per row: an intent that resolves after its row has scrolled away (or been recycled
  /// onto another item) still has somewhere to surface. Every browse surface already applies this,
  /// so giving both feedback channels a home here reaches all of them at once.
  func itemActionErrorAlert(_ actions: ItemActionsModel, isSuppressed: Bool = false) -> some View {
    alert(
      "Item Action",
      isPresented: Binding(
        get: { !isSuppressed && actions.actionErrorMessage != nil },
        set: { if $0 == false && !isSuppressed { actions.dismissActionError() } })
    ) {
      Button("OK", role: .cancel) { actions.dismissActionError() }
    } message: {
      Text(actions.actionErrorMessage ?? "")
    }
    // A failed action is the one thing on this channel the listener must notice, so it takes the
    // notification pattern the confirmations avoid.
    .sensoryFeedback(trigger: actions.actionErrorMessage) { _, newMessage in
      isSuppressed || newMessage == nil ? nil : ItemActionHaptics.failure
    }
    .queueFeedbackBanner(
      message: isSuppressed ? nil : actions.queueFeedbackMessage, onDismiss: actions.dismissQueueFeedback
    )
    .queueFeedbackBanner(
      message: isSuppressed ? nil : actions.savedFeedbackMessage, onDismiss: actions.dismissSavedFeedback
    )
    .queueFeedbackBanner(
      message: isSuppressed ? nil : actions.continueListeningFeedbackMessage,
      onDismiss: actions.dismissContinueListeningFeedback
    )
    .queueFeedbackBanner(
      message: isSuppressed ? nil : actions.ebookDeliveryFeedbackMessage,
      onDismiss: actions.dismissEbookDeliveryFeedback
    )
    // Every screen that shows book menus attaches this, so it is also where the menus' device list
    // is warmed: a long-press menu is built before its preview appears, so loading on the preview
    // would miss the first open. The service caches the read, so revisits cost nothing.
    .task { await actions.loadEreaderDevicesIfNeeded() }
  }

  /// The detail harness has no screen-wide item-action model, so it keeps the default no-op path.
  @ViewBuilder
  func itemActionErrorAlert(_ actions: ItemActionsModel?) -> some View {
    if let actions {
      itemActionErrorAlert(actions)
    } else {
      self
    }
  }
}

extension View {
  func queueFeedbackBanner(message: String?, onDismiss: @escaping () -> Void) -> some View {
    modifier(ItemQueueFeedbackBanner(message: message, onDismiss: onDismiss))
  }
}

/// Screen-wide queue, Saved for Later, and Continue Listening confirmations, shown briefly over
/// the bottom of whatever screen raised them, then cleared. A banner, not an alert (nothing needs
/// acknowledging). Announced once on appearance via an accessibility announcement.
private struct ItemQueueFeedbackBanner: ViewModifier {
  let message: String?
  let onDismiss: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .bottom) {
        // The animation stays on the overlay because animating the composed view animates the
        // screen's list and makes it drop touches while a row change settles; hit-testing stays
        // off because the capsule is purely confirmatory.
        ZStack {
          if let message,
            ItemContextMenuPresentation.QueueFeedback.isVisible(message)
          {
            HStack(spacing: WhirrSpacing.xSmall) {
              Image(
                systemName: ItemContextMenuPresentation.QueueFeedback.systemImage(for: message)
              )
              .font(WhirrTypeToken.headline.font)
              .frame(width: 28, height: 28)
              .background(.primary.opacity(0.08), in: Circle())
              .accessibilityHidden(true)

              Text(message)
                .font(WhirrTypeToken.body.font.weight(.semibold))
                .lineLimit(2)
            }
            .padding(.horizontal, WhirrSpacing.medium)
            .padding(.vertical, WhirrSpacing.xSmall)
            .background(.regularMaterial, in: Capsule())
            .overlay {
              Capsule().stroke(.primary.opacity(0.1), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
            .padding(.horizontal, WhirrSpacing.medium)
            .padding(.bottom, WhirrSpacing.large)
            .transition(
              reduceMotion
                ? .opacity
                : .move(edge: .bottom).combined(with: .opacity)
            )
            .accessibilityAddTraits(.isStaticText)
          }
        }
        .animation(
          reduceMotion ? nil : .snappy(duration: 0.28, extraBounce: 0.08),
          value: message
        )
        .allowsHitTesting(false)
      }
      // Keyed on the same value the banner animates, and returning nil for the clear, so the tap
      // lands with the confirmation's arrival and the two-second dismissal is silent. A second
      // confirmation arriving while the first is up is a new value, so it taps again.
      .sensoryFeedback(trigger: message) { _, newMessage in
        guard let newMessage,
          ItemContextMenuPresentation.QueueFeedback.isVisible(newMessage)
        else { return nil }
        return ItemContextMenuPresentation.QueueFeedback.haptic(for: newMessage)
      }
      // Keyed on the message, so a second confirmation restarts the window rather than inheriting
      // the remainder of the first one's.
      .task(id: message) {
        guard let message,
          ItemContextMenuPresentation.QueueFeedback.isVisible(message)
        else { return }
        AccessibilityNotification.Announcement(message).post()
        try? await Task.sleep(
          for: .seconds(ItemContextMenuPresentation.QueueFeedback.visibleDuration))
        guard Task.isCancelled == false else { return }
        onDismiss()
      }
  }
}
