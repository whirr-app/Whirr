import AppModel
import Foundation
import Persistence
import WatchProtocol

/// Phone-owned, session-stable podcast browse projection for the Watch. Walks the persisted show
/// and episode readers (not the home publisher's three-row snapshot) and pages one complete
/// in-memory session, so a request generation stays stable across pages even as playback
/// progress changes.
@MainActor
final class WatchPhoneBrowseModel {
  let library: any LibraryReading
  let nativeShows: any NativePodcastShowsReading
  let podcasts: any PodcastReading
  let readTimeoutNanoseconds: UInt64
  private var accountStamp: WatchAccountStamp?
  var browseEpoch: UInt64 = 0
  var sessions: [UInt64: BrowseSession] = [:]
  var browseBindingEpoch: UInt64 = 0
  private var loadTask: Task<BrowseSession, Error>?
  private var loadTaskID: UUID?
  var nativeEnabled = false

  struct BrowseSession {
    let shows: [WatchBrowseShowRow]
    let episodes: [WatchBrowseEpisodeRow]
    let inProgress: Set<WatchSelection>
    let generation: UInt64
  }

  init(
    library: any LibraryReading,
    nativeShows: any NativePodcastShowsReading,
    podcasts: any PodcastReading,
    readTimeoutNanoseconds: UInt64 = 5_000_000_000
  ) {
    self.library = library
    self.nativeShows = nativeShows
    self.podcasts = podcasts
    self.readTimeoutNanoseconds = readTimeoutNanoseconds
  }

  func bind(accountStamp: WatchAccountStamp) {
    guard self.accountStamp != accountStamp else { return }
    self.accountStamp = accountStamp
    sessions.removeAll(keepingCapacity: false)
    loadTask?.cancel()
    loadTask = nil
    loadTaskID = nil
    browseBindingEpoch = browseBindingEpoch == UInt64.max ? 1 : browseBindingEpoch + 1
    browseEpoch = browseEpoch == UInt64.max ? 1 : browseEpoch + 1
  }

  func unbind() {
    accountStamp = nil
    sessions.removeAll(keepingCapacity: false)
    loadTask?.cancel()
    loadTask = nil
    loadTaskID = nil
    browseBindingEpoch = browseBindingEpoch == UInt64.max ? 1 : browseBindingEpoch + 1
  }

  /// A new first page gets a new frozen generation. Existing page requests continue to resolve
  /// against their retained session, so progress or a foreground refresh cannot reorder page 2.
  func refresh() {
    browseEpoch = browseEpoch == UInt64.max ? 1 : browseEpoch + 1
  }

  /// Mirrors the native-subscription gate of the home snapshot. A toggle starts a fresh frozen
  /// session and cancels any read whose source set no longer matches.
  func setNativeEnabled(_ enabled: Bool) {
    guard nativeEnabled != enabled else { return }
    nativeEnabled = enabled
    sessions.removeAll(keepingCapacity: false)
    loadTask?.cancel()
    loadTask = nil
    loadTaskID = nil
    browseEpoch = browseEpoch == UInt64.max ? 1 : browseEpoch + 1
  }

  func reply(for request: WatchBrowseRequest) async -> WatchBrowseReply {
    guard let stamp = accountStamp, request.accountStamp == stamp else {
      return Self.failure(
        request, code: .accountUnavailable, message: "The phone account is unavailable.", retryable: false)
    }
    let requestBinding = browseBindingEpoch
    let session: BrowseSession
    if let requestedGeneration = request.generation {
      guard let retained = sessions[requestedGeneration] else {
        return Self.failure(
          request, code: .staleGeneration, message: "This browse list changed. Open it again to refresh.",
          retryable: true)
      }
      session = retained
    } else {
      do {
        if let loadTask {
          session = try await loadTask.value
        } else {
          let loadID = UUID()
          let nativeEnabledAtStart = nativeEnabled
          let task = Task { @MainActor [weak self] () throws -> BrowseSession in
            guard let self else { throw BrowseLoadError.unavailable }
            return try await self.load(binding: requestBinding, nativeEnabled: nativeEnabledAtStart)
          }
          loadTask = task
          loadTaskID = loadID
          // The shared task is cleared only once it has finished, and only if it is still this
          // binding's task: a first page requested meanwhile joins it instead of starting another.
          defer {
            if self.browseBindingEpoch == requestBinding, self.loadTaskID == loadID {
              self.loadTask = nil
              self.loadTaskID = nil
            }
          }
          session = try await task.value
        }
      } catch {
        return loadFailure(request, binding: requestBinding, stamp: stamp)
      }
    }
    guard browseBindingEpoch == requestBinding, accountStamp == stamp else {
      return Self.failure(
        request, code: .accountUnavailable, message: "The phone account changed. Open Podcasts again.", retryable: false
      )
    }

    return pagedReply(for: request, in: session)
  }

  /// The session holds both sources; a request for one is narrowed before paging so its pages
  /// never sit behind the other source's rows.
  private func narrowedRows(
    for request: WatchBrowseRequest, in session: BrowseSession
  ) -> [WatchBrowseRow] {
    let inSource: (WatchBrowseShowIdentity) -> Bool = { show in request.source?.contains(show) ?? true }
    switch request.scope {
    case .shows:
      return session.shows.filter { inSource($0.id) }.map(WatchBrowseRow.show)
    case .latestEpisodes:
      return sortedEpisodes(
        session.episodes.filter { inSource($0.show) }, sort: request.episodeSort, played: request.played,
        inProgress: session.inProgress
      ).map(WatchBrowseRow.episode)
    case .episodes(let show):
      return sortedEpisodes(
        session.episodes.filter { $0.show == show }, sort: request.episodeSort, played: request.played,
        inProgress: session.inProgress
      ).map(WatchBrowseRow.episode)
    }
  }

  /// Packs the narrowed rows against the wire budget and answers for the requested page.
  private func pagedReply(for request: WatchBrowseRequest, in session: BrowseSession) -> WatchBrowseReply {
    let rows = narrowedRows(for: request, in: session)
    guard let chunks = packedChunks(rows, request: request, generation: session.generation) else {
      return Self.failure(
        request, code: .retryable, message: "The phone returned an invalid podcast page. Try again.", retryable: true,
        retryAfterSeconds: 2)
    }
    guard request.page < chunks.count else {
      return Self.failure(
        request, code: .invalidRequest, message: "That browse page is no longer available.", retryable: false)
    }
    let pageRows = chunks[request.page]
    let next = request.page + 1 < chunks.count ? request.page + 1 : nil
    return Self.pageReply(
      request, rows: pageRows, page: request.page, nextPage: next, generation: session.generation)
      ?? Self.failure(
        request, code: .retryable, message: "The phone returned an invalid podcast page. Try again.", retryable: true,
        retryAfterSeconds: 2)
  }

  /// A failed load is answered from the binding it began under: an account or subscription change
  /// is not retryable, and anything else is.
  private func loadFailure(
    _ request: WatchBrowseRequest, binding: UInt64, stamp: WatchAccountStamp
  ) -> WatchBrowseReply {
    guard browseBindingEpoch == binding, accountStamp == stamp else {
      return Self.failure(
        request, code: .accountUnavailable, message: "The phone account changed. Open Podcasts again.", retryable: false
      )
    }
    return Self.failure(
      request, code: .retryable, message: "The phone could not read podcast data. Try again.", retryable: true,
      retryAfterSeconds: 2)
  }

  /// Packs a frozen result deterministically. A page is bounded by both the caller's row count
  /// and the encoded reply size, so long but valid metadata cannot drop a later page or make the
  /// Watch reject a complete catalogue.
  private func packedChunks(
    _ rows: [WatchBrowseRow], request: WatchBrowseRequest, generation: UInt64
  ) -> [[WatchBrowseRow]]? {
    guard rows.isEmpty == false else { return [[]] }
    // The row array is the only variable-size part of the reply. Encoding one row against the
    // same empty envelope gives its contribution (the one-byte array delimiter difference stays
    // as conservative headroom below). Page and next-page integer widths grow with the chunk
    // index, so reserve more than their maximum six-digit overhead.
    guard
      let empty = Self.encodedPageReply(
        request, rows: [], page: 0, nextPage: 1, generation: generation)
    else { return nil }
    let envelopeHeadroom = 128
    let budget = WatchBrowseLimits.maxWireBytes - empty.1.count - envelopeHeadroom
    guard budget > 0 else { return nil }
    var contributions: [Int] = []
    contributions.reserveCapacity(rows.count)
    for row in rows {
      guard
        let one = Self.encodedPageReply(
          request, rows: [row], page: 0, nextPage: 1, generation: generation)
      else { return nil }
      contributions.append(one.1.count - empty.1.count)
    }

    var chunks: [[WatchBrowseRow]] = []
    var cursor = 0
    while cursor < rows.count {
      let page = chunks.count
      var count = 0
      var estimatedBytes = 0
      while cursor + count < rows.count, count < request.pageSize {
        let contribution = contributions[cursor + count]
        guard estimatedBytes + contribution + 1 <= budget else { break }
        estimatedBytes += contribution + 1
        count += 1
      }
      guard count > 0 else { return nil }

      // The estimate is conservative, but verify the actual page: its page and nextPage numbers
      // may encode at different widths. Trimming never skips a row.
      while count > 0 {
        let hasMore = cursor + count < rows.count
        let nextPage = hasMore ? page + 1 : nil
        if Self.encodedPageReply(
          request, rows: Array(rows[cursor..<(cursor + count)]), page: page,
          nextPage: nextPage, generation: generation) != nil
        {
          break
        }
        count -= 1
      }
      guard count > 0 else { return nil }
      let chunk = Array(rows[cursor..<(cursor + count)])
      chunks.append(chunk)
      cursor += count
    }
    return chunks
  }

  private static func pageReply(
    _ request: WatchBrowseRequest, rows: [WatchBrowseRow], page: Int, nextPage: Int?, generation: UInt64
  ) -> WatchBrowseReply? {
    encodedPageReply(request, rows: rows, page: page, nextPage: nextPage, generation: generation)?.0
  }

  private static func encodedPageReply(
    _ request: WatchBrowseRequest, rows: [WatchBrowseRow], page: Int, nextPage: Int?, generation: UInt64
  ) -> (WatchBrowseReply, Data)? {
    guard
      let page = try? WatchBrowsePage(
        page: page, pageSize: request.pageSize, rows: rows, nextPage: nextPage,
        isComplete: nextPage == nil, generation: generation),
      let reply = try? WatchBrowseReply(request: request, status: .accepted, page: page),
      let data = try? WatchWireCodec.encode(reply)
    else { return nil }
    return (reply, data)
  }

  private func sortedEpisodes(
    _ rows: [WatchBrowseEpisodeRow], sort: WatchBrowseEpisodeSort, played: WatchBrowsePlayedFilter,
    inProgress: Set<WatchSelection>
  ) -> [WatchBrowseEpisodeRow] {
    rows.filter {
      switch played {
      case .inProgress: return inProgress.contains($0.selection)
      case .unplayed: return !$0.isPlayed
      case .all: return true
      }
    }.sorted { lhs, rhs in
      switch (lhs.publishedAt, rhs.publishedAt) {
      case (let left?, let right?):
        if left != right { return sort == .newest ? left > right : left < right }
      case (_?, nil): return true
      case (nil, _?): return false
      default: break
      }
      if lhs.showTitle.localizedCaseInsensitiveCompare(rhs.showTitle) != .orderedSame {
        return lhs.showTitle.localizedCaseInsensitiveCompare(rhs.showTitle) == .orderedAscending
      }
      return String(describing: lhs.id) < String(describing: rhs.id)
    }
  }

  enum BrowseLoadError: Error { case unavailable }

  private static func failure(
    _ request: WatchBrowseRequest, code: WatchBrowseErrorCode, message: String,
    retryable: Bool, retryAfterSeconds: Int? = nil
  ) -> WatchBrowseReply {
    let error = try! WatchBrowseError(
      code: code, message: message, retryable: retryable, retryAfterSeconds: retryAfterSeconds)
    return try! WatchBrowseReply(
      request: request, status: code == .retryable ? .retryableError : .unavailable, error: error)
  }
}
