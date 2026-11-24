import Foundation
import WatchPlayback
import WatchProtocol

/// Holds the files a background session hands over. The system removes its own temporary file when
/// the delegate method returns, so each is moved here synchronously and lives until the driver
/// commits it or deletes it.
nonisolated final class WatchRSSDownloadStaging: @unchecked Sendable {
  private let rootURL: URL
  private let lock = NSLock()
  /// Files this process moved, so the launch sweep cannot delete a commit still in flight.
  private var claimed: Set<String> = []

  init(rootURL: URL) {
    self.rootURL = rootURL
  }

  private var directory: URL { rootURL.appendingPathComponent("staging", isDirectory: true) }

  /// Moves `source` out of the session's temporary directory. Returns nil when it could not be
  /// moved, which the driver treats as a failed download.
  func preserve(_ source: URL, taskIdentifier: Int) -> URL? {
    lock.lock()
    defer { lock.unlock() }
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      return nil
    }
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var folder = directory
    try? folder.setResourceValues(values)
    let destination = directory.appendingPathComponent(
      "task-\(taskIdentifier)-\(UUID().uuidString.lowercased()).part")
    do {
      try fileManager.moveItem(at: source, to: destination)
    } catch {
      return nil
    }
    claimed.insert(destination.lastPathComponent)
    return destination
  }

  func discard(_ url: URL?) {
    guard let url else { return }
    lock.lock()
    claimed.remove(url.lastPathComponent)
    lock.unlock()
    try? FileManager.default.removeItem(at: url)
  }

  /// Removes files no callback in this process produced, which a process killed before its commit
  /// left behind. Only one process ever owns this session, so nothing live is swept.
  func sweepUnclaimed() {
    lock.lock()
    defer { lock.unlock() }
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return }
    for file in files where !claimed.contains(file.lastPathComponent) {
      try? FileManager.default.removeItem(at: file)
    }
  }
}
