import Foundation
import SyncEngine

/// Real `PowerObserving`, wrapping `ProcessInfo.isLowPowerModeEnabled` +
/// `.processInfoPowerStateDidChangeNotification` (ARCHITECTURE.md §3: the `NWPathMonitor`/
/// `ProcessInfo` adapter lives in App).
final class RealPowerObserving: PowerObserving, @unchecked Sendable {
  private let processInfo: ProcessInfo
  private let notificationCenter: NotificationCenter
  private var observer: NSObjectProtocol?

  var isLowPowerModeEnabled: Bool { processInfo.isLowPowerModeEnabled }

  init(processInfo: ProcessInfo = .processInfo, notificationCenter: NotificationCenter = .default) {
    self.processInfo = processInfo
    self.notificationCenter = notificationCenter
  }

  func startObserving(onChange: @escaping @Sendable (Bool) -> Void) {
    observer = notificationCenter.addObserver(
      forName: .NSProcessInfoPowerStateDidChange, object: processInfo, queue: nil
    ) { [weak self] _ in
      guard let self else { return }
      onChange(self.processInfo.isLowPowerModeEnabled)
    }
  }

  func stopObserving() {
    if let observer {
      notificationCenter.removeObserver(observer)
    }
  }
}
