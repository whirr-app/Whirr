import Observation

/// One paged car list: the page on screen and the way to the pages either side of it.
///
/// Paging replaces the list's rows in place rather than pushing a template per page, so this
/// keeps the start of every page behind the current one; the readers' cursors only run forward.
/// One read is in flight at a time, a repeated request joins it, and a newer request drops the
/// older one's result.
@MainActor
@Observable
public final class CarPlayPagedList {
  public enum Content: Sendable, Equatable {
    case loading
    case page(rows: [CarPlayBrowseRow], hasPrevious: Bool, hasNext: Bool)
    /// The first page could not be read. `load()` tries again.
    case unavailable
    /// The account graph was replaced; the owner rebuilds its lists from the new one.
    case stale
  }

  public typealias Read = @MainActor (CarPlayBrowseCursor?) async -> CarPlayBrowsePageResult

  public let route: CarPlayBrowseRoute
  public private(set) var content = Content.loading

  @ObservationIgnored private let read: Read
  /// Where each page up to the current one starts; the first is nil.
  @ObservationIgnored private var starts: [CarPlayBrowseCursor?] = []
  @ObservationIgnored private var next: CarPlayBrowseCursor?
  @ObservationIgnored private var pending: [CarPlayBrowseCursor?]?
  @ObservationIgnored private var requestID = 0
  @ObservationIgnored private var settleWaiters: [CheckedContinuation<Void, Never>] = []

  public init(route: CarPlayBrowseRoute, read: @escaping Read) {
    self.route = route
    self.read = read
  }

  /// Reads the first page, discarding the way back.
  public func load() { go([nil]) }

  public func showNext() {
    guard case .page(_, _, true) = content, let next else { return }
    go(starts + [next])
  }

  public func showPrevious() {
    guard starts.count > 1 else { return }
    go(Array(starts.dropLast()))
  }

  /// Drops any read in flight; its result is never shown.
  public func cancel() {
    requestID += 1
    pending = nil
    resumeSettleWaiters()
  }

  /// Returns once the first read has an answer, or the list is cancelled. A caller that holds a
  /// list back until then never shows it empty.
  public func settled() async {
    guard content == .loading, pending != nil else { return }
    await withCheckedContinuation { settleWaiters.append($0) }
  }

  private func resumeSettleWaiters() {
    let waiters = settleWaiters
    settleWaiters = []
    for waiter in waiters { waiter.resume() }
  }

  private func go(_ history: [CarPlayBrowseCursor?]) {
    guard pending != history else { return }
    requestID += 1
    let id = requestID
    pending = history
    Task { [weak self, read] in
      let result = await read(history.last ?? nil)
      self?.finish(id, history, result)
    }
  }

  private func finish(_ id: Int, _ history: [CarPlayBrowseCursor?], _ result: CarPlayBrowsePageResult) {
    guard id == requestID else { return }
    pending = nil
    switch result {
    case .page(let page):
      starts = history
      next = page.next
      set(.page(rows: page.rows, hasPrevious: history.count > 1, hasNext: page.next != nil))
    case .rejected(.staleGeneration):
      set(.stale)
    case .rejected(.staleCursor) where history.count > 1:
      // The list's order changed under the cursor: its pages no longer line up, so start over
      // rather than show a page that skips or repeats rows.
      go([nil])
    case .rejected:
      // A failed move leaves the page that is on screen; only a first read has nothing to show.
      if case .page = content { return }
      set(.unavailable)
    }
  }

  private func set(_ next: Content) {
    if content != next { content = next }
    if next != .loading { resumeSettleWaiters() }
  }
}
