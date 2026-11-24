import Testing

@testable import Persistence

/// Up Next edits are keyed by row since a book can hold several chapter rows. Tests that queue one
/// row per title name it by identity; this resolves that title's single row.
extension ListeningQueueStore {
  func rowID(of identity: ListeningIdentity) async throws -> Int64 {
    let rows = await fetchQueue().filter { $0.identity == identity }
    #expect(rows.count == 1, "\(identity) should hold exactly one row")
    return try #require(rows.first?.id)
  }

  func move(identity: ListeningIdentity, to position: Int) async throws {
    try await move(rowID: rowID(of: identity), to: position)
  }
}
