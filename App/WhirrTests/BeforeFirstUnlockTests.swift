import Foundation
import Persistence
import Testing

@testable import Whirr

/// A background launch before the first unlock cannot open the protected database. Background
/// entry points must see that as "nothing to do yet"; the opener has no trapping accessor.
@Suite("Background entry before first unlock")
struct BeforeFirstUnlockTests {

  @Test("a failed open is not cached, so a later open succeeds")
  func failedOpenIsRetried() {
    let attempts = AttemptCounter()
    let value = RetryingLazyValue<Int> {
      attempts.increment()
      if attempts.count == 1 { throw CocoaError(.fileReadNoPermission) }
      return 42
    }

    #expect(value.get() == nil)
    #expect(value.get() == 42)
    #expect(attempts.count == 2)
  }

  @Test("a successful open is made once and reused")
  func successfulOpenIsCached() {
    let attempts = AttemptCounter()
    let value = RetryingLazyValue<Int> {
      attempts.increment()
      return attempts.count
    }

    #expect(value.get() == 1)
    #expect(value.get() == 1)
    #expect(attempts.count == 1)
  }

  @MainActor
  @Test("with no database a background wake composes nothing")
  func noDatabaseComposesNothing() {
    #expect(PodcastBackgroundRefreshHardware.backgroundAccount(database: nil) == nil)
    #expect(PodcastBackgroundRefreshHardware.backgroundServices(database: nil) == nil)
  }

  @Test("with no database the refresh request is kept, so the wake chain survives")
  func noDatabaseKeepsTheRefreshRequest() {
    #expect(PodcastBackgroundRefreshHardware.refreshRequestAction(database: nil) == .submit)
  }

  @Test("a readable database with no account cancels the refresh request")
  func noAccountCancelsTheRefreshRequest() throws {
    let database = try AppDatabase.inMemory()
    #expect(PodcastBackgroundRefreshHardware.refreshRequestAction(database: database) == .cancel)
  }

  @Test("a readable database with an account submits the refresh request")
  func accountSubmitsTheRefreshRequest() throws {
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "before-first-unlock",
        serverBaseURL: "https://before-first-unlock.invalid",
        serverUserId: "before-first-unlock-user",
        serverVersion: "2.35.1"))
    #expect(PodcastBackgroundRefreshHardware.refreshRequestAction(database: database) == .submit)
  }
}

nonisolated private final class AttemptCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func increment() {
    lock.lock()
    storage += 1
    lock.unlock()
  }
}
