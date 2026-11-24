/// Pure decision logic for paginated library reconciliation. ABS has no transactional snapshot
/// cursor, so a refresh is a sequence of page requests reconciled against reported totals and
/// previously-seen item ids. Plain-value inputs only (no GRDB or ABSApi types, I/O or clock): the
/// caller requests the page the planner names, upserts its rows, and feeds the response back.
public struct LibraryTraversalPlanner: Sendable {

  /// One page as reported by the server: its own page number, the item ids it carries (server
  /// order), and the total item count the server reported alongside this specific page.
  public struct PageResponse: Sendable, Equatable {
    public let pageNumber: Int
    public let itemIds: [String]
    public let reportedTotal: Int

    public init(pageNumber: Int, itemIds: [String], reportedTotal: Int) {
      self.pageNumber = pageNumber
      self.itemIds = itemIds
      self.reportedTotal = reportedTotal
    }
  }

  /// What the caller should do next.
  public enum Action: Sendable, Equatable {
    case requestPage(Int)
    case finish(Outcome)
  }

  /// How the traversal ended. Names mirror `SyncRunState` (Persistence), which it maps to
  /// directly.
  public enum Outcome: Sendable, Equatable {
    /// The total was covered or the server returned a short/empty page (both end-of-data
    /// signals), with no total-change or id-overlap anomaly. `seenItemIds` is every id observed,
    /// deduplicated; only a `.complete` run may drive deletion inference.
    case complete(seenItemIds: Set<String>)
    /// Upserts happened (`seenItemIds` reflects them) but the run ended with an instability
    /// signal: total changed mid-run, ids reappeared across page boundaries, or the page budget
    /// ran out. No deletion inference; the caller schedules a backoff refresh, not an immediate
    /// loop.
    case incomplete(reason: IncompleteReason, seenItemIds: Set<String>)
    /// The page stream is untrustworthy: the server repeated a page's content verbatim (a
    /// non-advancing cursor). No id set is returned, so an aborted run cannot drive deletion
    /// inference.
    case abort(reason: AbortReason)
  }

  public enum IncompleteReason: Sendable, Equatable {
    /// The server reported a different total on a later page than it did on the first. A
    /// single total-change does not itself abort the page loop (small drift while a library
    /// is being concurrently modified is expected); it disqualifies the run from `.complete`.
    case totalChanged
    /// An id from an earlier page reappeared, but the page was not a verbatim repeat of its
    /// predecessor (that is `AbortReason.unstablePagination`). Tolerated with dedup, but it
    /// disqualifies the run from `.complete`.
    case idsRepeatedAcrossPageBoundaries
    /// Reported-total-derived page budget was exhausted before any natural termination
    /// signal fired: a guard against a lying or never-converging server, so never an infinite loop.
    /// Only reported when the budget itself is what stopped the run.
    case hardCapReached
  }

  public enum AbortReason: Sendable, Equatable {
    case unstablePagination
  }

  private let pageSize: Int
  private var nextPageNumber = 0
  private var initialTotal: Int?
  private var hardCapPages: Int?
  private var pagesRequestedCount = 0
  private var seenItemIds: Set<String> = []
  private var previousPageItemIds: [String]?
  private var totalEverChanged = false
  private var overlapEverObserved = false
  private var finished = false

  public init(pageSize: Int) {
    precondition(pageSize > 0, "pageSize must be positive")
    self.pageSize = pageSize
  }

  /// Begin the traversal. Always page 0.
  public mutating func start() -> Action {
    requestNextPage()
  }

  /// Feed the response for the most recently requested page and get the next action.
  public mutating func handle(_ page: PageResponse) -> Action {
    precondition(!finished, "traversal already finished; do not call handle again")
    pagesRequestedCount += 1

    if let initialTotal {
      if page.reportedTotal != initialTotal {
        totalEverChanged = true
      }
    } else {
      initialTotal = page.reportedTotal
      hardCapPages = hardCap(for: page.reportedTotal)
    }

    // A verbatim repeat of the immediately preceding page means the cursor never advanced.
    // The stream cannot be trusted, so abort rather than tolerate it.
    if let previousPageItemIds, previousPageItemIds == page.itemIds, !page.itemIds.isEmpty {
      return finish(.abort(reason: .unstablePagination))
    }

    let incomingIds = Set(page.itemIds)
    if !incomingIds.isDisjoint(with: seenItemIds) {
      overlapEverObserved = true
    }
    seenItemIds.formUnion(incomingIds)
    previousPageItemIds = page.itemIds

    let isShortPage = page.itemIds.count < pageSize
    let totalCovered = seenItemIds.count >= (initialTotal ?? 0)

    if isShortPage || totalCovered {
      if totalEverChanged {
        return finish(.incomplete(reason: .totalChanged, seenItemIds: seenItemIds))
      }
      if overlapEverObserved {
        return finish(.incomplete(reason: .idsRepeatedAcrossPageBoundaries, seenItemIds: seenItemIds))
      }
      return finish(.complete(seenItemIds: seenItemIds))
    }

    if let hardCapPages, pagesRequestedCount >= hardCapPages {
      return finish(.incomplete(reason: .hardCapReached, seenItemIds: seenItemIds))
    }

    return requestNextPage()
  }

  private mutating func finish(_ outcome: Outcome) -> Action {
    finished = true
    return .finish(outcome)
  }

  private mutating func requestNextPage() -> Action {
    let pageNumber = nextPageNumber
    nextPageNumber += 1
    return .requestPage(pageNumber)
  }

  private func hardCap(for total: Int) -> Int {
    guard total > 0 else { return 1 }
    let pagesNeededForTotal = (total + pageSize - 1) / pageSize
    return pagesNeededForTotal + 1
  }
}
