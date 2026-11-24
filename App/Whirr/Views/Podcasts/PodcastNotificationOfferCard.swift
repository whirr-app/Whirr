import AppModel
import DesignSystem
import SwiftUI

/// The one-time offer of New Episode Notifications on the Podcasts root. Inline, never modal;
/// either button answers it for good, and the setting stays in Settings > Podcasts.
///
/// The view is always in the stack, at zero height while there is nothing to offer, because it
/// owns loading the notification model: nothing else loads that model outside Settings.
struct PodcastNotificationOfferCard: View {
  let model: PodcastNotificationSettingsModel
  let marking: any PodcastNotificationOfferMarking
  let nativeSubscriptionsEnabled: Bool
  let hasFollowedShows: Bool
  let filterShowsOffer: Bool
  let hasPlaceholder: Bool
  let horizontalInset: CGFloat

  /// Seeded from the marker, then owned here: the marker is plain storage, not observable.
  @State private var isAnswered: Bool?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// A `load()` overtaken by the scene-activation refresh publishes nothing, so one await is not
  /// enough. Bounded, because an unloaded model only costs the offer.
  static let loadAttempts = 5

  private var isPresented: Bool {
    PodcastNotificationOfferPresentation.shouldPresent(
      .init(
        hasLoaded: model.hasLoaded, nativeSubscriptionsEnabled: nativeSubscriptionsEnabled,
        hasFollowedShows: hasFollowedShows, filterShowsOffer: filterShowsOffer,
        hasPlaceholder: hasPlaceholder, isEnabled: model.isEnabled,
        authorizationStatus: model.authorizationStatus,
        backgroundRefreshStatus: model.backgroundRefreshStatus,
        isAnswered: isAnswered ?? marking.isAnswered()))
  }

  var body: some View {
    VStack(spacing: 0) {
      if isPresented {
        card
          .padding(.horizontal, horizontalInset)
          .padding(.bottom, WhirrSpacing.medium)
          .transition(.opacity)
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isPresented)
    .task(id: nativeSubscriptionsEnabled && hasFollowedShows) {
      guard nativeSubscriptionsEnabled, hasFollowedShows, marking.isAnswered() == false else {
        return
      }
      for _ in 0..<Self.loadAttempts where model.hasLoaded == false {
        await model.load()
      }
    }
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.small) {
      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        Text(PodcastNotificationOfferCopy.title)
          .font(WhirrTypeToken.headline.font)
          .accessibilityAddTraits(.isHeader)
        Text(PodcastNotificationOfferCopy.detail)
          .font(WhirrTypeToken.subheadline.font)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: WhirrSpacing.small) {
        Button(PodcastNotificationOfferCopy.accept) {
          answer()
          model.requestEnabled(true)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppChrome.brandTint)
        .accessibilityIdentifier(PodcastAccessibilityID.notificationOfferAccept)

        Button(PodcastNotificationOfferCopy.decline) {
          answer()
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(PodcastAccessibilityID.notificationOfferDecline)
      }
      .frame(minHeight: WhirrMetric.minimumTouchTarget)
    }
    .padding(WhirrSpacing.medium)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      .primary.opacity(0.06),
      in: RoundedRectangle(
        cornerRadius: EditorialCardSurfaceModifier.cornerRadius, style: .continuous)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(PodcastAccessibilityID.notificationOffer)
  }

  /// Marked when the button is tapped, not when the system prompt resolves: a denial is
  /// recoverable from Settings, and asking twice is the thing to avoid.
  private func answer() {
    marking.markAnswered()
    isAnswered = true
  }
}
