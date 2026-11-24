import ABSApi
import Foundation
import Persistence
import Testing

@testable import Whirr

@MainActor
@Suite("Endpoint switch composition", .serialized)
struct EndpointSwitchCompositionTests {
  private let firstURL = "http://192.168.1.20:13378"
  private let secondURL = "https://nas.tail1234.ts.net"

  @Test("a reachable alternate advances the generation and is used by a fresh composition")
  func reachableAlternateRebuildsComposition() async throws {
    let database = try makeDatabase()
    let accountDAO = AccountDAO(database: database)
    let endpointDAO = AccountEndpointDAO(database: database)
    let account = try #require(try accountDAO.fetch())
    let reachable = secondURL
    let coordinator = makeCoordinator(
      accountDAO: accountDAO,
      endpointDAO: endpointDAO,
      probe: { endpoint in
        if endpoint.normalizedURL != reachable { throw URLError(.cannotConnectToHost) }
      })

    await coordinator.trigger(.foreground)

    #expect(coordinator.switchGeneration == 1)
    #expect(try accountDAO.fetch()?.serverBaseURL == secondURL)

    let hardware = PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering())
    let rebuilt = RootComposition(hardware: hardware, mode: .runtime, database: database, watchCompanionRuntime: nil)
    #expect(rebuilt.environment.composition == .runtime)
    let currentAccount = try #require(try accountDAO.fetch())
    let resolvedServer = AppEnvironment.serverConfig(
      for: currentAccount,
      factory: ABSServerConfigFactory(customHeaderStore: InMemoryCustomHeaderStore()))
    #expect(resolvedServer.baseURL.absoluteString == secondURL)
    #expect(account.serverBaseURL == firstURL)
  }

  @Test("an active transfer defers the rebuild while retaining the selected endpoint")
  func activeTransferDefersRebuild() async throws {
    let database = try makeDatabase()
    let accountDAO = AccountDAO(database: database)
    let endpointDAO = AccountEndpointDAO(database: database)
    let transfers = LockedSwitchValue(true)
    let coordinator = makeCoordinator(
      accountDAO: accountDAO,
      endpointDAO: endpointDAO,
      hasActiveTransfers: { transfers.value },
      probe: { endpoint in
        if endpoint.normalizedURL != secondURL { throw URLError(.cannotConnectToHost) }
      })

    await coordinator.trigger(.foreground)

    #expect(coordinator.switchGeneration == 0)
    #expect(try accountDAO.fetch()?.serverBaseURL == secondURL)
    #expect(coordinator.deferredSwitch)
  }

  @Test("a network change moves an app parked on the fallback back to the preferred address")
  func networkChangeReturnsToPreferred() async throws {
    let database = try makeDatabase()
    let accountDAO = AccountDAO(database: database)
    let endpointDAO = AccountEndpointDAO(database: database)
    let accountID = try #require(try accountDAO.fetch()?.id)
    try endpointDAO.setActive(accountId: accountID, normalizedURL: secondURL)
    // The preferred address answers (slowly) and the preference window opens only after it has,
    // so the outcome never depends on task scheduling. The fallback stays silent until the
    // selection cancels it: a fallback answering after the window is covered by the tests above.
    let preferredAnswered = SwitchLatch()
    let coordinator = makeCoordinator(
      accountDAO: accountDAO, endpointDAO: endpointDAO, windowOpensAfter: preferredAnswered,
      probe: { endpoint in
        if endpoint.normalizedURL == firstURL {
          try await Task.sleep(for: .milliseconds(100))
          await preferredAnswered.open()
        } else {
          try await Task.sleep(for: .seconds(30))
        }
      })

    await coordinator.trigger(.networkChanged)

    #expect(coordinator.switchGeneration == 1)
    #expect(try accountDAO.fetch()?.serverBaseURL == firstURL)
  }

  @Test("a switch deferred by playback completes once playback goes idle")
  func deferredSwitchCompletesWhenPlaybackStops() async throws {
    let database = try makeDatabase()
    let accountDAO = AccountDAO(database: database)
    let endpointDAO = AccountEndpointDAO(database: database)
    let playing = LockedSwitchValue(true)
    let transfers = LockedSwitchValue(false)
    let coordinator = makeCoordinator(
      accountDAO: accountDAO,
      endpointDAO: endpointDAO,
      isPlaybackActive: { playing.value },
      hasActiveTransfers: { transfers.value },
      probe: { endpoint in
        if endpoint.normalizedURL != secondURL { throw URLError(.cannotConnectToHost) }
      })

    await coordinator.trigger(.networkChanged)
    #expect(coordinator.deferredSwitch)
    #expect(coordinator.switchGeneration == 0)

    // Still busy: nothing happens.
    await coordinator.completeDeferredSwitchIfIdle()
    #expect(coordinator.switchGeneration == 0)

    playing.value = false
    transfers.value = true
    await coordinator.completeDeferredSwitchIfIdle()
    #expect(coordinator.switchGeneration == 0)

    transfers.value = false
    await coordinator.completeDeferredSwitchIfIdle()
    #expect(coordinator.switchGeneration == 1)
    #expect(coordinator.deferredSwitch == false)

    // Nothing deferred any more: a further idle signal is a no-op.
    await coordinator.completeDeferredSwitchIfIdle()
    #expect(coordinator.switchGeneration == 1)
  }

  @Test("the artwork scope follows the account, not its address")
  func artworkScopeIgnoresAddress() throws {
    let database = try makeDatabase()
    let accountDAO = AccountDAO(database: database)
    let account = try #require(try accountDAO.fetch())
    var moved = account
    moved.serverBaseURL = secondURL

    #expect(
      AppEnvironment.preparedArtworkScope(for: account)
        == AppEnvironment.preparedArtworkScope(for: moved))

    var otherAccount = account
    otherAccount.credentialNamespace = "another-namespace"
    #expect(
      AppEnvironment.preparedArtworkScope(for: account)
        != AppEnvironment.preparedArtworkScope(for: otherAccount))
    #expect(
      AppEnvironment.preparedArtworkScope(for: account)
        != AppEnvironment.preparedArtworkScope(for: nil))
  }

  private func makeDatabase() throws -> AppDatabase {
    let database = try AppDatabase.inMemory()
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: UUID().uuidString,
        serverBaseURL: firstURL,
        serverUserId: "endpoint-switch-user",
        serverVersion: "2.36.0"))
    let accountID = try #require(account.id)
    let endpointDAO = AccountEndpointDAO(database: database)
    _ = try endpointDAO.insert(accountId: accountID, normalizedURL: firstURL, preferred: true)
    _ = try endpointDAO.insert(accountId: accountID, normalizedURL: secondURL, preferred: false)
    return database
  }

  private func makeCoordinator(
    accountDAO: AccountDAO,
    endpointDAO: AccountEndpointDAO,
    isPlaybackActive: @escaping @MainActor () -> Bool = { false },
    hasActiveTransfers: @escaping @MainActor @Sendable () async -> Bool = { false },
    windowOpensAfter: SwitchLatch? = nil,
    probe: @escaping @Sendable (AccountEndpointRecord) async throws -> Void
  ) -> EndpointSwitchCoordinator {
    EndpointSwitchCoordinator(
      accountDAO: accountDAO,
      accountEndpointDAO: endpointDAO,
      tokenStore: InMemoryTokenStore(),
      customHeaderStore: InMemoryCustomHeaderStore(),
      isPlaybackActive: isPlaybackActive,
      hasActiveTransfers: hasActiveTransfers,
      // The preference window elapses at once (or once `windowOpensAfter` opens) so the surviving
      // address wins after it; the probe
      // timeout must not fire before a probe answers, so it sleeps for real and is cancelled
      // with the selection.
      sleep: { duration in
        guard duration > 2 else {
          await windowOpensAfter?.wait()
          return
        }
        do {
          try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
          // The selection finished and cancelled its timeout; returning is the right response.
        } catch {}
      },
      probe: probe)
  }
}

private actor SwitchLatch {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func open() {
    isOpen = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}

private final class LockedSwitchValue: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: Bool

  init(_ storage: Bool) {
    self.storage = storage
  }

  var value: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }
    set {
      lock.lock()
      storage = newValue
      lock.unlock()
    }
  }
}
