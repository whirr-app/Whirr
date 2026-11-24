import SwiftUI

/// The shell's ambient status signal: one glyph in the navigation bar that stays put for as long
/// as the condition holds, and explains itself when tapped.
///
/// A glyph shows the state itself, so the condition is legible before an action fails. A
/// full-width banner would occlude the navigation bar's controls, including Settings, the only
/// route out of a stale account. The explanation and its remedy (two lines and a button) live in
/// a popover, as more than a toolbar can hold.
///
/// Both shell conditions (an unreachable server, a credential that needs re-entering) render
/// through this one type so they share the same shape.
public struct ShellStatusIndicatorView: View {
  public let title: String
  public let message: String
  public let systemImage: String
  public let actionTitle: String
  /// Describes the popover's action button, not the glyph. The glyph's own hint is fixed below,
  /// because from the bar a tap only shows the explanation.
  public let actionAccessibilityHint: String?
  public let onAction: () -> Void

  @State private var handoff = ShellStatusActionHandoff()

  public init(
    title: String,
    message: String,
    systemImage: String,
    actionTitle: String,
    actionAccessibilityHint: String? = nil,
    onAction: @escaping () -> Void
  ) {
    self.title = title
    self.message = message
    self.systemImage = systemImage
    self.actionTitle = actionTitle
    self.actionAccessibilityHint = actionAccessibilityHint
    self.onAction = onAction
  }

  public var accessibilityLabel: String { title }
  public var actionButtonMinHeight: CGFloat { WhirrMetric.minimumTouchTarget }

  public var body: some View {
    Button {
      handoff.isExplanationPresented = true
    } label: {
      Image(systemName: systemImage)
        // `DownloadControlRole.warning` already establishes orange as this app's "needs attention,
        // nothing is broken" colour; red would overstate conditions the app recovers from, either
        // by itself (reachability) or with one sign-in (credentials).
        .foregroundStyle(.orange)
    }
    // The glyph carries no text, so the title is the whole label. The hint is about the popover,
    // not the condition: the label has already said what is wrong.
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint("Shows what to do about it.")
    .popover(isPresented: $handoff.isExplanationPresented) {
      explanation
        // Without this a compact-width popover becomes a sheet, which is the page-sized
        // interruption this indicator exists to avoid.
        .presentationCompactAdaptation(.popover)
        .onDisappear {
          if handoff.explanationDidDisappear() { onAction() }
        }
    }
  }

  private var explanation: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.small) {
      Text(title)
        .font(WhirrTypeToken.headline.font)
      Text(message)
        .font(.subheadline)
        .foregroundStyle(WhirrColorToken.textSecondary.color)
        .fixedSize(horizontal: false, vertical: true)
      actionButton
    }
    .padding(WhirrSpacing.medium)
    // A definite width, not a maximum: a popover measures its content against an unconstrained
    // proposal, so with `maxWidth` the message reports the height of a single unwrapped line and
    // the popover clips the wrapped text and the action button below it.
    .frame(width: 280, alignment: .leading)
  }

  @ViewBuilder private var actionButton: some View {
    let button = Button(actionTitle) {
      handoff.requestAction()
    }
    .font(.subheadline.weight(.semibold))
    .frame(minHeight: actionButtonMinHeight)

    if let actionAccessibilityHint {
      button.accessibilityHint(actionAccessibilityHint)
    } else {
      button
    }
  }
}

/// The order the indicator's action runs in: dismiss the popover first, act once it has gone.
///
/// Acting in the same tap as the dismissal fails for actions that present (Reconnect raises the
/// credential sheet): UIKit drops a second presentation while the popover is still on screen,
/// without an error, so the button would do nothing.
public struct ShellStatusActionHandoff: Equatable, Sendable {
  public var isExplanationPresented = false
  public private(set) var isActionPending = false

  public init() {}

  public mutating func requestAction() {
    isActionPending = true
    isExplanationPresented = false
  }

  /// Whether the action should run now. Consumes the request, so a later dismissal by tapping
  /// outside the popover does not repeat it.
  public mutating func explanationDidDisappear() -> Bool {
    defer { isActionPending = false }
    return isActionPending
  }
}
