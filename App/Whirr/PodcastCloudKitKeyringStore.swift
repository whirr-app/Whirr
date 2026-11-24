import CloudKit
import Foundation
import SyncEngine

/// The account's record-name keyring, read and minted with direct `CKDatabase` operations beside
/// the engine adapter. It cannot use `CKSyncEngine`'s batch flow: the keyring must resolve before
/// the barrier opens (every child record name depends on it), and it is minted by a conditional
/// save whose only acceptable conflict outcome is adopting the winner's key. That race is
/// `PodcastCloudKeyringBootstrap`'s policy in Core; this is translation.
final class PodcastCloudKitKeyringStore: PodcastCloudKeyringStore, @unchecked Sendable {
  enum Failure: Error, Equatable {
    /// `modifyRecords` returned no result for the record it was asked to save.
    case missingResult
  }

  private let database: CKDatabase
  private let zoneID: CKRecordZone.ID

  init(database: CKDatabase, zoneID: CKRecordZone.ID) {
    self.database = database
    self.zoneID = zoneID
  }

  private var recordID: CKRecord.ID {
    CKRecord.ID(recordName: PodcastCloudIdentity.keyringRecordName, zoneID: zoneID)
  }

  func fetchKeyring() async throws -> PodcastCloudKeyringFetch {
    do {
      return .present(recordNameKey: try Self.recordNameKey(from: try await database.record(for: recordID)))
    } catch let error as CKError where error.code == .unknownItem {
      return .absent
    }
  }

  /// A new record carries no change tag, so `.ifServerRecordUnchanged` makes the save succeed only
  /// if no keyring exists yet; losing the race returns the winner's record as `serverRecord`.
  func saveNewKeyring(_ key: PodcastCloudRecordNameKey) async throws -> PodcastCloudKeyringSave {
    let record = PodcastCloudKitTranslation.record(
      from: try PodcastCloudRecordCodec.encodeKeyring(recordNameKey: key.bytes), in: zoneID)
    let (saveResults, _) = try await database.modifyRecords(
      saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
    guard let result = saveResults[record.recordID] else { throw Failure.missingResult }
    switch result {
    case .success:
      return .saved
    case .failure(let error):
      guard let cloudError = error as? CKError, cloudError.code == .serverRecordChanged,
        let winner = cloudError.serverRecord
      else { throw error }
      return .serverRecordChanged(recordNameKey: try Self.recordNameKey(from: winner))
    }
  }

  /// Reads the key through the layout, so a keyring whose key arrived in the clear is rejected by
  /// the reader rather than adopted.
  static func recordNameKey(from record: CKRecord) throws -> Data {
    try PodcastCloudRecordCodec.decodeKeyring(PodcastCloudKitTranslation.fields(from: record))
  }
}
