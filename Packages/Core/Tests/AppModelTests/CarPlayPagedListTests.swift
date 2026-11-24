import TestSupport
import Testing

@testable import AppModel

/// Paging in place, with a way back.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct CarPlayPagedListTests {
  @Test func firstPageHasNoWayBack() async {
    let source = Source([nil: .page(["a", "b"], next: Self.second)])
    let list = source.list()
    #expect(list.content == .loading)
    list.load()
    await source.settle(list)

    #expect(list.content == .page(rows: Self.rows(["a", "b"]), hasPrevious: false, hasNext: true))
  }

  @Test func nextAndPreviousMoveInPlace() async {
    let source = Source([
      nil: .page(["a"], next: Self.second), Self.second: .page(["b"], next: Self.third),
      Self.third: .page(["c"], next: nil),
    ])
    let list = source.list()
    list.load()
    await source.settle(list)
    list.showNext()
    await source.settle(list)
    #expect(list.content == .page(rows: Self.rows(["b"]), hasPrevious: true, hasNext: true))
    list.showNext()
    await source.settle(list)
    #expect(list.content == .page(rows: Self.rows(["c"]), hasPrevious: true, hasNext: false))

    // The last page has nowhere further to go.
    list.showNext()
    await source.settle(list)
    #expect(source.reads == [nil, Self.second, Self.third])

    list.showPrevious()
    await source.settle(list)
    #expect(list.content == .page(rows: Self.rows(["b"]), hasPrevious: true, hasNext: true))
    list.showPrevious()
    await source.settle(list)
    #expect(list.content == .page(rows: Self.rows(["a"]), hasPrevious: false, hasNext: true))
    list.showPrevious()
    await source.settle(list)
    #expect(source.reads == [nil, Self.second, Self.third, Self.second, nil])
  }

  @Test func repeatedTapOnNextReadsOnce() async {
    let source = Source([nil: .page(["a"], next: Self.second), Self.second: .page(["b"], next: nil)])
    let list = source.list()
    list.load()
    await source.settle(list)
    source.hold = true
    list.showNext()
    list.showNext()
    await source.release()
    await source.settle(list)

    #expect(source.reads == [nil, Self.second])
  }

  @Test func newerRequestDropsTheOlderResult() async {
    let source = Source([nil: .page(["a"], next: Self.second), Self.second: .page(["b"], next: nil)])
    let list = source.list()
    list.load()
    await source.settle(list)
    source.hold = true
    list.showNext()
    await source.started()
    source.hold = false
    list.load()
    await source.settle(list)
    await source.release()
    await source.settle(list)

    #expect(list.content == .page(rows: Self.rows(["a"]), hasPrevious: false, hasNext: true))
  }

  @Test func cancelledReadIsNeverShown() async {
    let source = Source([nil: .page(["a"], next: nil)])
    let list = source.list()
    source.hold = true
    list.load()
    await source.started()
    list.cancel()
    await source.release()
    await source.settle(list)

    #expect(list.content == .loading)
  }

  @Test func staleCursorStartsAgainFromTheFirstPage() async {
    let source = Source([nil: .page(["a"], next: Self.second), Self.second: .rejected(.staleCursor)])
    let list = source.list()
    list.load()
    await source.settle(list)
    list.showNext()
    await source.settle(list)

    #expect(source.reads == [nil, Self.second, nil])
    #expect(list.content == .page(rows: Self.rows(["a"]), hasPrevious: false, hasNext: true))
  }

  @Test func replacedGraphIsReportedStale() async {
    let source = Source([nil: .rejected(.staleGeneration)])
    let list = source.list()
    list.load()
    await source.settle(list)
    #expect(list.content == .stale)
  }

  @Test func failedFirstReadIsUnavailableAndCanBeRetried() async {
    let source = Source([nil: .rejected(.unavailable)])
    let list = source.list()
    list.load()
    await source.settle(list)
    #expect(list.content == .unavailable)

    source.results[nil] = .page(["a"], next: nil)
    list.load()
    await source.settle(list)
    #expect(list.content == .page(rows: Self.rows(["a"]), hasPrevious: false, hasNext: false))
  }

  @Test func failedMoveKeepsThePageOnScreen() async {
    let source = Source([nil: .page(["a"], next: Self.second), Self.second: .rejected(.unavailable)])
    let list = source.list()
    list.load()
    await source.settle(list)
    list.showNext()
    await source.settle(list)

    #expect(list.content == .page(rows: Self.rows(["a"]), hasPrevious: false, hasNext: true))
    // The move can be tried again.
    list.showNext()
    await source.settle(list)
    #expect(source.reads == [nil, Self.second, Self.second])
  }

  @Test func settledWaitsForTheFirstAnswerAndForNothingAfterIt() async {
    let source = Source([nil: .page(["a"], next: nil)])
    let list = source.list()
    source.hold = true
    list.load()
    await source.started()
    var woke = false
    let waiter = Task {
      await list.settled()
      woke = true
    }
    await awaitQuiescence("still reading") { "\(woke)" }
    #expect(woke == false)

    await source.release()
    await waiter.value
    #expect(list.content == .page(rows: Self.rows(["a"]), hasPrevious: false, hasNext: false))
    // A list with something to show has nothing to wait for.
    await list.settled()
  }

  @Test func settledEndsWhenTheReadIsCancelledOrFails() async {
    let cancelled = Source([nil: .page(["a"], next: nil)])
    let first = cancelled.list()
    cancelled.hold = true
    first.load()
    await cancelled.started()
    var waiting = false
    let waiter = Task {
      waiting = true
      await first.settled()
    }
    // The list is on this actor, so the flag is seen only once the waiter has suspended inside
    // `settled()`.
    await waitUntil("waiter inside settled") { waiting }
    first.cancel()
    await waiter.value
    await cancelled.release()

    let failing = Source([nil: .rejected(.unavailable)])
    let second = failing.list()
    second.load()
    await second.settled()
    #expect(second.content == .unavailable)
  }

  // MARK: - Fixtures

  // Distinct opaque cursors; only their identity matters here.
  private static let second = CarPlayBrowseCursor(route: .audiobooks, position: .followedStart)
  private static let third = CarPlayBrowseCursor(route: .downloads, position: .followedStart)

  private static func rows(_ ids: [String]) -> [CarPlayBrowseRow] {
    ids.map { CarPlayBrowseRow(id: $0, identity: nil, title: $0, subtitle: nil, artwork: .none) }
  }

  private enum Answer {
    case page([String], next: CarPlayBrowseCursor?)
    case rejected(CarPlayBrowsePageRejection)
  }

  @MainActor private final class Source {
    var results: [CarPlayBrowseCursor?: Answer]
    var hold = false
    private(set) var reads: [CarPlayBrowseCursor?] = []
    private var finished = 0
    // Always held: `hold` decides per read whether it parks. A parked read stays parked through
    // task cancellation, so a cancelled read still finishes only on `release()`.
    private let gate = TestGate<Void>(label: "Source held read", ignoresCancellation: true)

    init(_ results: [CarPlayBrowseCursor?: Answer]) {
      self.results = results
      gate.hold()
    }

    func list() -> CarPlayPagedList {
      CarPlayPagedList(route: .audiobooks) { [self] cursor in
        reads.append(cursor)
        if hold { await gate.pass() }
        defer { finished += 1 }
        switch results[cursor] {
        case .page(let ids, let next):
          return .page(.init(generation: 1, route: .audiobooks, rows: CarPlayPagedListTests.rows(ids), next: next))
        case .rejected(let rejection): return .rejected(rejection)
        case nil: return .rejected(.unavailable)
        }
      }
    }

    func started() async {
      await gate.waitUntilParked()
    }

    func release() async {
      await started()
      gate.releaseParked()
    }

    /// Every read that was started has finished and been applied.
    func settle(_ list: CarPlayPagedList) async {
      await awaitQuiescence("paged list settling") { "\(self.reads.count)|\(self.finished)|\(list.content)" }
    }
  }
}
