import SyncEngine

public final class FakeSyncCoordinating: SyncCoordinating, @unchecked Sendable {
  private let count = Locked(0)
  public var refreshCount: Int { count.value }
  public func refresh() async { count.value += 1 }

  /// - Parameter libraryDiscoveryResult: what `refreshLibraryDiscovery()` reports. `nil` keeps the
  ///   protocol's default: a plain `refresh()` that reports `.pending`.
  public init(libraryDiscoveryResult: LibraryDiscoveryRefreshResult? = nil) {
    libraryDiscoveryResultBox = Locked(libraryDiscoveryResult)
  }

  private let libraryDiscoveryResultBox: Locked<LibraryDiscoveryRefreshResult?>
  private let discoveryCount = Locked(0)
  private let inclusionCount = Locked(0)

  /// How many times `refreshLibraryDiscovery()` was called.
  public var discoveryRefreshCount: Int { discoveryCount.value }
  /// How many times `librarySelectionDidIncludeLibrary()` was called.
  public var inclusionIntentCount: Int { inclusionCount.value }

  public func refreshLibraryDiscovery() async -> LibraryDiscoveryRefreshResult {
    discoveryCount.withValue { $0 += 1 }
    if let result = libraryDiscoveryResultBox.value { return result }
    await refresh()
    return .pending
  }

  public func librarySelectionDidIncludeLibrary() async {
    inclusionCount.withValue { $0 += 1 }
  }

  private let searchResultBox = Locked<Result<[SearchMatch], Error>>(.success([]))
  private let recordedSearchesBox = Locked<[(libraryId: String, query: String)]>([])
  public var recordedSearches: [(libraryId: String, query: String)] { recordedSearchesBox.value }

  public func stubSearch(_ result: Result<[SearchMatch], Error>) {
    searchResultBox.value = result
  }

  /// Holds `search` after `hold()` until the test calls `release(_:)` with the fan-out's result,
  /// so a test can show what a model does while the server has not yet answered. Open, `search`
  /// answers what `stubSearch` set. The call is recorded before it parks.
  public let searchGate = TestGate<Result<SearchFanOutResult, Error>>(
    label: "FakeSyncCoordinating.search")

  private let recordedSearchLibraryIDsBox = Locked<[[String]?]>([])
  /// Every fan-out's full `libraryIDs` argument, in call order. `nil` means every library on the
  /// account, which is what a Search tab spanning the whole account must ask for. `recordedSearches`
  /// flattens this to a single id and so cannot tell `nil` from `["lib1"]`.
  public var recordedSearchLibraryIDs: [[String]?] { recordedSearchLibraryIDsBox.value }

  /// Recorded against the first requested library id, for callers that only ever pass one. Use
  /// `recordedSearchLibraryIDs` for the whole argument.
  public func search(libraryIDs: [String]?, query: String, limit: Int) async throws -> SearchFanOutResult {
    recordedSearchesBox.withValue { $0.append((libraryIDs?.first ?? "", query)) }
    recordedSearchLibraryIDsBox.withValue { $0.append(libraryIDs) }
    let stubbed = searchResultBox
    let result = await searchGate.pass(otherwise: {
      stubbed.value.map { SearchFanOutResult(matches: $0, failures: []) }
    })
    return try result.get()
  }
}
