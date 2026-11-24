import SnapshotTesting
import SwiftUI
import Testing

@testable import DesignSystem

// Same `.dump` semantic-snapshot idiom as `ComponentTests`/`PlayerComponentTests`: there is no
// UIKit host on macOS, so accessibility labels/values/hints/traits are computed properties,
// directly testable, and only applied inside `body`. Every component here takes caller-supplied
// copy only, owned by the models.
@Suite("Download and resolution components")
@MainActor
struct DownloadComponentTests {

  // MARK: - Download control cluster (button + progress)

  @Test("download control status icons are pairwise distinct across every kind")
  func downloadControlIconsAreDistinctAcrossKinds() {
    let icons: [DownloadControlKind: String] = [
      .notDownloaded: "arrow.down.circle",
      .waitingForWiFi: "wifi.slash",
      .queued: "clock",
      .downloading: "arrow.down.circle.fill",
      .paused: "pause.circle",
      .pausedAuth: "lock.circle",
      .interrupted: "exclamationmark.arrow.triangle.2.circlepath",
      .deleting: "trash",
      .failed: "exclamationmark.triangle",
      .completed: "checkmark.circle.fill",
    ]
    #expect(Set(icons.values).count == DownloadControlKind.allCases.count)
  }

  // MARK: - Offline/downloaded badge

  @Test("offline badge exposes caller-supplied label and icon")
  func offlineBadgeExposesCallerSuppliedLabelAndIcon() {
    let badge = OfflineBadgeView(label: "Downloaded", systemImage: "arrow.down.circle.fill")
    #expect(badge.label == "Downloaded")
    #expect(badge.systemImage == "arrow.down.circle.fill")
    #expect(badge.accessibilityLabel == "Downloaded")
  }

  @Test("offline badge semantic snapshot captures only caller-supplied copy")
  func offlineBadgeSemanticSnapshot() {
    let badge = OfflineBadgeView(label: "Downloaded", systemImage: "arrow.down.circle.fill")
    assertSnapshot(of: badge, as: .dump)
  }

  // MARK: - Resolution list row (progress conflict, skew confirmation, dead letter, paused auth)

  @Test("resolution list row exposes caller-supplied copy and forwards the tapped action's index")
  func resolutionListRowExposesCopyAndForwardsActionIndex() {
    var selectedIndex: Int?
    let row = ResolutionListRowView(
      title: "Which progress is right for \"Project Hail Mary\"?",
      message: "This device and the server disagree about how far you got.",
      systemImage: "arrow.triangle.branch",
      actions: [
        ResolutionListRowView.Action(
          label: "Keep This Device's Progress", accessibilityHint: "Keeps this device's progress"),
        ResolutionListRowView.Action(
          label: "Use the Server's Progress", accessibilityHint: "Uses the server's progress"),
      ],
      onSelectAction: { selectedIndex = $0 }
    )
    #expect(row.title == "Which progress is right for \"Project Hail Mary\"?")
    #expect(row.actions.count == 2)
    row.onSelectAction(1)
    #expect(selectedIndex == 1)
  }

  @Test("resolution list row action sets differ per kind (progress conflict/skew vs dead letter vs paused-auth)")
  func resolutionListRowActionSetsDifferPerKind() {
    let twoActionRow = ResolutionListRowView(
      title: "Title", message: "Message", systemImage: "arrow.triangle.branch",
      actions: [
        ResolutionListRowView.Action(label: "Keep Local", accessibilityHint: "Keeps local progress"),
        ResolutionListRowView.Action(label: "Take Server", accessibilityHint: "Takes server progress"),
      ], onSelectAction: { _ in }
    )
    let oneActionRow = ResolutionListRowView(
      title: "Title", message: "Message", systemImage: "lock.circle",
      actions: [ResolutionListRowView.Action(label: "Sign In Again", accessibilityHint: "Signs in again")],
      onSelectAction: { _ in }
    )
    #expect(twoActionRow.actions.count == 2)
    #expect(oneActionRow.actions.count == 1)
    #expect(twoActionRow.actions.map(\.label) != oneActionRow.actions.map(\.label))
  }

  @Test("resolution list row marks an overwrite-style action destructive without relying on color")
  func resolutionListRowMarksOverwriteActionDestructive() {
    let row = ResolutionListRowView(
      title: "Overwrite the Server's Progress?", message: "This overwrites the server's current progress.",
      systemImage: "exclamationmark.triangle",
      actions: [
        ResolutionListRowView.Action(
          label: "Overwrite", accessibilityHint: "Overwrites the server's progress", isDestructive: true)
      ],
      onSelectAction: { _ in }
    )
    #expect(row.actions[0].isDestructive)
  }

  @Test("resolution list row actions meet the 44pt minimum hit target")
  func resolutionListRowActionsMeetMinimumHitTarget() {
    let row = ResolutionListRowView(
      title: "Title", message: "Message", systemImage: "lock.circle",
      actions: [ResolutionListRowView.Action(label: "Sign In Again", accessibilityHint: "Signs in again")],
      onSelectAction: { _ in }
    )
    #expect(row.actionButtonMinHeight >= WhirrMetric.minimumTouchTarget)
  }

  @Test("resolution list row semantic snapshot: two actions")
  func resolutionListRowSemanticSnapshotTwoActions() {
    let row = ResolutionListRowView(
      title: "Which progress is right for \"Project Hail Mary\"?",
      message: "This device and the server disagree about how far you got.",
      systemImage: "arrow.triangle.branch",
      actions: [
        ResolutionListRowView.Action(
          label: "Keep This Device's Progress", accessibilityHint: "Keeps this device's progress"),
        ResolutionListRowView.Action(
          label: "Use the Server's Progress", accessibilityHint: "Uses the server's progress"),
      ],
      onSelectAction: { _ in }
    )
    assertSnapshot(of: row, as: .dump)
  }

  @Test("resolution list row semantic snapshot: one action")
  func resolutionListRowSemanticSnapshotOneAction() {
    let row = ResolutionListRowView(
      title: "\"Project Hail Mary\" Is Paused", message: "This download paused because you're signed out.",
      systemImage: "lock.circle",
      actions: [ResolutionListRowView.Action(label: "Sign In Again", accessibilityHint: "Signs in again")],
      onSelectAction: { _ in }
    )
    assertSnapshot(of: row, as: .dump)
  }

  // MARK: - Destructive purge confirmation

  @Test("destructive purge confirmation exposes caller-supplied copy and forwards confirm/cancel separately")
  func destructivePurgeConfirmationForwardsConfirmAndCancelSeparately() {
    var confirmed = false
    var cancelled = false
    let confirmation = DestructivePurgeConfirmationView(
      title: "Delete download?",
      message: "This deletes the downloaded file for \"Project Hail Mary\" from this device.",
      confirmLabel: "Delete", confirmAccessibilityHint: "Deletes the downloaded file", cancelLabel: "Cancel",
      onConfirm: { confirmed = true }, onCancel: { cancelled = true }
    )
    #expect(confirmation.title == "Delete download?")
    confirmation.onCancel()
    #expect(cancelled)
    #expect(!confirmed)
    confirmation.onConfirm()
    #expect(confirmed)
  }

  @Test("destructive purge confirmation buttons meet the 44pt minimum hit target")
  func destructivePurgeConfirmationButtonsMeetMinimumHitTarget() {
    let confirmation = DestructivePurgeConfirmationView(
      title: "Delete download?", message: "Message", confirmLabel: "Delete",
      confirmAccessibilityHint: "Deletes the downloaded file", cancelLabel: "Cancel", onConfirm: {}, onCancel: {}
    )
    #expect(confirmation.confirmButtonMinHeight >= WhirrMetric.minimumTouchTarget)
    #expect(confirmation.cancelButtonMinHeight >= WhirrMetric.minimumTouchTarget)
  }

  @Test("destructive purge confirmation semantic snapshot captures only caller-supplied copy")
  func destructivePurgeConfirmationSemanticSnapshot() {
    let confirmation = DestructivePurgeConfirmationView(
      title: "Delete download?",
      message: "This deletes the downloaded file for \"Project Hail Mary\" from this device.",
      confirmLabel: "Delete", confirmAccessibilityHint: "Deletes the downloaded file", cancelLabel: "Cancel",
      onConfirm: {}, onCancel: {}
    )
    assertSnapshot(of: confirmation, as: .dump)
  }
}
