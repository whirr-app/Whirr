import AppModel
import DesignSystem
import SwiftUI
import SyncEngine

/// The stall/error banner. Owns the buffering debounce (`isStalled`) and reads `playback.phase`,
/// so the page never re-runs on a phase flap, only this zero-height overlay does.
struct StatusBannerSection: View {
  let playback: PlaybackModel
  let connectivityModel: ConnectivityModel?

  /// True only once `.buffering` has persisted past `bufferingBannerDelay`. A real stream flaps
  /// through `.buffering` around every play and seek; showing the banner instantly inserts a row
  /// mid-layout and shoves the transport controls out from under the user's finger.
  @State private var isStalled = false

  var body: some View {
    // The gap above the banner belongs to the banner. Padding wrapped around an `EmptyView` is
    // no longer an `EmptyView`, so a stack would give an idle player the space too. The
    // expanded player sizes its cover from this block's height, so that padding would come
    // straight out of the artwork.
    Group {
      if drawsBanner {
        banner
          .padding(.top, WhirrSpacing.small)
      }
    }
    // Restarts whenever the phase changes: entering `.buffering` arms the delay, and any phase
    // change before it fires cancels the sleep, so only a genuine stall shows the banner.
    // Outside the branch above so the debounce still arms while no banner is drawn.
    .task(id: playback.phase) {
      guard playback.phase == .buffering else {
        isStalled = false
        return
      }
      try? await Task.sleep(for: .seconds(ExpandedPlayerView.bufferingBannerDelay))
      if Task.isCancelled == false {
        isStalled = true
      }
    }
  }

  /// Whether `banner` resolves to anything. The same call it switches on, so the padding above it
  /// can be conditional.
  private var drawsBanner: Bool {
    ExpandedPlayerPresentation.statusBanner(
      phase: playback.phase,
      isStreamingSource: playback.isStreamingSource,
      reachability: connectivityModel?.reachability ?? .unknown,
      isBufferingDebounced: isStalled,
      itemID: playback.loadedItemID,
      startFailureMessage: playback.startFailureMessage
    ) != nil
  }

  @ViewBuilder
  private var banner: some View {
    switch ExpandedPlayerPresentation.statusBanner(
      phase: playback.phase,
      isStreamingSource: playback.isStreamingSource,
      reachability: connectivityModel?.reachability ?? .unknown,
      isBufferingDebounced: isStalled,
      itemID: playback.loadedItemID,
      startFailureMessage: playback.startFailureMessage
    ) {
    case .some(.buffering):
      // Title only: a subtitle would just repeat "Buffering".
      PlaybackStatusBanner(
        kind: .buffering, title: "Buffering", message: "",
        systemImage: "arrow.triangle.2.circlepath"
      )
      .accessibilityIdentifier(PlayerAccessibilityID.expandedStatusBanner)
    case .some(.offline(let presentation)):
      PlaybackStatusBanner(
        kind: .offline,
        title: presentation.banner.title,
        message: presentation.banner.message,
        systemImage: presentation.systemImage,
        retryTitle: presentation.banner.retryTitle,
        retryAction: { playback.retry() }
      )
      .accessibilityIdentifier(PlayerAccessibilityID.expandedStatusBanner)
    case .some(.recoverableError(let message)):
      PlaybackStatusBanner(
        kind: .recoverableError, title: "Playback Error", message: message,
        systemImage: "exclamationmark.triangle", retryTitle: "Retry", retryAction: { playback.retry() }
      )
      .accessibilityIdentifier(PlayerAccessibilityID.expandedStatusBanner)
    case .some(.unrecoverableError(let message)):
      PlaybackStatusBanner(
        kind: .recoverableError, title: "Playback Error", message: message,
        systemImage: "exclamationmark.triangle"
      )
      .accessibilityIdentifier(PlayerAccessibilityID.expandedStatusBanner)
    default:
      EmptyView()
    }
  }
}
