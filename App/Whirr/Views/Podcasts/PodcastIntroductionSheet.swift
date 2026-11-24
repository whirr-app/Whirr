import AppModel
import DesignSystem
import SwiftUI

/// The one-time Podcasts introduction, in the system welcome-sheet shape: a large title, one
/// lede, a short symbol-labelled row per idea and a full-width Continue. Informational only: it
/// grants nothing and opens no cloud path. Presented from the Podcasts tab root; the harness
/// passes an already-seen marker.
struct PodcastIntroductionSheetView: View {
  let hasServerAccount: Bool
  let onDismiss: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: WhirrSpacing.xLarge) {
        VStack(alignment: .leading, spacing: WhirrSpacing.small) {
          Text(PodcastIntroductionCopy.title)
            .font(.largeTitle.bold())
            .accessibilityAddTraits(.isHeader)
          Text(PodcastIntroductionPresentation.lede(hasServerAccount: hasServerAccount))
            .font(.body)
            .foregroundStyle(WhirrColorToken.textSecondary.color)
        }
        VStack(alignment: .leading, spacing: WhirrSpacing.large) {
          ForEach(
            PodcastIntroductionPresentation.rows(hasServerAccount: hasServerAccount), id: \.self
          ) { row in
            PodcastIntroductionRowView(row: row)
          }
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, WhirrSpacing.large)
      .padding(.top, WhirrSpacing.xLarge + WhirrSpacing.medium)
    }
    .safeAreaInset(edge: .bottom) {
      Button(action: onDismiss) {
        Text(PodcastIntroductionCopy.dismiss)
          .font(.body.weight(.semibold))
          .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
      }
      .buttonStyle(.borderedProminent)
      .tint(AppChrome.brandTint)
      .padding(.horizontal, WhirrSpacing.large)
      .padding(.bottom, WhirrSpacing.medium)
      .accessibilityIdentifier(PodcastIntroductionAccessibilityID.dismiss)
    }
    .accessibilityIdentifier(PodcastIntroductionAccessibilityID.sheet)
  }
}

private struct PodcastIntroductionRowView: View {
  let row: PodcastIntroductionPresentation.Row

  var body: some View {
    HStack(alignment: .top, spacing: WhirrSpacing.medium) {
      Image(systemName: row.systemImage)
        .font(.title2)
        .foregroundStyle(AppChrome.brandTint)
        .frame(width: WhirrSpacing.xLarge, alignment: .center)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        Text(row.title)
          .font(.headline)
        Text(row.detail)
          .font(.subheadline)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

enum PodcastIntroductionAccessibilityID {
  static let sheet = "podcasts.introduction"
  static let dismiss = "podcasts.introduction.dismiss"
}

private struct PodcastIntroductionModifier: ViewModifier {
  let marking: any PodcastIntroductionMarking
  let nativeSubscriptionsEnabled: Bool
  let hasServerAccount: Bool
  @State private var isPresented = false

  func body(content: Content) -> some View {
    content
      .onAppear {
        guard isPresented == false else { return }
        isPresented = PodcastIntroductionPresentation.shouldPresent(
          seenVersion: marking.seenVersion(), nativeSubscriptionsEnabled: nativeSubscriptionsEnabled)
      }
      // Disabling native subscriptions while the sheet is up withdraws it; the user has read it.
      .onChange(of: nativeSubscriptionsEnabled) { _, enabled in
        if enabled == false { isPresented = false }
      }
      // Button and swipe dismissal both count as seen; there is nothing to decline.
      .sheet(
        isPresented: $isPresented, onDismiss: { marking.markSeen() },
        content: {
          PodcastIntroductionSheetView(hasServerAccount: hasServerAccount) { isPresented = false }
            .adaptiveSheetPresentation(role: .fitted, compactDetents: [.large])
        })
  }
}

extension View {
  func podcastIntroduction(
    marking: any PodcastIntroductionMarking, nativeSubscriptionsEnabled: Bool, hasServerAccount: Bool
  ) -> some View {
    modifier(
      PodcastIntroductionModifier(
        marking: marking, nativeSubscriptionsEnabled: nativeSubscriptionsEnabled,
        hasServerAccount: hasServerAccount))
  }
}
