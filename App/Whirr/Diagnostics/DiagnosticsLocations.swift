import Foundation

/// Where the app keeps diagnostics it may later share. One root so account removal can delete
/// everything under it in a single `exportedDiagnosticsRootURL` step (SECURITY.md rule 8):
///
/// ```text
/// Application Support/Whirr/Diagnostics/
///   MetricKit/   crash and hang payloads stored on the launch after they happened
///   Exports/     the text bundle Settings › Report a Problem hands to the share sheet
/// ```
///
/// Excluded from backup: a diagnostics file is only ever useful on the device that produced it.
nonisolated enum DiagnosticsLocations {
  static func root(applicationSupportDirectory: URL) -> URL {
    applicationSupportDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
  }

  static func metricKit(root: URL) -> URL {
    root.appendingPathComponent("MetricKit", isDirectory: true)
  }

  static func exports(root: URL) -> URL {
    root.appendingPathComponent("Exports", isDirectory: true)
  }

  static func defaultMetricKit() -> URL {
    metricKit(root: root(applicationSupportDirectory: AppEnvironment.applicationSupportDirectory()))
  }

  /// Creates `directory` if needed and marks it excluded from backup. Idempotent.
  static func prepare(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutable = directory
    try mutable.setResourceValues(values)
  }
}
