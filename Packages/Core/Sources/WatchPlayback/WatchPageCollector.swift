enum WatchPageCollectorLimits {
  static let maximumItems = 10_000
  static let maximumPages = 100
  static let maximumCacheEntries = 8
  static let maximumCacheRows = 20_000
}

/// Traversal policy differs only where ABS supplies a total: an early short page is incomplete
/// there, whereas the recent-episode endpoint uses a short or repeated page as its terminator.
enum WatchPageCollector {
  static func collect<Row: Sendable>(
    client: isolated WatchLibraryClient, generation: Int, pageSize: Int, pageLimit: Int,
    requiresTotal: Bool, identity: @Sendable (Row) -> String,
    fetch: @Sendable (Int) async throws -> ([Row], Int?)
  ) async throws -> [Row] {
    var result: [Row] = []
    var seen = Set<String>()
    var expectedTotal = 0
    for page in 0..<pageLimit {
      try Task.checkCancellation()
      let (rows, total) = try await fetch(page)
      guard generation == client.generation else { throw WatchLibraryError.staleRequest }
      expectedTotal = max(expectedTotal, total ?? 0)
      if expectedTotal > WatchPageCollectorLimits.maximumItems { throw WatchLibraryError.catalogueTooLarge }
      let before = result.count
      for row in rows where seen.insert(identity(row)).inserted { result.append(row) }
      if requiresTotal {
        if expectedTotal > 0 && result.count >= expectedTotal { return result }
        if expectedTotal == 0 && rows.isEmpty { return result }
        if rows.count < pageSize || result.count == before { throw WatchLibraryError.catalogueIncomplete }
      } else {
        if result.count >= WatchPageCollectorLimits.maximumItems { throw WatchLibraryError.catalogueTooLarge }
        if rows.count < pageSize || result.count == before { return result }
      }
    }
    throw WatchLibraryError.catalogueTooLarge
  }
}
