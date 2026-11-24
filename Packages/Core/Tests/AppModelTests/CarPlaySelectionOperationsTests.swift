import Persistence
import PlayerCore
import TestSupport
import Testing

@testable import AppModel

/// Row taps as finite, exactly-once outcomes.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct CarPlaySelectionOperationsTests {
  @Test func acceptedSelectionStartsOnce() async throws {
    let operations = CarPlaySelectionOperations()
    let gate = Gate()
    let outcomeBook = try Self.book("a")
    async let outcome = operations.select(.play(outcomeBook)) { await gate.perform() }
    await gate.release(.accepted)

    #expect(await outcome == .started)
    #expect(gate.calls == 1)
    #expect(operations.isPending == false)
  }

  @Test func repeatedTapOnThePendingSelectionJoinsIt() async throws {
    let operations = CarPlaySelectionOperations()
    let gate = Gate()
    let book = try Self.book("a")
    async let first = operations.select(.play(book)) { await gate.perform() }
    async let second = operations.select(.play(book)) { await gate.perform() }
    await gate.release(.accepted)

    #expect(await [first, second] == [.started, .started])
    #expect(gate.calls == 1)
  }

  @Test func competingSelectionSupersedesThePendingOne() async throws {
    let operations = CarPlaySelectionOperations()
    let older = Gate()
    let newer = Gate()
    let firstBook = try Self.book("a")
    async let first = operations.select(.play(firstBook)) { await older.perform() }
    await older.started()
    let secondBook = try Self.book("b")
    async let second = operations.select(.play(secondBook)) { await newer.perform() }

    // The older tap is answered at once, before either start has finished.
    #expect(await first == .superseded)

    // Its late success must not be shown against the newer selection.
    await older.release(.accepted)
    await newer.release(.rejected(.preparationFailed))
    #expect(await second == .failed(.preparationFailed))
    #expect(operations.lateFailure(in: Self.state("a", phase: Self.failure)) == nil)
  }

  @Test func disconnectEndsEveryWaitWithoutWaitingForTheStart() async throws {
    let operations = CarPlaySelectionOperations()
    let gate = Gate()
    async let outcome = operations.select(.resumeLastPlayed) { await gate.perform() }
    await gate.started()
    operations.cancelAll()

    #expect(await outcome == .cancelled)
    #expect(operations.isPending == false)

    await gate.release(.accepted)
    #expect(operations.lateFailure(in: Self.state("a", phase: Self.failure)) == nil)
  }

  @Test func startDroppedForAnotherSurfaceIsSupersededNotFailed() async throws {
    let operations = CarPlaySelectionOperations()
    let gate = Gate()
    let outcomeBook = try Self.book("a")
    async let outcome = operations.select(.play(outcomeBook)) { await gate.perform() }
    await gate.release(.rejected(.cancelled))

    #expect(await outcome == .superseded)
  }

  @Test func rejectionIsReportedAsIs() async throws {
    let operations = CarPlaySelectionOperations()
    let gate = Gate()
    let outcomeBook = try Self.book("a")
    async let outcome = operations.select(.play(outcomeBook)) { await gate.perform() }
    await gate.release(.rejected(.staleGeneration))

    #expect(await outcome == .failed(.staleGeneration))
  }

  @Test func finishedSelectionCanBeSelectedAgain() async throws {
    let operations = CarPlaySelectionOperations()
    let gate = Gate()
    let book = try Self.book("a")
    async let first = operations.select(.play(book)) { await gate.perform() }
    await gate.release(.accepted)
    #expect(await first == .started)

    async let second = operations.select(.play(book)) { await gate.perform() }
    await gate.release(.accepted)
    #expect(await second == .started)
    #expect(gate.calls == 2)
  }

  @Test func failureAfterAnAcceptedStartIsReportedOnce() async throws {
    let operations = try await Self.started("a")

    #expect(operations.lateFailure(in: Self.state("a", phase: .preparing)) == nil)
    #expect(operations.lateFailure(in: Self.state("a", phase: Self.failure)) == .failed(isRecoverable: true))
    #expect(operations.lateFailure(in: Self.state("a", phase: Self.failure)) == nil)
  }

  @Test func stallAfterAnAcceptedStartIsReported() async throws {
    let operations = try await Self.started("a")
    #expect(operations.lateFailure(in: Self.state("a", phase: .stalled)) == .stalled)
  }

  @Test func failureAfterAudioPlayedIsNotTheStartsFailure() async throws {
    let operations = try await Self.started("a")

    #expect(operations.lateFailure(in: Self.state("a", phase: .playing)) == nil)
    #expect(operations.lateFailure(in: Self.state("a", phase: Self.failure)) == nil)
  }

  @Test func failureOfATitleTheCarDidNotStartIsNotReported() async throws {
    let operations = try await Self.started("a")

    #expect(operations.lateFailure(in: Self.state("other", phase: Self.failure)) == nil)
    // The car's start was replaced, so a later failure of its own title is not its to report.
    #expect(operations.lateFailure(in: Self.state("a", phase: Self.failure)) == nil)
  }

  @Test func failureWithNoAcceptedStartIsNotReported() {
    let operations = CarPlaySelectionOperations()
    #expect(operations.lateFailure(in: Self.state("a", phase: Self.failure)) == nil)
  }

  // MARK: - Fixtures

  /// A start the test finishes when it chooses.
  @MainActor private final class Gate {
    private(set) var calls = 0
    // A start runs to completion regardless of cancellation, so the gate ignores it.
    private let gate = TestGate<CarPlayPlaybackResult>(
      label: "CarPlay start", ignoresCancellation: true)

    init() { gate.hold() }

    func perform() async -> CarPlayPlaybackResult {
      calls += 1
      return await gate.pass(otherwise: { .accepted })
    }

    func started() async {
      await gate.waitUntilParked()
    }

    func release(_ result: CarPlayPlaybackResult) async {
      await started()
      gate.releaseParked(result)
    }
  }

  private static let failure = PlayerPhase.failed(AudioEngineFailure(isRecoverable: true, message: "failed"))

  private static func book(_ itemID: String) throws -> ListeningIdentity {
    try #require(ListeningIdentity.audiobook(itemID: itemID))
  }

  private static func started(_ itemID: String) async throws -> CarPlaySelectionOperations {
    let operations = CarPlaySelectionOperations()
    let gate = Gate()
    let outcomeBook = try Self.book(itemID)
    async let outcome = operations.select(.play(outcomeBook)) { await gate.perform() }
    await gate.release(.accepted)
    #expect(await outcome == .started)
    return operations
  }

  private static func state(_ itemID: String, phase: PlayerPhase) -> PlayerState {
    let timeline = try? PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 100)])
    return PlayerState(
      phase: phase, item: timeline.map { PlayerItem(id: itemID, timeline: $0) }, currentTrackIndex: 0,
      globalPosition: 0, rate: 1)
  }
}
