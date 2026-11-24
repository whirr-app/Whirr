import SwiftUI

/// Which non-nominal playback condition a `PlaybackStatusBanner` communicates. Each case is
/// always paired by the caller with a distinct `systemImage`, so status is never conveyed by
/// colour alone.
public enum PlaybackStatusKind: Sendable, Equatable, CaseIterable {
  case buffering
  case recoverableError
  case offline
  case recoveringSession
}

/// Status banner for the buffering / recoverable-error / offline / recovering-session states a
/// player surface can be in. All copy (title, message, icon, retry title) is caller-supplied;
/// DesignSystem owns no state copy (ARCHITECTURE.md).
public struct PlaybackStatusBanner: View {
  public let kind: PlaybackStatusKind
  public let title: String
  public let message: String
  public let systemImage: String
  public let retryTitle: String?
  public let retryAction: (() -> Void)?

  public init(
    kind: PlaybackStatusKind,
    title: String,
    message: String,
    systemImage: String,
    retryTitle: String? = nil,
    retryAction: (() -> Void)? = nil
  ) {
    self.kind = kind
    self.title = title
    self.message = message
    self.systemImage = systemImage
    self.retryTitle = retryTitle
    self.retryAction = retryAction
  }

  /// The single accessibility label VoiceOver announces for the banner, combining title and
  /// message so status is read in one pass. Pure, so testable without rendering.
  public var accessibilityLabel: String {
    message.isEmpty ? title : "\(title). \(message)"
  }

  public var body: some View {
    PlayerSurface {
      VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
        Label(title, systemImage: systemImage)
          .font(WhirrTypeToken.headline.font)
        // A caller that has nothing to add beyond the title (e.g. buffering, whose title already
        // says everything) passes an empty message; render title-only rather than a blank line.
        if !message.isEmpty {
          Text(message)
            .font(WhirrTypeToken.body.font)
            .foregroundStyle(.secondary)
        }

        if let retryTitle, let retryAction {
          Button(retryTitle, action: retryAction)
            .frame(minHeight: WhirrMetric.minimumTouchTarget)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(accessibilityLabel)
      .padding(WhirrSpacing.medium)
      // A surface of its own, not bare text: this banner is placed over the player's artwork-tinted
      // canvas, where unbacked labels sat unreadably on top of whatever they overlapped. Matches
      // the adjacent player-control card treatment so the two read as the same material.
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
