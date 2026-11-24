import Foundation
import Persistence
import UIKit

/// Starts the podcast iCloud sync runtime once per process, from app launch rather than from a
/// scene, so a background launch for a CloudKit push has an engine to receive it.
///
/// Before the first unlock since boot nothing that reads consent or the database may run: consent
/// is an `AfterFirstUnlock` Keychain item the runtime reads once, then only on change, so an early
/// `false` would keep sync off until the next launch. The launch therefore waits for protected
/// data, registering the observer before the first availability check so an unlock between the two
/// is not missed. `PodcastCloudSyncComposition.runtime` is built only by `run`, after the database
/// opens; it stays a lazy singleton because composition sites capture it once.
final class PodcastCloudSyncLaunch {
  struct Seams {
    /// Must register its observer synchronously, when called, and buffer what arrives.
    var protectedDataDidBecomeAvailable: () -> AsyncStream<Void>
    var databaseIfAvailable: () -> AppDatabase?
    var resolve: (AppDatabase) async -> Void
    var run: () async -> Void
  }

  static let shared = PodcastCloudSyncLaunch(seams: .production)

  private let seams: Seams
  private var task: Task<Void, Never>?

  init(seams: Seams) {
    self.seams = seams
  }

  var isStarted: Bool { task != nil }

  /// The production entry, from `application(_:didFinishLaunchingWithOptions:)`. The UI harness
  /// composes no account and must not start sync.
  static func startForLaunch() {
    #if DEBUG || PERF_INVESTIGATION
      guard !UIHarness.isActive else { return }
    #endif
    shared.start()
  }

  /// Resolves the installation identity, then follows consent for the life of the process. A
  /// second call is a no-op. Returns the launch task so tests can await the part that finishes.
  @discardableResult
  func start() -> Task<Void, Never> {
    if let task { return task }
    let seams = seams
    let availability = seams.protectedDataDidBecomeAvailable()
    let task = Task {
      guard let database = await Self.awaitDatabase(seams: seams, availability: availability) else { return }
      // Resolve before any sync engine exists.
      await seams.resolve(database)
      await seams.run()
    }
    self.task = task
    return task
  }

  private static func awaitDatabase(seams: Seams, availability: AsyncStream<Void>) async -> AppDatabase? {
    if let database = seams.databaseIfAvailable() { return database }
    for await _ in availability {
      if let database = seams.databaseIfAvailable() { return database }
    }
    return nil
  }
}

extension PodcastCloudSyncLaunch.Seams {
  static var production: Self {
    Self(
      protectedDataDidBecomeAvailable: { ProtectedDataWakeUp.stream() },
      databaseIfAvailable: { DatabaseHardware.sharedIfAvailable() },
      resolve: { database in await PodcastCloudLaunchSequence.resolveForLaunch(database: database) },
      run: { await PodcastCloudSyncComposition.runForLaunch() })
  }
}
