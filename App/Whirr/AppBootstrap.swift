import Foundation
import Persistence
import UIKit

/// What the store says about the account, read once before a launch graph is composed so that a
/// read that fails is never mistaken for "no account".
nonisolated struct AccountLaunchState: Sendable {
  var account: AccountRecord?
  var removalIsPending: Bool
}

/// The step every entry point shares before the full graph exists: the phone scene, an App
/// Intent, a Watch wake and a CarPlay scene can each run it first, and before the first unlock
/// since boot.
nonisolated enum AppBootstrap {
  enum Failure: Equatable, Sendable {
    /// The store would not open although protected data is readable: not a locked phone.
    case databaseUnopenable
    /// The store opened but its account or removal-journal row could not be read.
    case accountUnreadable
  }

  struct Launch: Sendable {
    let database: AppDatabase
    let accountState: AccountLaunchState
  }

  enum Outcome: Sendable {
    /// Before the first unlock since boot. Retried when protected data becomes available.
    case storageUnavailable
    case failed(Failure)
    case ready(Launch)
  }

  /// `isProtectedDataAvailable` only classifies a store that failed to open; the opener's own
  /// success is the readiness truth, because that flag is also false on a locked phone that has
  /// been unlocked once, when the store's `completeUntilFirstUserAuthentication` files open.
  static func run(database: () -> AppDatabase?, isProtectedDataAvailable: () -> Bool) -> Outcome {
    guard let database = database() else {
      return isProtectedDataAvailable() ? .failed(.databaseUnopenable) : .storageUnavailable
    }
    do {
      let account = try AccountDAO(database: database).fetch()
      let removalIsPending = try AccountRemovalJournalStore(database: database).fetch() != nil
      return .ready(
        Launch(
          database: database,
          accountState: AccountLaunchState(account: account, removalIsPending: removalIsPending)))
    } catch {
      return .failed(.accountUnreadable)
    }
  }

  @MainActor static func production() -> Outcome {
    run(
      database: { launchSpan("bootstrap.openDatabase") { DatabaseHardware.sharedIfAvailable() } },
      isProtectedDataAvailable: { UIApplication.shared.isProtectedDataAvailable })
  }
}

/// The one "retry now" signal for work that found the store closed before the first unlock. It
/// says only that a retry is worth making; whether the store opens is the answer.
enum ProtectedDataWakeUp {
  static func stream() -> AsyncStream<Void> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let center = NotificationCenter.default
      let observer = center.addObserver(
        forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
      ) { _ in continuation.yield() }
      nonisolated(unsafe) let token = observer
      continuation.onTermination = { _ in center.removeObserver(token) }
    }
  }
}
