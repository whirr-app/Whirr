import Foundation

/// The leftovers of A's `transferFile` ingress. B's Watch downloads write into the received-episode
/// store directly, so nothing accepts a file here any more; what remains is the launch-time purge of
/// files an earlier build left in the inbox, and the sign-out removal of the same directory.
public enum WatchReceivedEpisodeInbox {
  public static func directory(applicationSupport: URL) -> URL {
    applicationSupport.appendingPathComponent("WatchEpisodeInbox", isDirectory: true)
  }

  /// Removes files older than `date`, including half pairs left by a crash inside the retired
  /// accept. A file with an unreadable date is kept: deleting a possibly in-flight move loses an
  /// episode, and nothing in this build writes here.
  public static func purge(olderThan date: Date, directory: URL) {
    let fileManager = FileManager.default
    guard
      let urls = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])
    else { return }
    for url in urls where url.pathExtension == "audio" || url.pathExtension == "json" {
      guard
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
          .contentModificationDate
      else { continue }
      if modified < date { try? fileManager.removeItem(at: url) }
    }
  }

  public static func removeAll(directory: URL) {
    try? FileManager.default.removeItem(at: directory)
  }
}
