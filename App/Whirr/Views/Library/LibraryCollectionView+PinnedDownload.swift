import AppModel
import DesignSystem
import SwiftUI

/// The list's download control: the book page's glyphs and `DownloadControlRole` colours, read
/// from the list's pin state.
nonisolated enum PinnedListDownloadPresentation {
  static func kind(for state: PinnedListDownloadModel.State) -> DownloadControlKind {
    switch state {
    case .off: .notDownloaded
    case .downloading: .downloading
    case .downloaded: .completed
    case .waitingForWiFi: .waitingForWiFi
    case .failed: .failed
    }
  }

  /// A downloaded list shows a tick rather than the book page's trash: tapping opens a menu here,
  /// so the glyph reports the state instead of naming the tap. Unenclosed, as every glyph in the
  /// bar's group must be.
  static func systemImage(for state: PinnedListDownloadModel.State) -> String {
    switch state {
    case .off, .downloading: "arrow.down"
    case .downloaded: "checkmark"
    case .waitingForWiFi: "wifi.slash"
    case .failed: "exclamationmark.triangle"
    }
  }

  static func progressFraction(for state: PinnedListDownloadModel.State) -> Double? {
    guard case .downloading(let done, let total) = state else { return nil }
    return total > 0 ? Double(done) / Double(total) : 0
  }

  static func accessibilityLabel(for state: PinnedListDownloadModel.State) -> String {
    PinnedListDownloadCopy.status(state).map { "Downloads, \($0)" } ?? "Download List"
  }
}

extension LibraryCollectionView {
  /// Off, a tap pins the list. On, a tap opens what it can do: retry what failed, or unpin.
  @ViewBuilder var pinnedDownloadControl: some View {
    let pin = pinModel
    let state = pin.state
    Group {
      if pin.isPinned {
        Menu {
          if let status = PinnedListDownloadCopy.status(state) {
            Text(status)
          }
          if case .failed = state {
            Button(PinnedListDownloadCopy.menuTryAgain, systemImage: "arrow.clockwise") {
              Task { await pin.retryFailed() }
            }
          }
          Button(PinnedListDownloadCopy.menuRemove, systemImage: "trash", role: .destructive) {
            Task { await pin.turnOff() }
          }
        } label: {
          pinnedDownloadGlyph(state)
        }
      } else {
        Button {
          Task { await pin.turnOn() }
        } label: {
          pinnedDownloadGlyph(state)
        }
      }
    }
    .disabled(pin.isWorking || model.state == .unavailable)
    .accessibilityLabel(PinnedListDownloadPresentation.accessibilityLabel(for: state))
    .accessibilityIdentifier(LibraryAccessibilityID.collectionPinnedDownload)
  }

  func pinnedDownloadHost(_ content: some View) -> some View {
    let pin = pinModel
    return
      content
      .alert(
        pin.pendingConfirmation?.title ?? "",
        isPresented: Binding(
          get: { pin.pendingConfirmation != nil },
          set: { if $0 == false { pin.cancelConfirmation() } }),
        presenting: pin.pendingConfirmation
      ) { confirmation in
        Button(
          confirmation.confirmTitle, role: confirmation.action == .unpin ? .destructive : nil
        ) {
          Task { await pin.confirm(confirmation) }
        }
        Button("Cancel", role: .cancel) { pin.cancelConfirmation() }
      } message: { confirmation in
        Text(confirmation.message)
      }
      .alert(
        "Downloads",
        isPresented: Binding(
          get: { pin.errorMessage != nil },
          set: { if $0 == false { pin.dismissError() } })
      ) {
        Button("OK", role: .cancel) { pin.dismissError() }
      } message: {
        Text(pin.errorMessage ?? "")
      }
  }

  /// Sized as the book page's bubble sizes its ring: a stroked circle has no intrinsic size.
  @ViewBuilder private func pinnedDownloadGlyph(_ state: PinnedListDownloadModel.State) -> some View {
    let systemImage = PinnedListDownloadPresentation.systemImage(for: state)
    Group {
      if let fraction = PinnedListDownloadPresentation.progressFraction(for: state) {
        DownloadProgressRing(progressFraction: fraction, systemImage: systemImage)
          .frame(width: 22, height: 22)
          .imageScale(.medium)
          .fixedSize()
      } else {
        Image(systemName: systemImage)
      }
    }
    .foregroundStyle(DownloadControlRole.tint(for: PinnedListDownloadPresentation.kind(for: state)))
  }
}
