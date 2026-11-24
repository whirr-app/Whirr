import ABSApi
import Foundation
import Persistence

extension SyncEngine {
  /// Reasons `search` can fail before reaching `ABSClient.searchLibrary`, which has its own
  /// `SearchError`/`APIError` cases for the request itself.
  public enum SearchCoordinationError: Error, Sendable, Equatable {
    case notAuthenticated
  }

  /// `SyncCoordinating.search(libraryIDs:query:limit:)`: fans one query out across every targeted
  /// library, one `ABSClient.searchLibrary` request each, admitted by the `ServerRequestGate`
  /// `client` shares (API-CONVENTIONS.md rule 13), so `withTaskGroup` adds no limiter. A failing
  /// library becomes a `SearchLibraryFailure`, not a thrown error. Book/podcast hits go through the
  /// non-destructive `upsertSearchHit`; author/series hits are never upserted.
  public func search(libraryIDs: [String]?, query: String, limit: Int) async throws -> SearchFanOutResult {
    guard let accountRecord = try? await accountDAO.fetchAsync(), let accountId = accountRecord.id else {
      throw SearchCoordinationError.notAuthenticated
    }
    let account = try tokenAccount(for: accountRecord)

    let includedLibraries = (try? await libraryDAO.fetchIncludedAsync(accountId: accountId)) ?? []
    let libraries: [LibraryRecord]
    if let libraryIDs {
      // An unknown or excluded id is silently skipped from the fan-out: neither issues a
      // server request or appears in failures. Keeps the caller's requested order.
      let byServerID = Dictionary(uniqueKeysWithValues: includedLibraries.map { ($0.serverLibraryId, $0) })
      libraries = libraryIDs.compactMap { byServerID[$0] }
    } else {
      libraries = includedLibraries
    }
    guard libraries.isEmpty == false else {
      return SearchFanOutResult(matches: [], failures: [])
    }

    let outcomes = await withTaskGroup(of: (Int, String, Result<[SearchMatch], Error>).self) {
      group -> [(Int, String, Result<[SearchMatch], Error>)] in
      for (index, library) in libraries.enumerated() {
        group.addTask {
          do {
            let matches = try await self.searchOneLibrary(
              account: account, library: library, accountId: accountId, query: query, limit: limit)
            return (index, library.serverLibraryId, .success(matches))
          } catch {
            return (index, library.serverLibraryId, .failure(error))
          }
        }
      }
      var collected: [(Int, String, Result<[SearchMatch], Error>)] = []
      collected.reserveCapacity(libraries.count)
      for await outcome in group { collected.append(outcome) }
      return collected
    }

    // Restores the caller-given library order (`withTaskGroup` completion order is not that)
    // so `matches` stays "grouped by library, in query order" per the protocol doc comment.
    var matches: [SearchMatch] = []
    var failures: [SearchLibraryFailure] = []
    for (_, serverLibraryId, result) in outcomes.sorted(by: { $0.0 < $1.0 }) {
      switch result {
      case .success(let libraryMatches):
        matches.append(contentsOf: libraryMatches)
      case .failure(let error):
        failures.append(SearchLibraryFailure(libraryId: serverLibraryId, message: String(describing: error)))
      }
    }
    return SearchFanOutResult(matches: matches, failures: failures)
  }

  /// One library's slice of `search(libraryIDs:query:limit:)`: the request, the non-destructive
  /// upsert for book/podcast hits only, and the kind-tagged `SearchMatch` mapping for every
  /// bucket. Book hits before podcast before author before series, matching
  /// `Persistence.SearchResultKind`'s own declared case order.
  private func searchOneLibrary(
    account: TokenAccount, library: LibraryRecord, accountId: Int64, query: String, limit: Int
  ) async throws -> [SearchMatch] {
    let results = try await client.searchLibrary(
      account: account, library: library.serverLibraryId, query: query, limit: limit)

    var matches: [SearchMatch] = []
    matches.reserveCapacity(
      results.bookHits.count + results.podcastHits.count + results.authorHits.count + results.seriesHits.count)

    if let libraryRowId = library.id {
      // The namespace reservation is an ingest rule, not only a record-construction rule: a
      // rejected row must not escape this boundary as an otherwise valid ABS search match.
      for hit in results.bookHits {
        guard PodcastSourceIdentity.hasReservedPrefix(hit.libraryItem.id) == false else {
          continue
        }
        await upsertSearchHit(
          hit, mediaKindHint: "book", accountId: accountId, libraryRowId: libraryRowId)
        matches.append(
          SearchMatch(
            kind: .book, libraryId: library.serverLibraryId, itemId: hit.libraryItem.id,
            matchKey: hit.matchKey, matchText: hit.matchText))
      }
      for hit in results.podcastHits {
        guard PodcastSourceIdentity.hasReservedPrefix(hit.libraryItem.id) == false else {
          continue
        }
        await upsertSearchHit(
          hit, mediaKindHint: "podcast", accountId: accountId, libraryRowId: libraryRowId)
        matches.append(
          SearchMatch(
            kind: .podcast, libraryId: library.serverLibraryId, itemId: hit.libraryItem.id,
            matchKey: hit.matchKey, matchText: hit.matchText))
      }
    }
    // Author/series hits are not library items, so they are never upserted into `item`. The
    // server's `authors`/`series` buckets carry no `matchKey`, so these report `matchText` only
    // (`matchReason` derives to `nil`).
    for hit in results.authorHits {
      matches.append(
        SearchMatch(
          kind: .author, libraryId: library.serverLibraryId, itemId: hit.id, matchKey: nil, matchText: hit.name))
    }
    for hit in results.seriesHits {
      matches.append(
        SearchMatch(
          kind: .series, libraryId: library.serverLibraryId, itemId: hit.id, matchKey: nil, matchText: hit.name))
    }
    return matches
  }

  /// Non-destructive upsert: an existing row keeps its seen stamp and `softDeleted`, and only
  /// display fields refresh, so a search neither protects a row from deletion inference nor exposes
  /// it early. Search writes no `itemSeen` row; deletion inference's LEFT JOIN treats absence as
  /// older than any completed traversal's generation, so the next `inferDeletions` pass sweeps an
  /// unseen row unless that traversal confirms it.
  private func upsertSearchHit(
    _ hit: SearchHit, mediaKindHint: String, accountId: Int64, libraryRowId: Int64
  ) async {
    if let existing = try? await itemDAO.fetchOneAsync(
      libraryId: libraryRowId, serverItemId: hit.libraryItem.id)
    {
      let mediaKind = hit.libraryItem.mediaType ?? mediaKindHint
      // Search hits carry no traversal-only count. Preserve the prior valid signal regardless of
      // the hit's media kind so this non-destructive upsert cannot erase a complete projection.
      let podcastEpisodeCount =
        existing.podcastServerEpisodeCount.flatMap { $0 >= 0 ? $0 : nil }
      if let updated = Self.makeItemRecord(
        id: existing.id,
        accountId: existing.accountId,
        libraryId: existing.libraryId,
        serverItemId: existing.serverItemId,
        mediaKind: mediaKind,
        title: Self.title(for: hit.libraryItem) ?? hit.libraryItem.id,
        author: Self.author(for: hit.libraryItem),
        durationSeconds: Self.durationSeconds(for: hit.libraryItem),
        itemDescription: existing.itemDescription,
        addedAt: existing.addedAt,
        numAudioFiles: existing.numAudioFiles,
        ebookFormat: existing.ebookFormat,
        ebookFileIno: existing.ebookFileIno,
        ebookFileExt: existing.ebookFileExt,
        seriesName: existing.seriesName,
        narratorName: existing.narratorName,
        expandedMetadataFetchedAt: existing.expandedMetadataFetchedAt,
        audioDownloadExpectedBytes: existing.audioDownloadExpectedBytes,
        ebookDownloadExpectedBytes: existing.ebookDownloadExpectedBytes,
        podcastAutoDownloadEpisodes: existing.podcastAutoDownloadEpisodes,
        podcastLastEpisodeCheck: existing.podcastLastEpisodeCheck,
        podcastAutoDownloadSchedule: existing.podcastAutoDownloadSchedule,
        podcastMaxEpisodesToKeep: existing.podcastMaxEpisodesToKeep,
        podcastMaxNewEpisodesToDownload: existing.podcastMaxNewEpisodesToDownload,
        serverUpdatedAt: existing.serverUpdatedAt,
        podcastServerEpisodeCount: podcastEpisodeCount,
        podcastFeedFingerprint: PodcastFeedIdentity.validatedFingerprint(
          existing.podcastFeedFingerprint),
        podcastLanguage: existing.podcastLanguage,
        hasServerArtwork: existing.hasServerArtwork,
        softDeleted: existing.softDeleted)
      {
        _ = try? await itemDAO.upsertAsync(updated)
      }
    } else {
      if let inserted = Self.makeItemRecord(
        accountId: accountId,
        libraryId: libraryRowId,
        serverItemId: hit.libraryItem.id,
        mediaKind: hit.libraryItem.mediaType ?? mediaKindHint,
        title: Self.title(for: hit.libraryItem) ?? hit.libraryItem.id,
        author: Self.author(for: hit.libraryItem),
        durationSeconds: Self.durationSeconds(for: hit.libraryItem),
        itemDescription: nil,
        addedAt: nil,
        numAudioFiles: nil,
        ebookFormat: nil,
        ebookFileIno: nil,
        ebookFileExt: nil,
        seriesName: nil,
        narratorName: nil,
        expandedMetadataFetchedAt: nil,
        podcastAutoDownloadEpisodes: nil,
        podcastLastEpisodeCheck: nil,
        serverUpdatedAt: nil,
        podcastServerEpisodeCount: nil,
        podcastLanguage: nil,
        hasServerArtwork: nil,
        softDeleted: false)
      {
        _ = try? await itemDAO.upsertAsync(inserted)
      }
    }
  }

  private static func title(for item: ItemDetail) -> String? {
    switch item.media {
    case .book(let book): return book.title
    case .podcast(let podcast): return podcast.title
    case nil: return nil
    }
  }

  private static func author(for item: ItemDetail) -> String? {
    switch item.media {
    case .book(let book): return book.authorName
    case .podcast(let podcast): return podcast.author
    case nil: return nil
    }
  }

  private static func durationSeconds(for item: ItemDetail) -> Double? {
    switch item.media {
    case .book(let book): return book.duration
    case .podcast, nil: return nil
    }
  }
}
