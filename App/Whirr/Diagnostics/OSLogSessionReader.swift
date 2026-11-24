import AppModel
import CoreSupport
import Foundation
import OSLog

/// The current process's unified-log entries for Whirr's subsystem. iOS exposes only the running
/// process's entries to an app, so this covers the launch the report is made from; earlier
/// launches are represented by the durable diagnostics events instead.
nonisolated struct OSLogSessionReader: SessionLogReading, Sendable {
  /// `DeviceTraceLog`'s DEBUG-only device traces. They name local files and row ids for someone
  /// reading a tethered device, never ship in Release, and have no place in a file a person is
  /// asked to trust; a debug build must not be the one that breaks the footer's promise.
  static let excludedCategories: Set<String> = ["trace"]

  func recentEntries(limit: Int) async throws -> [String] {
    let store = try OSLogStore(scope: .currentProcessIdentifier)
    let position = store.position(timeIntervalSinceLatestBoot: 0)
    let predicate = NSPredicate(format: "subsystem == %@", CoreLogging.subsystem)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss.SSS"

    var lines: [String] = []
    for entry in try store.getEntries(at: position, matching: predicate) {
      guard let log = entry as? OSLogEntryLog,
        let level = Self.name(for: log.level), Self.includes(category: log.category)
      else { continue }
      lines.append("\(formatter.string(from: log.date)) [\(log.category)] \(level): \(log.composedMessage)")
    }
    return Array(lines.suffix(limit))
  }

  static func includes(category: String) -> Bool {
    excludedCategories.contains(category) == false
  }

  /// Debug entries are left out: they are the noisiest and least useful in a shared file.
  static func name(for level: OSLogEntryLog.Level) -> String? {
    switch level {
    case .info: return "info"
    case .notice: return "notice"
    case .error: return "error"
    case .fault: return "fault"
    case .debug, .undefined: return nil
    @unknown default: return nil
    }
  }
}
