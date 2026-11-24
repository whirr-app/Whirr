import os

/// Persistence's one unified-log subsystem. It matches `CoreLogging.subsystem`; this target does
/// not depend on CoreSupport, so the constant is repeated here rather than imported.
enum PersistenceLogging {
  static let subsystem = "com.remoteconcern.whirr"

  static func logger(category: String) -> Logger {
    Logger(subsystem: subsystem, category: category)
  }
}
