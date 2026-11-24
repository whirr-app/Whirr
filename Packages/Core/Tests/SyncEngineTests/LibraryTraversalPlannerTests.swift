import Testing

@testable import SyncEngine

/// Pure decision logic for paginated library reconciliation. No I/O, clock or database. The
/// planner sees only page metadata (ids and reported total) and decides which page to request
/// next and how the run finished.
@Suite struct LibraryTraversalPlannerTests {

  typealias Page = LibraryTraversalPlanner.PageResponse

  // MARK: - Sequential issuance

  @Test func requestsPagesSequentiallyStartingAtZero() {
    var planner = LibraryTraversalPlanner(pageSize: 2)
    #expect(planner.start() == .requestPage(0))
    let action1 = planner.handle(Page(pageNumber: 0, itemIds: ["a", "b"], reportedTotal: 4))
    #expect(action1 == .requestPage(1))
    let action2 = planner.handle(Page(pageNumber: 1, itemIds: ["c", "d"], reportedTotal: 4))
    if case .finish(.complete) = action2 {
      // expected: total covered
    } else {
      Issue.record("expected completion once total is covered, got \(action2)")
    }
  }

  // MARK: - Dedup across the run

  @Test func dedupsItemIdsAcrossPagesWithoutDoubleCounting() {
    var planner = LibraryTraversalPlanner(pageSize: 3)
    _ = planner.start()
    // Page 0 returns 3 ids; page 1 re-returns one of them plus one genuinely new id, then a
    // short page ends the run. The final seen set must count each id once.
    _ = planner.handle(Page(pageNumber: 0, itemIds: ["a", "b", "c"], reportedTotal: 4))
    let action = planner.handle(Page(pageNumber: 1, itemIds: ["c", "d"], reportedTotal: 4))
    guard case .finish(let outcome) = action else {
      Issue.record("expected a finish action, got \(action)")
      return
    }
    // Overlap across boundaries is the softer inconsistency signal: finish useful upserts, mark
    // incomplete, never abort.
    guard case .incomplete(let reason, let seenItemIds) = outcome else {
      Issue.record("expected incomplete outcome, got \(outcome)")
      return
    }
    #expect(reason == .idsRepeatedAcrossPageBoundaries)
    #expect(seenItemIds == ["a", "b", "c", "d"])
  }

  // MARK: - Termination signals

  @Test func terminatesWhenAuthoritativeTotalIsCovered() {
    var planner = LibraryTraversalPlanner(pageSize: 2)
    _ = planner.start()
    _ = planner.handle(Page(pageNumber: 0, itemIds: ["a", "b"], reportedTotal: 4))
    let action = planner.handle(Page(pageNumber: 1, itemIds: ["c", "d"], reportedTotal: 4))
    guard case .finish(.complete(let seenItemIds)) = action else {
      Issue.record("expected complete outcome, got \(action)")
      return
    }
    #expect(seenItemIds == ["a", "b", "c", "d"])
  }

  @Test func terminatesOnShortPageEvenIfTotalNotCovered() {
    var planner = LibraryTraversalPlanner(pageSize: 3)
    _ = planner.start()
    // Reported total says 10, but a short (< pageSize) page is an authoritative end-of-data
    // signal, independent of total coverage.
    let action = planner.handle(Page(pageNumber: 0, itemIds: ["a", "b"], reportedTotal: 10))
    guard case .finish(.complete(let seenItemIds)) = action else {
      Issue.record("expected complete outcome, got \(action)")
      return
    }
    #expect(seenItemIds == ["a", "b"])
  }

  @Test func terminatesOnEmptyFirstPage() {
    var planner = LibraryTraversalPlanner(pageSize: 50)
    _ = planner.start()
    let action = planner.handle(Page(pageNumber: 0, itemIds: [], reportedTotal: 0))
    #expect(action == .finish(.complete(seenItemIds: [])))
  }

  // MARK: - Hard cap

  @Test func hardCapDerivedFromReportedTotalPlusOnePage() {
    // pageSize 2, reported total 6: 3 pages to cover it + 1 buffer page = hard cap 4.
    // A lying server whose window drifts by one id per page: deduped growth never keeps pace
    // with pageSize, so total is never covered, no page is short, and no page repeats its
    // predecessor. Only the hard cap can stop this run.
    var planner = LibraryTraversalPlanner(pageSize: 2)
    #expect(planner.start() == .requestPage(0))
    let action0 = planner.handle(Page(pageNumber: 0, itemIds: ["a", "b"], reportedTotal: 6))
    #expect(action0 == .requestPage(1))
    let action1 = planner.handle(Page(pageNumber: 1, itemIds: ["b", "c"], reportedTotal: 6))
    #expect(action1 == .requestPage(2))
    let action2 = planner.handle(Page(pageNumber: 2, itemIds: ["c", "d"], reportedTotal: 6))
    #expect(action2 == .requestPage(3))
    let action3 = planner.handle(Page(pageNumber: 3, itemIds: ["d", "e"], reportedTotal: 6))
    guard case .finish(.incomplete(let reason, let seenItemIds)) = action3 else {
      Issue.record("expected incomplete outcome at the hard cap, got \(action3)")
      return
    }
    #expect(reason == .hardCapReached)
    #expect(seenItemIds == ["a", "b", "c", "d", "e"])
  }

  // MARK: - Instability

  @Test func repeatedPageContentAbortsAsUnstablePagination() {
    var planner = LibraryTraversalPlanner(pageSize: 2)
    _ = planner.start()
    _ = planner.handle(Page(pageNumber: 0, itemIds: ["a", "b"], reportedTotal: 6))
    // The "cursor" doesn't advance: page 1 is byte-for-byte identical to page 0.
    let action = planner.handle(Page(pageNumber: 1, itemIds: ["a", "b"], reportedTotal: 6))
    #expect(action == .finish(.abort(reason: .unstablePagination)))
  }

  @Test func totalChangingMidRunFinishesUsefulUpsertsAsIncomplete() {
    var planner = LibraryTraversalPlanner(pageSize: 2)
    _ = planner.start()
    _ = planner.handle(Page(pageNumber: 0, itemIds: ["a", "b"], reportedTotal: 6))
    // Total shifts on page 1. A single shift does not end the run (small drift while a library
    // is modified concurrently is expected). It disqualifies `.complete`, and the run keeps
    // going, still bounded by the hard cap, a short page or total coverage.
    let midRunAction = planner.handle(Page(pageNumber: 1, itemIds: ["c", "d"], reportedTotal: 8))
    #expect(midRunAction == .requestPage(2))
    // A short page ends the run naturally.
    let action = planner.handle(Page(pageNumber: 2, itemIds: ["e"], reportedTotal: 8))
    guard case .finish(.incomplete(let reason, let seenItemIds)) = action else {
      Issue.record("expected incomplete outcome, got \(action)")
      return
    }
    #expect(reason == .totalChanged)
    // Every page's ids are still a useful upsert, so nothing is discarded.
    #expect(seenItemIds == ["a", "b", "c", "d", "e"])
  }

  // MARK: - Property tests

  /// For arbitrary server behavior, the planner must reach a `.finish` decision within the
  /// hard cap of pages, and never issue `.requestPage(n)` for the same `n` twice in one
  /// traversal. Generation is seeded: no wall clock, no `Int.random` without an explicit
  /// generator.
  @Test(arguments: Array(0..<200))
  func terminatesWithinHardCapAndNeverRepeatsAPageRequest(seed: Int) {
    var rng = SplitMix64(seed: UInt64(seed))
    let pageSize = Int.random(in: 1...5, using: &rng)
    let total = Int.random(in: 0...20, using: &rng)
    // The planner's hard cap derives from the total the first page reports. An adversarial mode
    // below can bump the effective total by 1 on any page, including the first, so this upper
    // bound assumes that happened.
    let hardCapPagesUpperBound = (((total + 1) + pageSize - 1) / pageSize) + 1

    var planner = LibraryTraversalPlanner(pageSize: pageSize)
    var requestedPages: [Int] = []
    var nextIdCounter = 0
    var iterations = 0
    var action = planner.start()

    while true {
      iterations += 1
      #expect(
        iterations <= hardCapPagesUpperBound + 1,
        "planner failed to terminate within the hard cap")
      if iterations > hardCapPagesUpperBound + 1 { break }

      switch action {
      case .requestPage(let pageNumber):
        #expect(
          !requestedPages.contains(pageNumber),
          "page \(pageNumber) was requested twice in one traversal")
        requestedPages.append(pageNumber)

        // Adversarial page shapes: sometimes a full page of new ids, sometimes short/empty,
        // sometimes a wholesale repeat of the previous page, sometimes a shifted total.
        let mode = Int.random(in: 0...3, using: &rng)
        let effectiveTotal = mode == 3 ? total + 1 : total
        let itemIds: [String]
        switch mode {
        case 1:
          // short/empty page
          let count = Int.random(in: 0..<pageSize, using: &rng)
          itemIds = (0..<count).map { _ in
            defer { nextIdCounter += 1 }
            return "id-\(nextIdCounter)"
          }
        case 2 where !requestedPages.isEmpty:
          itemIds = Array(repeating: "repeat", count: pageSize)
        default:
          itemIds = (0..<pageSize).map { _ in
            defer { nextIdCounter += 1 }
            return "id-\(nextIdCounter)"
          }
        }
        action = planner.handle(
          Page(pageNumber: pageNumber, itemIds: itemIds, reportedTotal: effectiveTotal))
      case .finish:
        return
      }
    }
  }
}

/// Seedable RNG for property tests (SplitMix64). Keeps generation reproducible across runs
/// without a dependency.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state = state &+ 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
