import ABSApi
import Foundation
import Persistence

/// Keeps every Audiobookshelf show a smart list names fully expanded (smart lists plan,
/// "Audiobookshelf expansion").
///
/// Two stages over the shows `PodcastCatalogRefreshStore.candidates` selects, restricted to the
/// shows lists name and bounded by a per-pass show budget:
///
/// 1. Bulk fill: `POST /api/items/batch/get` for shows not yet completely expanded, in chunks
///    bounded by their stored episode counts. The response is handed to the show refresh as
///    prefetched detail, which maps it as *incomplete*: it adds and updates episodes but never
///    soft-deletes one and never sets `lastCompleteEpisodeListAt`.
/// 2. Completeness: one `PodcastRefreshCoordinator.refresh` per show, sequentially. That single
///    expanded fetch soft-deletes and, through `recordSuccess`, marks the show complete.
///
/// There is no timer here (API-CONVENTIONS rule 20): the caller owns the deadline and cancels.
/// Every step checks cancellation; whatever has committed stays committed.
public struct SmartListShowExpansion: Sendable {
  /// At most this many shows in one batch request.
  static let maximumShowsPerChunk = 10
  /// At most this many known episodes across one batch request. A body is about 4 KB per
  /// episode, and `BoundedDecoding.maximumBodyBytes` refuses 25 MiB.
  static let maximumEpisodesPerChunk = 2_000

  public struct Summary: Sendable, Equatable {
    public var batchFilledShows = 0
    public var completedShows = 0
    public var failedShows = 0
    public init() {}
  }

  struct ChunkShow: Sendable, Equatable {
    let localItemID: Int64
    let serverItemID: String
    let knownEpisodeCount: Int?
  }

  private let database: AppDatabase
  private let client: ABSClient
  private let showRefresh: PodcastRefreshCoordinator
  private let reading: SmartListExpansionReading
  private let refreshStore: PodcastCatalogRefreshStore
  private let showBudget: Int
  private let now: @Sendable () -> Date
  private let randomSource: @Sendable () -> Double

  public init(
    database: AppDatabase,
    client: ABSClient,
    showRefresh: PodcastRefreshCoordinator,
    showBudget: Int = 20,
    now: @escaping @Sendable () -> Date = Date.init,
    randomSource: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
  ) {
    self.database = database
    self.client = client
    self.showRefresh = showRefresh
    reading = SmartListExpansionReading(database: database)
    refreshStore = PodcastCatalogRefreshStore(database: database)
    self.showBudget = max(0, showBudget)
    self.now = now
    self.randomSource = randomSource
  }

  /// Routine pass: the due shows of every list, for the signed-in account.
  @discardableResult
  public func expandDueShows() async -> Summary {
    await expand(listID: nil)
  }

  /// Save-time expansion: only the shows `listID` names. A user action, run in the foreground.
  @discardableResult
  public func expand(listID: Int64) async -> Summary {
    await expand(listID: Optional(listID))
  }

  private func expand(listID: Int64?) async -> Summary {
    var summary = Summary()
    guard showBudget > 0, Task.isCancelled == false else { return summary }
    guard let account = try? await resolveAccount() else { return summary }
    guard
      let named = try? await reading.namedShows(accountID: account.accountID, listID: listID),
      named.isEmpty == false
    else { return summary }
    guard Task.isCancelled == false else { return summary }
    guard
      let due = try? await refreshStore.candidates(
        now: now(), backstop: 0, includeBackstop: false,
        itemIDs: Set(named.map(\.localItemID)), includeNeverCompletelyExpanded: true,
        limit: showBudget)
    else { return summary }
    let namedByID = Dictionary(uniqueKeysWithValues: named.map { ($0.localItemID, $0) })
    let shows = due.compactMap { candidate -> (PodcastRefreshCandidate, ChunkShow)? in
      guard let show = namedByID[candidate.localItemID] else { return nil }
      return (
        candidate,
        ChunkShow(
          localItemID: show.localItemID, serverItemID: show.serverItemID,
          knownEpisodeCount: show.knownEpisodeCount)
      )
    }
    guard shows.isEmpty == false else { return summary }

    var progress = ProgressSource(client: client, account: account.tokenAccount)

    // Stage 1: bulk fill. Only shows without a complete list: a batch response is partial, and
    // refreshing an already-complete show with one would move its success checkpoint past the
    // server's `updatedAt` without reconciling removals.
    let fillable = shows.filter { $0.0.lastCompleteEpisodeListAt == nil }.map(\.1)
    let batchOutcome = await batchFill(
      fillable, account: account.tokenAccount, progress: &progress, summary: &summary)
    guard batchOutcome == .continue, Task.isCancelled == false else { return summary }

    // Stage 2: one expanded fetch per show for completeness.
    let snapshot = await progress.snapshot()
    for (_, show) in shows {
      guard Task.isCancelled == false else { return summary }
      do {
        let outcome = try await showRefresh.refresh(
          itemID: show.serverItemID, prefetchedDetail: nil,
          progressSnapshot: snapshot.progress, progressSnapshotIsComplete: snapshot.isComplete)
        if outcome == .complete {
          summary.completedShows += 1
        } else {
          // The list could not prove absence (duplicate ids, dropped rows). Without a backoff the
          // show would take a budget slot on every pass.
          summary.failedShows += 1
          await recordFailure(show)
        }
      } catch is CancellationError {
        return summary
      } catch {
        if (error as? APIError) == .cancelled { return summary }
        guard Self.isShowLevelFailure(error) else { return summary }
        summary.failedShows += 1
        await recordFailure(show)
      }
    }
    return summary
  }

  // MARK: - Batch fill

  private enum BatchOutcome { case `continue`, stop }

  private func batchFill(
    _ shows: [ChunkShow], account: TokenAccount, progress: inout ProgressSource,
    summary: inout Summary
  ) async -> BatchOutcome {
    let chunks = Self.chunks(shows)
    guard chunks.isEmpty == false else { return .continue }
    let snapshot = await progress.snapshot()
    for chunk in chunks {
      guard Task.isCancelled == false else { return .stop }
      let outcome = await fill(chunk, account: account, snapshot: snapshot, summary: &summary)
      if outcome == .stop { return .stop }
    }
    return .continue
  }

  /// Fetches one chunk, halving it when the body is refused for size, down to one show, which is
  /// then skipped (its per-show fetch still runs).
  private func fill(
    _ chunk: [ChunkShow], account: TokenAccount, snapshot: UserProgressSnapshot,
    summary: inout Summary
  ) async -> BatchOutcome {
    let details: [ItemDetail]
    do {
      details = try await client.batchGetItems(
        account: account, ids: chunk.map(\.serverItemID))
    } catch is CancellationError {
      return .stop
    } catch let error as APIError {
      switch error {
      case .cancelled:
        return .stop
      case .payloadTooLarge:
        guard chunk.count > 1 else { return .continue }
        let middle = chunk.count / 2
        for half in [Array(chunk[..<middle]), Array(chunk[middle...])] {
          guard Task.isCancelled == false else { return .stop }
          if await fill(half, account: account, snapshot: snapshot, summary: &summary) == .stop {
            return .stop
          }
        }
        return .continue
      case .decoding, .notFound, .ambiguousLocalSessionResponse:
        // This chunk is unusable; the per-show fetches below still cover its shows.
        return .continue
      default:
        // Transport, auth, rate limit and server failures say nothing about these shows, and a
        // follow-up request would only add load (rule 19).
        return .stop
      }
    } catch {
      return .stop
    }

    let wanted = Dictionary(uniqueKeysWithValues: chunk.map { ($0.serverItemID, $0) })
    for detail in details {
      guard Task.isCancelled == false else { return .stop }
      guard let show = wanted[detail.id] else { continue }
      do {
        _ = try await showRefresh.refresh(
          itemID: show.serverItemID, prefetchedDetail: detail,
          progressSnapshot: snapshot.progress, progressSnapshotIsComplete: snapshot.isComplete)
        summary.batchFilledShows += 1
      } catch is CancellationError {
        return .stop
      } catch {
        if (error as? APIError) == .cancelled { return .stop }
        guard Self.isShowLevelFailure(error) else { return .stop }
        summary.failedShows += 1
        await recordFailure(show)
      }
    }
    return .continue
  }

  /// Chunks bounded by stored episode counts: at most 10 shows and 2,000 known episodes; a show
  /// of unknown count is a chunk of its own; a show whose known count alone exceeds the cap is
  /// left out (its per-show fetch carries it).
  static func chunks(
    _ shows: [ChunkShow], maximumShows: Int = maximumShowsPerChunk,
    maximumEpisodes: Int = maximumEpisodesPerChunk
  ) -> [[ChunkShow]] {
    var chunks: [[ChunkShow]] = []
    var current: [ChunkShow] = []
    var currentEpisodes = 0
    func flush() {
      if current.isEmpty == false { chunks.append(current) }
      current = []
      currentEpisodes = 0
    }
    for show in shows {
      guard let count = show.knownEpisodeCount else {
        flush()
        chunks.append([show])
        continue
      }
      let episodes = max(0, count)
      guard episodes <= maximumEpisodes else { continue }
      if current.count >= maximumShows || currentEpisodes + episodes > maximumEpisodes {
        flush()
      }
      current.append(show)
      currentEpisodes += episodes
    }
    flush()
    return chunks
  }

  // MARK: - Helpers

  /// Hydration's classification, plus a body over the size cap: a show too large to decode would
  /// otherwise stop every pass on the same show.
  static func isShowLevelFailure(_ error: any Error) -> Bool {
    if (error as? APIError) == .payloadTooLarge { return true }
    return PodcastProgressHydrationCoordinator.isShowLevelFailure(error)
  }

  private func recordFailure(_ show: ChunkShow) async {
    try? await refreshStore.recordShowFailure(
      itemID: show.localItemID, at: now(), randomUnit: randomSource())
  }

  private struct Account: Sendable {
    let accountID: Int64
    let tokenAccount: TokenAccount
  }

  private func resolveAccount() async throws -> Account? {
    guard let record = try await AccountDAO(database: database).fetchAsync(),
      let accountID = record.id
    else { return nil }
    return Account(accountID: accountID, tokenAccount: try record.credentialTokenAccount)
  }

  /// One `/api/me` per pass, shared by every show refresh. A failure degrades to an incomplete
  /// empty snapshot, which can never evidence a reset, as the refresh's own fallback does.
  private struct ProgressSource {
    let client: ABSClient
    let account: TokenAccount
    private var cached: UserProgressSnapshot?

    init(client: ABSClient, account: TokenAccount) {
      self.client = client
      self.account = account
    }

    mutating func snapshot() async -> UserProgressSnapshot {
      if let cached { return cached }
      let value =
        (try? await client.fetchUserProgressSnapshot(account: account))
        ?? UserProgressSnapshot(progress: [], hiddenSeriesIDs: [], isComplete: false)
      cached = value
      return value
    }
  }
}
