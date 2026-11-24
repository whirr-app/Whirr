import AppModel
import Foundation
import Persistence
import ReaderCore
import SyncEngine

/// Production App-side bridge for the reader's progress. The restore read resolves item identity
/// and progress in one database snapshot; both writes go through `ItemProgressCoordinator`, which
/// commits the position with its outbox row and then requests a drain.
struct DefaultReaderProgressAccess: ReaderProgressAccessing, Sendable {
  private let progressDAO: MediaProgressDAO
  private let coordinator: ItemProgressCoordinator
  private let accountID: Int64

  init(database: AppDatabase, accountID: Int64, coordinator: ItemProgressCoordinator) {
    progressDAO = MediaProgressDAO(database: database)
    self.coordinator = coordinator
    self.accountID = accountID
  }

  func fetchRestoreTarget(itemID: String) async throws -> ReaderRestoreTarget? {
    guard
      let progress = try await progressDAO.fetchCurrentForServerItemAsync(
        accountId: accountID, serverItemId: itemID)
    else { return nil }

    if let positionJSON = progress.readingPositionJSON,
      let position = try? JSONDecoder().decode(ReadingPosition.self, from: Data(positionJSON.utf8))
    {
      return .position(position)
    }
    guard let ebookProgress = progress.ebookProgress else { return nil }
    return .totalProgression(ebookProgress)
  }

  func write(position: ReadingPosition, itemID: String) async throws {
    let json = String(
      decoding: try JSONEncoder().encode(position), as: UTF8.self)
    try await coordinator.writeEbookPosition(
      itemID: itemID,
      readingPositionJSON: json,
      ebookProgress: position.ebookProgress,
      ebookLocation: position.ebookLocation)
  }

  func markEbookAsFinished(itemID: String) async throws {
    try await coordinator.markEbookAsFinished(itemID: itemID)
  }

  func requestSync() async {
    await coordinator.requestSync()
  }
}

struct NoOpReaderPreferencesStore: ReaderPreferencesStoring, Sendable {
  func fetchPreferencesJSON() async throws -> String? { nil }
  func writePreferencesJSON(_ preferencesJSON: String) async throws {}
}
