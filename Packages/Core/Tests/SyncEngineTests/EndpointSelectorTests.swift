import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

@Suite("EndpointSelector")
struct EndpointSelectorTests {
  private let preferred = "http://192.168.1.20:13378"
  private let local = "http://books.local:13378"
  private let alternate = "https://nas.tail1234.ts.net"
  private let publicEndpoint = "https://books.example.org"

  @Test("prefers the preferred endpoint when both answer in the window")
  func preferredEndpointWinsWithinWindow() async throws {
    let fixture = try makeFixture(behaviors: [.success, .success])
    let selector = fixture.selector
    let selection = Task { await selector.select() }

    #expect(try fixture.accountDAO.fetch() != nil)
    #expect(try fixture.endpointDAO.fetchAll(accountId: fixture.accountID).count == 2)
    #expect(await fixture.script.waitForCallCount(2))

    #expect(await selection.value == .unchanged(active: preferred))
    #expect(try fixture.accountDAO.fetch()?.serverBaseURL == preferred)
    #expect(
      try fixture.endpointDAO.fetchAll(accountId: fixture.accountID).allSatisfy {
        $0.lastReachedAt == fixture.date
      })
  }

  @Test("stops waiting for other probes once the preferred endpoint answers")
  func preferredAnswerEndsSelectionWithoutWaitingForHangingProbes() async throws {
    let fixture = try makeFixture(behaviors: [.success, .hang])

    // Neither the preference window nor the probe timeout is ever released here.
    #expect(await fixture.selector.select() == .unchanged(active: preferred))
    let endpoints = try fixture.endpointDAO.fetchAll(accountId: fixture.accountID)
    #expect(endpoints[0].lastReachedAt == fixture.date)
    #expect(endpoints[1].lastReachedAt == nil)
    #expect(endpoints[1].lastFailedAt == nil)
  }

  @Test("an earlier lower-priority answer yields to the preferred answer")
  func preferredAnswerCanArriveSecond() async throws {
    let fixture = try makeFixture(behaviors: [.waitForRelease, .success])
    let selection = Task { await fixture.selector.select() }

    #expect(await fixture.script.waitForCallCount(2))
    #expect(await fixture.script.waitForReleaseWaiter(preferred))
    #expect(await fixture.clock.waitForWaiterCount(3))
    await fixture.script.release(preferred)

    // The preferred answer ends the selection on its own; the window timer is never released.
    #expect(await selection.value == .unchanged(active: preferred))
  }

  @Test("uses a later answer after the preference window")
  func laterAnswerWinsAfterWindow() async throws {
    let fixture = try makeFixture(behaviors: [.hang, .success])
    let selection = Task { await fixture.selector.select() }

    #expect(await fixture.script.waitForCallCount(2))
    #expect(await fixture.clock.waitForWaiterCount(3))
    fixture.clock.release(duration: 2)
    #expect(await fixture.script.waitForCallCount(2))
    fixture.clock.release(duration: 10)

    #expect(await selection.value == .switched(from: preferred, to: alternate))
    #expect(try fixture.endpointDAO.fetchAll(accountId: fixture.accountID).first?.lastFailedAt == fixture.date)
  }

  @Test("uses the first answer when no endpoint answers in the window")
  func firstAnswerAfterWindowWins() async throws {
    let fixture = try makeFixture(behaviors: [.hang, .waitForRelease])
    let selection = Task { await fixture.selector.select() }

    #expect(await fixture.script.waitForCallCount(2))
    #expect(await fixture.script.waitForReleaseWaiter(alternate))
    #expect(await fixture.clock.waitForWaiterCount(3))
    fixture.clock.release(duration: 2)
    await fixture.script.release(alternate)
    fixture.clock.release(duration: 10)

    #expect(await selection.value == .switched(from: preferred, to: alternate))
  }

  @Test("keeps the active endpoint when nothing answers")
  func nothingAnswersLeavesActiveEndpointUnchanged() async throws {
    let fixture = try makeFixture(behaviors: [.failure, .failure])
    let selection = Task { await fixture.selector.select() }

    #expect(await fixture.script.waitForCallCount(2))
    #expect(await fixture.clock.waitForWaiterCount(3))
    fixture.clock.release(duration: 2)

    #expect(await selection.value == .nothingAnswered(active: preferred))
    #expect(try fixture.accountDAO.fetch()?.serverBaseURL == preferred)
  }

  @Test("orders LAN, local, tailnet, and public endpoints deterministically")
  func endpointMatrixUsesStoredPreferenceOrder() async throws {
    let endpoints = [preferred, local, alternate, publicEndpoint]
    let fixture = try makeFixture(
      behaviors: [.failure, .success, .success, .success], endpointURLs: endpoints)
    let selection = Task { await fixture.selector.select() }

    #expect(await fixture.script.waitForCallCount(endpoints.count))
    #expect(await fixture.clock.waitForWaiterCount(endpoints.count + 1))
    fixture.clock.release(duration: 2)

    #expect(await selection.value == .switched(from: preferred, to: local))
  }

  @Test("a throwing probe is a failure and cannot win")
  func thrownProbeIsFailure() async throws {
    let fixture = try makeFixture(behaviors: [.failure, .success])
    let selection = Task { await fixture.selector.select() }

    #expect(await fixture.script.waitForCallCount(2))
    #expect(await fixture.clock.waitForWaiterCount(3))
    fixture.clock.release(duration: 2)

    #expect(await selection.value == .switched(from: preferred, to: alternate))
    let endpoints = try fixture.endpointDAO.fetchAll(accountId: fixture.accountID)
    #expect(endpoints[0].lastReachedAt == nil)
    #expect(endpoints[0].lastFailedAt == fixture.date)
    #expect(endpoints[1].lastReachedAt == fixture.date)
  }

  @Test("overlapping selections share one probe pass")
  func overlappingSelectionsCoalesce() async throws {
    // Both probes block until released, so the first pass is still in flight when the second
    // caller arrives and must attach to it rather than start its own probes.
    let fixture = try makeFixture(behaviors: [.waitForRelease, .waitForRelease])
    let first = Task { await fixture.selector.select() }
    #expect(await fixture.script.waitForCallCount(2))

    let secondStarted = SelectorFlag()
    let second = Task {
      await secondStarted.set()
      return await fixture.selector.select()
    }
    #expect(await waitUntil("second selection started") { await secondStarted.isSet })
    await fixture.script.release(alternate)
    await fixture.script.release(preferred)

    #expect(await first.value == .unchanged(active: preferred))
    #expect(await second.value == .unchanged(active: preferred))
    #expect(await fixture.script.callCount == 2)
  }

  @Test("a single endpoint is returned without probing")
  func singleEndpointDoesNotProbe() async throws {
    let fixture = try makeFixture(behaviors: [.success], includeAlternate: false)

    #expect(await fixture.selector.select() == .singleEndpoint)
    #expect(await fixture.script.callCount == 0)
  }

  private func makeFixture(
    behaviors: [ProbeBehavior], includeAlternate: Bool = true, endpointURLs: [String]? = nil
  ) throws -> SelectorFixture {
    let database = try AppDatabase.inMemory()
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "endpoint-selector-client",
        serverBaseURL: preferred,
        serverUserId: "endpoint-selector-user",
        serverVersion: "2.36.0"))
    let accountID = try #require(account.id)
    let endpointDAO = AccountEndpointDAO(database: database)
    let urls = endpointURLs ?? (includeAlternate ? [preferred, alternate] : [preferred])
    for (index, url) in urls.enumerated() {
      _ = try endpointDAO.insert(accountId: accountID, normalizedURL: url, preferred: index == 0)
    }

    let date = Date(timeIntervalSince1970: 500)
    let clock = SelectorTestClock()
    let script = SelectorProbeScript(
      behaviors: Dictionary(
        uniqueKeysWithValues: zip(
          urls, behaviors)))
    let selector = EndpointSelector(
      accountDAO: AccountDAO(database: database),
      accountEndpointDAO: endpointDAO,
      probe: { endpoint in try await script.probe(endpoint) },
      preferenceWindow: 2,
      probeTimeout: 10,
      sleep: { duration in await clock.sleep(duration) },
      now: { date })
    return SelectorFixture(
      selector: selector, accountDAO: AccountDAO(database: database), endpointDAO: endpointDAO,
      accountID: accountID, script: script, clock: clock, date: date)
  }
}

private actor SelectorFlag {
  private(set) var isSet = false
  func set() { isSet = true }
}

private struct SelectorFixture: Sendable {
  let selector: EndpointSelector
  let accountDAO: AccountDAO
  let endpointDAO: AccountEndpointDAO
  let accountID: Int64
  let script: SelectorProbeScript
  let clock: SelectorTestClock
  let date: Date
}

private enum ProbeBehavior: Sendable {
  case success
  case failure
  case waitForRelease
  case hang
}

private actor SelectorProbeScript {
  private let behaviors: [String: ProbeBehavior]
  private var calls: [String] = []
  // One held gate per endpoint whose probe parks until `release(_:)`.
  private let gates: [String: TestGate<Void>]

  init(behaviors: [String: ProbeBehavior]) {
    self.behaviors = behaviors
    var gates: [String: TestGate<Void>] = [:]
    for (url, behavior) in behaviors {
      switch behavior {
      case .waitForRelease, .hang:
        let gate = TestGate<Void>(label: "SelectorProbeScript probe of \(url)")
        gate.hold()
        gates[url] = gate
      case .success, .failure:
        break
      }
    }
    self.gates = gates
  }

  var callCount: Int { calls.count }

  func waitForCallCount(_ expected: Int) async -> Bool {
    await waitUntil("probe call count \(expected)") { calls.count >= expected }
  }

  func waitForReleaseWaiter(_ url: String) async -> Bool {
    await waitUntil("release waiter for \(url)") { (gates[url]?.parkedCount ?? 0) > 0 }
  }

  func probe(_ endpoint: AccountEndpointRecord) async throws {
    let url = endpoint.normalizedURL
    calls.append(url)
    switch behaviors[url] {
    case .success:
      return
    case .failure:
      throw URLError(.cannotConnectToHost)
    case .waitForRelease, .hang:
      await gates[url]?.pass()
      return
    case nil:
      throw URLError(.badURL)
    }
  }

  func release(_ url: String) {
    gates[url]?.releaseParked()
  }
}

private final class SelectorTestClock: @unchecked Sendable {
  // One gate per sleep duration. Releasing a duration opens its gate for good, so a sleep that
  // starts afterwards returns at once.
  private let gates = Locked<[TimeInterval: TestGate<Void>]>([:])
  // Counts sleeps started, not parked: a probe's timeout sleep is cancelled, and leaves its gate,
  // as soon as the probe settles, but the tests still need to know it began.
  private let startedSleeps = Locked(0)

  private func gate(for duration: TimeInterval, held: Bool) -> TestGate<Void> {
    gates.withValue { gates in
      if let gate = gates[duration] { return gate }
      let gate = TestGate<Void>(label: "SelectorTestClock sleep of \(duration)s")
      if held { gate.hold() }
      gates[duration] = gate
      return gate
    }
  }

  func sleep(_ duration: TimeInterval) async {
    guard duration > 0 else { return }
    startedSleeps.withValue { $0 += 1 }
    await gate(for: duration, held: true).pass()
  }

  func release(duration: TimeInterval) {
    gate(for: duration, held: false).release()
  }

  func waitForWaiterCount(_ expected: Int) async -> Bool {
    await waitUntil("clock waiter count \(expected)") { startedSleeps.value >= expected }
  }
}
