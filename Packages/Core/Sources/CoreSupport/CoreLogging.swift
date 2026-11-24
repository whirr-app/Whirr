import os

public enum CoreLogging {
  /// Whirr's one unified-log subsystem (the bundle identifier), shared by the App and every
  /// package logger. Settings › Report a Problem exports only this subsystem, so a logger under
  /// any other name is invisible to it.
  public static let subsystem = "com.remoteconcern.whirr"

  public static func logger(category: String) -> Logger {
    Logger(subsystem: subsystem, category: category)
  }
}
