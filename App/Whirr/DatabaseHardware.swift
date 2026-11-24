import Foundation
import Persistence

/// The process's one on-disk store, threaded through every `AppEnvironment` rebuild like
/// `PlaybackHardware` and `BackgroundDownloadHardware` (a `static let` that runs once).
///
/// A store per environment would make login (`RootView.rebuildAfterAuthentication`, a synchronous
/// main-thread handler) open a second `DatabasePool` on the file and re-run the migrator; with
/// `busyMode = .timeout(5)` that contention blocks.
nonisolated enum DatabaseHardware {
  /// The only way to the store, and it can fail: the files use
  /// `completeUntilFirstUserAuthentication`, so a launch before first unlock gets `nil` and a later
  /// call opens normally. Not `isProtectedDataAvailable`, which is also false on a locked device
  /// unlocked once, when these files are readable and overnight work runs. No trapping accessor or
  /// in-memory fallback: an unopenable store is a state `AppRuntime.readiness` reports
  /// (ARCHITECTURE.md), never an empty library.
  static func sharedIfAvailable() -> AppDatabase? {
    opener.get()
  }

  private static let databaseURL = applicationSupportDirectory().appendingPathComponent("whirr.sqlite")

  private static let opener = RetryingLazyValue<AppDatabase> {
    try? FileManager.default.createDirectory(
      at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    return try AppDatabase.onDisk(at: databaseURL, fileAttributes: POSIXFileAttributeApplier())
  }

  static func applicationSupportDirectory() -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("Whirr", isDirectory: true)
  }
}

/// Makes a value on first successful use and keeps it; a failed attempt is not remembered, so the
/// next call tries again. Calls are serialised, so the value is made at most once.
nonisolated final class RetryingLazyValue<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private let make: @Sendable () throws -> Value
  private var value: Value?

  init(_ make: @escaping @Sendable () throws -> Value) {
    self.make = make
  }

  func get() -> Value? {
    lock.lock()
    defer { lock.unlock() }
    if let value { return value }
    value = try? make()
    return value
  }
}
