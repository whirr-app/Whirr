import AppModel
import Foundation
import Persistence
import TestSupport
import Testing

@testable import Whirr

/// The once-per-process launch entry for the podcast sync runtime. `run` is the only seam that
/// reaches `PodcastCloudSyncComposition.runtime`, so "run was not called" is also "the runtime was
/// not touched".
@MainActor
@Suite("Podcast cloud sync launch")
struct PodcastCloudSyncLaunchTests {
  @MainActor
  private final class Harness {
    var events: [String] = []
    var databaseAvailable: Bool
    var onFirstCheck: (() -> Void)?
    private(set) var continuation: AsyncStream<Void>.Continuation?
    let database: AppDatabase

    init(databaseAvailable: Bool) throws {
      self.databaseAvailable = databaseAvailable
      database = try AppDatabase.inMemory()
    }

    var seams: PodcastCloudSyncLaunch.Seams {
      PodcastCloudSyncLaunch.Seams(
        protectedDataDidBecomeAvailable: {
          self.events.append("register")
          return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { self.continuation = $0 }
        },
        databaseIfAvailable: {
          self.events.append("check")
          if let onFirstCheck = self.onFirstCheck {
            self.onFirstCheck = nil
            onFirstCheck()
            return nil
          }
          return self.databaseAvailable ? self.database : nil
        },
        resolve: { _ in
          self.events.append("resolve.start")
          await Task.yield()
          await Task.yield()
          self.events.append("resolve.end")
        },
        run: { self.events.append("run") })
    }

    var work: [String] { events.filter { $0 != "register" && $0 != "check" } }

    func protectedDataBecameAvailable() {
      databaseAvailable = true
      continuation?.yield()
    }
  }

  /// Waits for the launch task to acknowledge `count` availability checks. After a failed check it
  /// can only be suspended on the protected-data stream, so nothing else can happen until a yield.
  private func awaitChecks(_ count: Int, in harness: Harness) async {
    await waitUntil("\(count) availability checks") {
      harness.events.filter { $0 == "check" }.count >= count
    }
  }

  @Test("a second start is a no-op")
  func secondStartIsNoOp() async throws {
    let harness = try Harness(databaseAvailable: true)
    let launch = PodcastCloudSyncLaunch(seams: harness.seams)
    let first = launch.start()
    let second = launch.start()
    await first.value
    await second.value
    #expect(launch.isStarted)
    #expect(harness.events.filter { $0 == "register" }.count == 1)
    #expect(harness.work == ["resolve.start", "resolve.end", "run"])
  }

  @Test("resolve finishes before run starts")
  func resolveFinishesBeforeRun() async throws {
    let harness = try Harness(databaseAvailable: true)
    await PodcastCloudSyncLaunch(seams: harness.seams).start().value
    #expect(harness.work == ["resolve.start", "resolve.end", "run"])
  }

  @Test("the protected-data observer is registered before the first availability check")
  func registersBeforeChecking() async throws {
    let harness = try Harness(databaseAvailable: true)
    await PodcastCloudSyncLaunch(seams: harness.seams).start().value
    #expect(Array(harness.events.prefix(2)) == ["register", "check"])
  }

  @Test("with the database unavailable, neither resolve nor run happens")
  func unavailableDatabaseTouchesNothing() async throws {
    let harness = try Harness(databaseAvailable: false)
    let launch = PodcastCloudSyncLaunch(seams: harness.seams)
    let task = launch.start()
    await awaitChecks(1, in: harness)
    #expect(harness.events == ["register", "check"])
    #expect(harness.work.isEmpty)

    harness.continuation?.finish()
    await task.value
    #expect(harness.work.isEmpty)
  }

  @Test("after the protected-data notification, resolve then run happen once")
  func notificationStartsTheRuntimeOnce() async throws {
    let harness = try Harness(databaseAvailable: false)
    let launch = PodcastCloudSyncLaunch(seams: harness.seams)
    let task = launch.start()
    await awaitChecks(1, in: harness)
    #expect(harness.work.isEmpty)

    harness.protectedDataBecameAvailable()
    await task.value
    // A later unlock, and a later launch call, find the work already done.
    harness.continuation?.yield()
    await launch.start().value
    #expect(harness.events.filter { $0 == "check" }.count == 2)
    #expect(harness.work == ["resolve.start", "resolve.end", "run"])
  }

  @Test("a notification still unavailable to open waits for the next one")
  func notificationBeforeTheDatabaseOpensKeepsWaiting() async throws {
    let harness = try Harness(databaseAvailable: false)
    let task = PodcastCloudSyncLaunch(seams: harness.seams).start()
    await awaitChecks(1, in: harness)
    harness.continuation?.yield()
    await awaitChecks(2, in: harness)
    #expect(harness.work.isEmpty)

    harness.protectedDataBecameAvailable()
    await task.value
    #expect(harness.work == ["resolve.start", "resolve.end", "run"])
  }

  @Test("a notification that arrives before the availability check is not lost")
  func notificationBeforeTheCheckIsNotLost() async throws {
    let harness = try Harness(databaseAvailable: false)
    // The unlock lands between registering and the first check: that check still fails, and only
    // the buffered notification can bring the launch back.
    harness.onFirstCheck = { harness.protectedDataBecameAvailable() }
    await PodcastCloudSyncLaunch(seams: harness.seams).start().value
    #expect(harness.work == ["resolve.start", "resolve.end", "run"])
  }

  @Test("launching the test host starts the entry once, with consent closed and sync off")
  func testHostLaunchDoesNotStartSync() async throws {
    // `didFinishLaunching` runs in the unit-test host. It starts the entry, but on the dedicated
    // test simulator no listener has consented, so nothing is resolved and no session exists.
    #expect(PodcastCloudSyncLaunch.shared.isStarted)
    #expect(PodcastCloudSyncComposition.gate.allowsCloudWork == false)
    let runtime = try #require(PodcastCloudSyncComposition.runtime)
    #expect(await runtime.status() == .off)
  }
}
