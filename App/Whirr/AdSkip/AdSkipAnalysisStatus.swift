import AppModel
import DesignSystem
import SwiftUI

/// What the expanded player says about the loaded episode's ad analysis. Shown only until the
/// episode is ready, and never while a skip receipt is showing.
enum AdSkipStatusPresentation {
  static let checkNowTitle = "Check Now"
  static let checkNowHint = "Checks this episode for ads on battery"

  struct Content: Equatable {
    let text: String
    let systemImage: String
    /// Only the charging wait can be lifted from here: the listener chose it.
    let offersCheckNow: Bool
  }

  /// Nil when there is nothing to say, including a held analysis whose reason has already gone:
  /// the coordinator will be told in a moment, and a stale line would be wrong.
  nonisolated static func content(
    for status: PlaybackAdAnalysisStatus, pauseReason: AdSkipPauseReason?
  ) -> Content? {
    switch status {
    case .none, .notEnabled:
      // Off is the offer's to say (`AdSkipOffer`), not the status line's.
      return nil
    case .checking:
      return Content(text: "Checking this episode for ads", systemImage: "waveform", offersCheckNow: false)
    case .waiting(.speechModel):
      return Content(
        text: "Ad checks start once the speech model has downloaded", systemImage: "arrow.down.circle",
        offersCheckNow: false)
    case .waiting(.conditions):
      guard let pauseReason else { return nil }
      let copy = AdSkipWaitPresentation.player(pauseReason)
      return Content(
        text: copy.text, systemImage: copy.systemImage, offersCheckNow: copy.offersCheckNow)
    }
  }

  /// Announces a status once per loaded episode, so a status that changes while one episode plays
  /// (waiting, then checking) speaks only the first time, and the mini and expanded players never
  /// both speak.
  @MainActor
  static func announce(_ content: Content, forLoad key: String) {
    guard announcedLoad != key else { return }
    announcedLoad = key
    AccessibilityNotification.Announcement(content.text).post()
  }

  @MainActor private static var announcedLoad: String?
}

/// The status line: the same glass capsule as the receipt, so the two read as one place.
struct AdSkipStatusCapsule: View {
  let content: AdSkipStatusPresentation.Content
  let onCheckNow: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    GlassContainer(in: Capsule()) {
      HStack(spacing: 0) {
        Label {
          Text(content.text)
        } icon: {
          Image(systemName: content.systemImage)
            .symbolEffect(
              .variableColor.iterative, options: .repeating,
              isActive: reduceMotion == false && content.systemImage == "waveform")
        }
        .font(WhirrTypeToken.subheadline.font)
        .padding(.leading, 18)
        .padding(.trailing, content.offersCheckNow ? 4 : 18)
        .frame(minHeight: 44)
        if content.offersCheckNow {
          Button(action: onCheckNow) {
            Text(AdSkipStatusPresentation.checkNowTitle)
              .font(WhirrTypeToken.subheadline.font.weight(.semibold))
              .padding(.horizontal, 14)
              .frame(minHeight: 44)
              .contentShape(Rectangle())
          }
          .accessibilityHint(AdSkipStatusPresentation.checkNowHint)
          .accessibilityIdentifier(PlayerAccessibilityID.adSkipCheckNow)
        }
      }
      .buttonStyle(.plain)
      .lineLimit(2)
      .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityIdentifier(PlayerAccessibilityID.adSkipStatus)
  }
}

/// Follows the loaded episode's status and why analysis waits, for `AdSkipReceiptOverlay`.
struct AdSkipStatusTracker: ViewModifier {
  let playback: PlaybackModel
  @Binding var content: AdSkipStatusPresentation.Content?

  private struct Key: Equatable {
    let status: PlaybackAdAnalysisStatus
    let load: String
  }

  private var load: String { "\(playback.loadedItemID ?? "")/\(playback.loadedEpisodeID ?? "")" }

  func body(content view: Content) -> some View {
    view
      .task(id: Key(status: playback.adAnalysisStatus, load: load)) {
        guard case .waiting(.conditions) = playback.adAnalysisStatus else {
          refresh(pauseReason: nil)
          return
        }
        for await reason in AdSkipAnalysisConditions.pauseReasonChanges() {
          refresh(pauseReason: reason)
        }
      }
  }

  private func refresh(pauseReason reason: AdSkipPauseReason?) {
    let next = AdSkipStatusPresentation.content(for: playback.adAnalysisStatus, pauseReason: reason)
    if let next { AdSkipStatusPresentation.announce(next, forLoad: load) }
    if content != next { content = next }
  }
}
