import AppModel
import Foundation
import SyncEngine

/// One platform lookup with two different failure contracts below. The scheduler fails open;
/// Settings preserves `nil` so it never presents a sentinel as a real byte figure.
nonisolated private func availableCapacityForImportantUsage(at rootURL: URL) -> Int64? {
  let values = try? rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
  return values?.volumeAvailableCapacityForImportantUsage
}

/// Production `FreeSpaceReporting`. `volumeAvailableCapacityForImportantUsageKey` is the figure
/// Apple recommends for large downloads (it counts space the system may reclaim under pressure).
/// Read fresh on every call; `DownloadCoordinator.schedule()` is the only caller and re-evaluates
/// it each scheduling pass.
struct FileSystemFreeSpaceReporting: FreeSpaceReporting {
  let rootURL: URL

  func availableCapacityBytes() -> Int64 {
    availableCapacityForImportantUsage(at: rootURL) ?? Int64.max
  }
}

/// The optional form of the same capacity read, for the contextual Settings UI. Nonisolated
/// because the App target defaults declarations to `MainActor`; the synchronous filesystem lookup
/// runs in detached utility work rather than blocking UI.
struct FileSystemDeviceStorageCapacityReader: DeviceStorageCapacityReading, Sendable {
  let rootURL: URL

  nonisolated func availableCapacityBytes() async -> Int64? {
    let rootURL = rootURL
    return await Task.detached(priority: .utility) {
      availableCapacityForImportantUsage(at: rootURL)
    }.value
  }
}
