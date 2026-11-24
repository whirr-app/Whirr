import SwiftUI

// All copy on these views comes from the caller (AppModel state, in the App target), so no
// user-facing string literals live in this file. `systemImage` is an SF Symbol identifier,
// not localised copy, and is likewise supplied by the caller.

/// A busy/loading placeholder for a screen or section.
public struct LoadingStateView: View {
  let message: String

  public init(message: String) {
    self.message = message
  }

  public var body: some View {
    VStack(spacing: WhirrSpacing.small) {
      ProgressView()
      Text(message)
        .font(WhirrTypeToken.body.font)
        .foregroundStyle(WhirrColorToken.textSecondary.color)
    }
    .padding(WhirrSpacing.large)
  }
}

/// Shown when a screen or section has nothing to display.
public struct EmptyStateView: View {
  let title: String
  let message: String
  let systemImage: String
  let actionLabel: String?
  let action: (() -> Void)?

  public init(
    title: String,
    message: String,
    systemImage: String,
    actionLabel: String? = nil,
    action: (() -> Void)? = nil
  ) {
    self.title = title
    self.message = message
    self.systemImage = systemImage
    self.actionLabel = actionLabel
    self.action = action
  }

  public var hasAction: Bool { actionLabel != nil && action != nil }

  public var body: some View {
    if let actionLabel, let action {
      ContentUnavailableView {
        Label(title, systemImage: systemImage)
      } description: {
        Text(message)
      } actions: {
        Button(actionLabel, action: action)
      }
    } else {
      ContentUnavailableView {
        Label(title, systemImage: systemImage)
      } description: {
        Text(message)
      }
    }
  }
}

/// Shown when a screen or section failed to load, with an optional retry action.
public struct ErrorStateView: View {
  let title: String
  let message: String
  let systemImage: String
  let retryTitle: String?
  let retryAction: (() -> Void)?

  public init(
    title: String,
    message: String,
    systemImage: String,
    retryTitle: String? = nil,
    retryAction: (() -> Void)? = nil
  ) {
    self.title = title
    self.message = message
    self.systemImage = systemImage
    self.retryTitle = retryTitle
    self.retryAction = retryAction
  }

  public var body: some View {
    ContentUnavailableView {
      Label(title, systemImage: systemImage)
    } description: {
      Text(message)
    } actions: {
      if let retryTitle, let retryAction {
        Button(retryTitle, action: retryAction)
      }
    }
  }
}
