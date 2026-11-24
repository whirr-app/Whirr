import AppModel
import Combine
import SwiftUI
import UIKit

extension View {
  /// Explains a refused New Episode Notifications enable. `refusal` belongs to the presenting
  /// screen's own model, so a pushed screen never presents an alert raised beneath it.
  func notificationEnableRefusalAlert(
    _ refusal: NotificationEnableRefusal?, dismiss: @escaping () -> Void
  ) -> some View {
    alert(
      refusal?.title ?? "",
      isPresented: Binding(get: { refusal != nil }, set: { if $0 == false { dismiss() } }),
      presenting: refusal
    ) { refusal in
      if refusal.offersSystemSettings {
        Button(SettingsCopy.openSystemSettingsTitle) { SystemSettingsLink.open() }
        Button("Cancel", role: .cancel) {}
      } else {
        Button("OK", role: .cancel) {}
      }
    } message: { refusal in
      Text(refusal.message)
    }
  }

  /// Background App Refresh and Low Power Mode can change while a settings screen is open, with
  /// no scene activation to prompt a refresh.
  func refreshesOnBackgroundRefreshChanges(
    _ model: PodcastNotificationSettingsModel?
  ) -> some View {
    onReceive(
      NotificationCenter.default
        .publisher(for: UIApplication.backgroundRefreshStatusDidChangeNotification)
        .merge(
          with: NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
        )
        .receive(on: RunLoop.main)
    ) { _ in
      model?.sceneDidBecomeActive()
    }
  }
}

enum SystemSettingsLink {
  static func open() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }
}
