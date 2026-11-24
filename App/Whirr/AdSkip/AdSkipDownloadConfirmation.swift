import SwiftUI

/// The consent prompt before the speech model downloads, shared by Settings and the player's
/// offer. It takes a binding and callbacks rather than the settings model: Settings binds the
/// model's own `isConfirmingDownload`, which its toggle reads, and the offer binds state of its
/// own so a Settings page underneath never presents a second prompt. Look Back passes its own
/// message, and no Wi-Fi wait: the listener is waiting on the sheet for the download.
struct AdSkipDownloadConfirmation: ViewModifier {
  @Binding var isPresented: Bool
  var message = AdSkipSettingsCopy.downloadMessage
  var offersWiFiWait = true
  let onConfirm: (_ allowingCellular: Bool) -> Void
  let onCancel: () -> Void

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        AdSkipSettingsCopy.downloadTitle, isPresented: $isPresented, titleVisibility: .visible
      ) {
        if offersWiFiWait {
          Button(AdSkipSettingsCopy.downloadOnWiFi) { onConfirm(false) }
        }
        Button(AdSkipSettingsCopy.downloadNow) { onConfirm(true) }
        Button(AdSkipSettingsCopy.cancel, role: .cancel) { onCancel() }
      } message: {
        Text(message)
      }
  }
}

extension View {
  func adSkipDownloadConfirmation(
    isPresented: Binding<Bool>, message: String = AdSkipSettingsCopy.downloadMessage,
    offersWiFiWait: Bool = true, onConfirm: @escaping (_ allowingCellular: Bool) -> Void,
    onCancel: @escaping () -> Void = {}
  ) -> some View {
    modifier(
      AdSkipDownloadConfirmation(
        isPresented: isPresented, message: message, offersWiFiWait: offersWiFiWait,
        onConfirm: onConfirm, onCancel: onCancel))
  }
}
