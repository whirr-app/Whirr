import AppModel
import DesignSystem
import PlayerCore
import SwiftUI

/// The receipt for an ad skip: "Skipped 0:32 of ads", with Undo
/// unless the skip ended the episode. Only the in-app player shows it.
enum AdSkipReceiptPresentation {
  static let visibleDuration: Duration = .seconds(8)
  static let undoTitle = "Undo"
  static let undoActionName = "Undo Ad Skip"

  /// "Skipped 0:32 of ads", with no separator glyph. A length, so unpadded minutes,
  /// unlike the playhead's "00:32".
  nonisolated static func text(for receipt: PlaybackSkipReceipt) -> String {
    let seconds = Int(duration(of: receipt).rounded())
    let remainder = seconds % 60
    return "Skipped \(seconds / 60):\(remainder < 10 ? "0" : "")\(remainder) of ads"
  }

  /// "Skipped 32 seconds of ads", for VoiceOver.
  nonisolated static func announcement(for receipt: PlaybackSkipReceipt) -> String {
    let seconds = Int(duration(of: receipt).rounded())
    let spoken = Duration.seconds(seconds).formatted(
      .units(allowed: [.minutes, .seconds], width: .wide))
    return "Skipped \(spoken) of ads"
  }

  private nonisolated static func duration(of receipt: PlaybackSkipReceipt) -> Double {
    max(0, receipt.range.end - receipt.range.start)
  }

  /// What a surface shows once `PlaybackModel.lastSkip` changes to `lastSkip`. A new skip
  /// replaces the receipt; an undone or superseded one goes from every surface. A receipt without
  /// Undo, which the model clears when the next item loads, stays out its time.
  nonisolated static func shown(after lastSkip: PlaybackSkipReceipt?, showing: PlaybackSkipReceipt?)
    -> PlaybackSkipReceipt?
  {
    if let lastSkip { return lastSkip }
    return showing?.canUndo == true ? nil : showing
  }

  /// Called by every surface that sees a skip. The first call for a skip announces it and starts
  /// its clock, so the mini and expanded players neither both speak nor disagree about how long
  /// is left.
  @MainActor
  static func note(_ receipt: PlaybackSkipReceipt) {
    guard current?.receipt != receipt else { return }
    current = (receipt, .now)
    AccessibilityNotification.Announcement(announcement(for: receipt)).post()
  }

  /// How long `receipt` has left on screen, or nil once its time is up or if it was never seen.
  @MainActor
  static func remaining(for receipt: PlaybackSkipReceipt) -> Duration? {
    guard let current, current.receipt == receipt else { return nil }
    let left = visibleDuration - (ContinuousClock.now - current.seenAt)
    return left > .zero ? left : nil
  }

  @MainActor private static var current: (receipt: PlaybackSkipReceipt, seenAt: ContinuousClock.Instant)?
}

/// Follows `PlaybackModel.lastSkip` for one surface. A skip shows until `visibleDuration` after it
/// happened, including on a surface that appears part way through, such as the expanded player
/// opened from the mini player to reach Undo. With `staysForVoiceOver`, it stays under VoiceOver
/// until dismissed, since a timed control could go before it is reached.
struct AdSkipReceiptTracker: ViewModifier {
  let playback: PlaybackModel
  @Binding var visible: PlaybackSkipReceipt?
  let staysForVoiceOver: Bool

  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

  func body(content: Content) -> some View {
    content
      .onAppear {
        if let receipt = playback.lastSkip, AdSkipReceiptPresentation.remaining(for: receipt) != nil {
          visible = receipt
        }
      }
      .onChange(of: playback.lastSkip) { _, receipt in
        if let receipt { AdSkipReceiptPresentation.note(receipt) }
        visible = AdSkipReceiptPresentation.shown(after: receipt, showing: visible)
      }
      .task(id: visible) {
        guard let receipt = visible, staysForVoiceOver == false || voiceOverEnabled == false
        else { return }
        if let remaining = AdSkipReceiptPresentation.remaining(for: receipt) {
          try? await Task.sleep(for: remaining)
        }
        if Task.isCancelled == false, visible == receipt { visible = nil }
      }
  }
}

extension View {
  func tracksAdSkipReceipt(
    _ playback: PlaybackModel, visible: Binding<PlaybackSkipReceipt?>, staysForVoiceOver: Bool
  ) -> some View {
    modifier(
      AdSkipReceiptTracker(
        playback: playback, visible: visible, staysForVoiceOver: staysForVoiceOver))
  }
}

/// The expanded player's receipt: a glass capsule floating above the transport controls, so the
/// page's layout never moves for it.
struct AdSkipReceiptCapsule: View {
  let receipt: PlaybackSkipReceipt
  let onUndo: () -> Void
  let onDismiss: () -> Void

  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

  var body: some View {
    GlassContainer(in: Capsule()) {
      HStack(spacing: 0) {
        Label(AdSkipReceiptPresentation.text(for: receipt), systemImage: "forward.end")
          .font(WhirrTypeToken.subheadline.font)
          .padding(.leading, 18)
          .padding(.trailing, receipt.canUndo ? 4 : 18)
          .frame(minHeight: 44)
          .accessibilityLabel(AdSkipReceiptPresentation.announcement(for: receipt))
        if receipt.canUndo {
          Button(action: onUndo) {
            Text(AdSkipReceiptPresentation.undoTitle)
              .font(WhirrTypeToken.subheadline.font.weight(.semibold))
              .padding(.horizontal, 14)
              .frame(minHeight: 44)
              .contentShape(Rectangle())
          }
          .accessibilityLabel(AdSkipReceiptPresentation.undoActionName)
          .accessibilityIdentifier(PlayerAccessibilityID.adSkipUndo)
        }
        if voiceOverEnabled {
          Button(action: onDismiss) {
            Image(systemName: "xmark")
              .font(WhirrTypeToken.caption.font.weight(.semibold))
              .foregroundStyle(.secondary)
              .frame(minWidth: 44, minHeight: 44)
              .contentShape(Rectangle())
          }
          .accessibilityLabel("Dismiss")
        }
      }
      .buttonStyle(.plain)
      .lineLimit(1)
      .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
    // At large sizes under VoiceOver the label truncates rather than push the capsule past the
    // screen.
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityIdentifier(PlayerAccessibilityID.adSkipReceipt)
  }
}

/// Floats the receipt just above whatever it is applied to, fading under Reduce Motion and
/// rising otherwise. While no receipt shows, the loaded episode's analysis status takes its
/// place: a receipt is news, the status is not. With the setting off for an episode it would
/// cover, the one-time offer takes that place instead.
struct AdSkipReceiptOverlay: ViewModifier {
  let playback: PlaybackModel
  @State private var visible: PlaybackSkipReceipt?
  @State private var status: AdSkipStatusPresentation.Content?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .overlay(alignment: .top) {
        ZStack {
          if let receipt = visible {
            AdSkipReceiptCapsule(
              receipt: receipt,
              onUndo: {
                visible = nil
                playback.undoLastSkip()
              },
              onDismiss: { visible = nil }
            )
            .transition(
              reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
          } else if let status {
            AdSkipStatusCapsule(content: status, onCheckNow: { playback.checkLoadedEpisodeForAds() })
              .transition(.opacity)
          } else if playback.adAnalysisStatus == .notEnabled {
            AdSkipOfferSlot(playback: playback)
              .transition(.opacity)
          }
        }
        .animation(reduceMotion ? nil : .snappy, value: visible)
        .animation(reduceMotion ? nil : .snappy, value: status)
        .alignmentGuide(.top) { $0[.bottom] + WhirrSpacing.small }
      }
      .tracksAdSkipReceipt(playback, visible: $visible, staysForVoiceOver: true)
      .modifier(AdSkipStatusTracker(playback: playback, content: $status))
  }
}
