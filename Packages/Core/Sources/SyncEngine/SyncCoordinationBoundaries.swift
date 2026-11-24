import Persistence

/// The outcome of a request to reconcile the server library list. `pending` says
/// less than success: a run already owns the single-flight slot, so the request was coalesced but
/// its eventual network outcome is not known to this caller yet.
public enum LibraryDiscoveryRefreshResult: Sendable, Equatable {
  case reconciled
  case unavailable
  case pending
}

/// The sole post-login orchestrator of API work (ARCHITECTURE.md §2).
public protocol SyncCoordinating: Sendable {
  func refresh() async

  /// Reconciles the server's accessible-library list for library selection. Unlike the broad
  /// pull-to-refresh intent, this reports whether discovery itself completed, so Settings can
  /// retain cached rows without claiming an unavailable server was refreshed.
  func refreshLibraryDiscovery() async -> LibraryDiscoveryRefreshResult

  /// Called only after a library-selection write has committed an inclusion. Narrower than the
  /// selection store: excluding needs no new traversal, because the engine re-reads inclusion
  /// before every subsequent request, while including needs a fresh pull.
  func librarySelectionDidIncludeLibrary() async

  /// The cross-library search fan-out. `libraryIDs == nil` means every included library on the
  /// signed-in account (via `LibraryDAO.fetchIncludedAsync`); a list searches its included subset.
  /// An unknown or excluded id is skipped with no request, so never appears in `failures`.
  ///
  /// One request per targeted library, admitted through the `ABSClient`-owned `ServerRequestGate`
  /// (API-CONVENTIONS.md rule 13), so no second limiter here. A library's failure goes in
  /// `SearchFanOutResult.failures`, not thrown, and the others still return. `limit` is forwarded
  /// unchanged. Every bucket (book/podcast/author/series) becomes a kind-tagged `SearchMatch`;
  /// author/series hits are never upserted into `item`.
  ///
  /// Book and podcast hits are upserted non-destructively, as in a normal pull. The result is an
  /// ordered id list plus match annotations, never a wire DTO; the caller (`SearchModel`)
  /// resolves rows from `LibraryReading`'s observed projections.
  func search(libraryIDs: [String]?, query: String, limit: Int) async throws -> SearchFanOutResult
}

/// Keeps existing lightweight coordinators source-compatible until they own a library-selection
/// writer. Production `SyncEngine` overrides this to schedule a pull.
extension SyncCoordinating {
  /// Existing lightweight coordinators own only the broad refresh intent. Their result is
  /// `pending`, not a fabricated success or failure.
  public func refreshLibraryDiscovery() async -> LibraryDiscoveryRefreshResult {
    await refresh()
    return .pending
  }

  public func librarySelectionDidIncludeLibrary() async {}
}

/// One library's fan-out failure: the id plus a human-readable description of what went
/// wrong, never the underlying `Error`, which isn't generally `Equatable`/`Sendable` across
/// every case. Nothing above `SyncEngine` needs more than "this library failed and here is why"
/// to render the offline/partial annotation.
public struct SearchLibraryFailure: Sendable, Equatable {
  public let libraryId: String
  public let message: String

  public init(libraryId: String, message: String) {
    self.libraryId = libraryId
    self.message = message
  }
}

/// The fan-out result: every successful library's matches, grouped (each library's block
/// stays contiguous, in the order libraries were queried) and in per-library server order, plus
/// one `SearchLibraryFailure` per library whose request failed.
public struct SearchFanOutResult: Sendable, Equatable {
  public let matches: [SearchMatch]
  public let failures: [SearchLibraryFailure]

  public init(matches: [SearchMatch], failures: [SearchLibraryFailure] = []) {
    self.matches = matches
    self.failures = failures
  }
}

/// Explicit item-level progress changes made outside a playback session. Implementations must
/// persist the local projection and durable outbox operation before returning.
/// `episodeID` scopes both intents to one podcast episode; `nil` is the item's own progress. A
/// finished episode never finishes its show, so the two identities stay distinct all the way down
/// to `ItemProgressIntentStore`'s row and the outbox route the drainer picks from it.
public protocol ItemProgressIntents: Sendable {
  func resetProgress(itemID: String, episodeID: String?) async throws
  func resetEbookProgress(itemID: String) async throws
  func markAsFinished(itemID: String, episodeID: String?, duration: Double?) async throws
  func setContinueListeningVisibility(
    itemID: String, episodeID: String?, isHidden: Bool
  ) async throws
  /// Every episode in one transaction and one drain. The single-episode path costs a transaction
  /// and a drain request each, which a "mark all" over a long show turns into hundreds of both.
  func setEpisodesFinished(
    itemID: String, episodes: [EpisodeProgressChange], isFinished: Bool
  ) async throws
}

public struct NoOpItemProgressIntents: ItemProgressIntents, Sendable {
  public init() {}
  public func resetProgress(itemID: String, episodeID: String?) async throws {}
  public func resetEbookProgress(itemID: String) async throws {}
  public func markAsFinished(itemID: String, episodeID: String?, duration: Double?) async throws {}
  public func setContinueListeningVisibility(
    itemID: String, episodeID: String?, isHidden: Bool
  ) async throws {}
  public func setEpisodesFinished(
    itemID: String, episodes: [EpisodeProgressChange], isFinished: Bool
  ) async throws {}
}

/// One server search hit's stable identity plus why it matched. `itemId` is the server entity id:
/// a library item id for `.book`/`.podcast` (what `LibraryReading.observeItems(ids:)` resolves and
/// `NavigationModel.Route.itemDetail` carries), or an author/series id for `.author`/`.series`,
/// which are never upserted into `item`. Never a wire DTO: `ABSApi.SearchHit`/`SearchAuthorHit`/
/// `SearchSeriesHit`/`ItemDetail` die inside `SyncEngine.search`. `libraryId` (default `""`) is
/// the hit's server library, keeping a fan-out result grouped by library. `matchReason` is
/// `matchKey`/`matchText` folded into `Persistence.SearchMatchReason`, the vocabulary the search
/// merge and `SearchCopy` render from. `matchKey`/`matchText` stay because `FakeSyncCoordinating`
/// and `SearchModelTests` read them directly.
public struct SearchMatch: Sendable, Equatable {
  public let kind: SearchResultKind
  public let libraryId: String
  public let itemId: String
  public let matchKey: String?
  public let matchText: String?
  public let matchReason: SearchMatchReason?

  public init(
    kind: SearchResultKind = .book,
    libraryId: String = "",
    itemId: String,
    matchKey: String?,
    matchText: String?
  ) {
    self.kind = kind
    self.libraryId = libraryId
    self.itemId = itemId
    self.matchKey = matchKey
    self.matchText = matchText
    self.matchReason = matchKey.map { SearchMatchReason(field: $0, text: matchText) }
  }
}
