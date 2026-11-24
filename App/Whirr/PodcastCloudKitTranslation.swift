import CloudKit
import CoreSupport
import Foundation
import SyncEngine
import os

/// The CloudKit half of the sync boundary: value translation, and nothing else.
///
/// Every function here is pure and free of engine state, so the App's share of the boundary is
/// testable: `CKSyncEngine.Event` has no public initializer, so the delegate cannot be driven from
/// a host test. The delegate is a thin shell over these.
nonisolated enum PodcastCloudKitTranslation {
  private static let log = CoreLogging.logger(category: "PodcastCloudSync")

  enum Failure: Error, Equatable {
    /// A record type this schema version does not declare. Ignoring the record would silently drop
    /// a newer device's data; rejecting it lets the coordinator record `Sync needs attention`.
    case undeclaredRecordType(String)
  }

  // MARK: - Records

  /// Builds a `CKRecord` from already-split fields. No layout lookup: `PodcastCloudRecordBuilder`
  /// alone decides each field's compartment, so this cannot put an encrypted field in the clear.
  /// With a system-fields archive the record is rebuilt from it, so the save carries its change tag
  /// and is conditional. An archive that does not decode, or names another record, is ignored: the
  /// save loses as `serverRecordChanged` and the merge uses the server record. Slower, never wrong.
  static func record(
    from fields: PodcastCloudRecordFields, in zoneID: CKRecordZone.ID, systemFields: Data? = nil
  ) -> CKRecord {
    let recordID = CKRecord.ID(recordName: fields.recordName, zoneID: zoneID)
    let record =
      systemFields.flatMap { archivedRecord(from: $0, matching: recordID, type: fields.recordType) }
      ?? CKRecord(recordType: fields.recordType, recordID: recordID)
    for (name, value) in fields.plaintext {
      record[name] = cloudValue(value)
    }
    for (name, value) in fields.encrypted {
      record.encryptedValues[name] = cloudValue(value)
    }
    return record
  }

  /// Reads a `CKRecord` back through the layout, not the record's own key list, so a field a newer
  /// schema adds is ignored, and a field the layout declares encrypted is read only from
  /// `encryptedValues` (one that arrived in the clear is absent, and
  /// `PodcastCloudRecordReader.required` rejects it). `PodcastCloudKitTranslationTests` pins the
  /// compartment separation, and that `CKRecord.allKeys()` reports both compartments, so a
  /// plaintext audit must subtract `encryptedValues.allKeys()` and use a service-returned record.
  static func fields(from record: CKRecord) throws -> PodcastCloudRecordFields {
    guard let type = PodcastCloudRecordLayout.recordType(named: record.recordType) else {
      throw Failure.undeclaredRecordType(record.recordType)
    }
    var plaintext: [String: PodcastCloudRecordValue] = [:]
    var encrypted: [String: PodcastCloudRecordValue] = [:]
    for field in type.fields {
      // Explicitly the existential overload: `CKRecordKeyValueSetting` also offers a generic
      // subscript, and letting inference choose would depend on the destination type.
      let raw: (any CKRecordValueProtocol)? =
        field.isEncrypted ? record.encryptedValues[field.name] : record[field.name]
      guard let value = recordValue(raw, kind: field.kind) else { continue }
      if field.isEncrypted {
        encrypted[field.name] = value
      } else {
        plaintext[field.name] = value
      }
    }
    return PodcastCloudRecordFields(
      recordType: record.recordType, recordName: record.recordID.recordName,
      plaintext: plaintext, encrypted: encrypted)
  }

  private static func archivedRecord(
    from archive: Data, matching recordID: CKRecord.ID, type: String
  ) -> CKRecord? {
    guard let coder = try? NSKeyedUnarchiver(forReadingFrom: archive) else { return nil }
    coder.requiresSecureCoding = true
    defer { coder.finishDecoding() }
    guard let record = CKRecord(coder: coder), record.recordID == recordID, record.recordType == type
    else { return nil }
    return record
  }

  /// The field names a record holds in the clear: every key minus the encrypted ones.
  ///
  /// `allKeys()` reports both compartments (pinned by `encryptionPlacementFollowsTheLayout`), so
  /// reading it as the plaintext set would flag every well-formed record. This is the plaintext
  /// audit's input; what may be in the clear is `PodcastCloudRecordLayout`'s call in Core.
  static func plaintextFieldNames(of record: CKRecord) -> Set<String> {
    Set(record.allKeys()).subtracting(record.encryptedValues.allKeys())
  }

  /// Every portable kind has a `CKRecordValueProtocol` conformance, so nothing is re-encoded on
  /// the way out. `.boolean` is the one kind with no CloudKit field type of its own: `Bool` bridges
  /// to an INT64 0/1, which is why it reads back through `NSNumber` rather than as a `Bool`.
  private static func cloudValue(_ value: PodcastCloudRecordValue) -> any CKRecordValueProtocol {
    switch value {
    case .string(let value): value
    case .integer(let value): value
    case .boolean(let value): value
    case .double(let value): value
    case .date(let value): value
    case .data(let value): value
    case .stringList(let value): value
    }
  }

  /// `NSNumber` rather than a direct cast for the three numeric kinds: CloudKit's Objective-C
  /// bridging does not promise which Swift numeric type comes back out of a fetched record.
  private static func recordValue(
    _ raw: (any CKRecordValueProtocol)?, kind: PodcastCloudRecordLayout.ValueKind
  ) -> PodcastCloudRecordValue? {
    switch kind {
    case .string: (raw as? String).map { .string($0) }
    case .integer: (raw as? NSNumber).map { .integer($0.int64Value) }
    case .boolean: (raw as? NSNumber).map { .boolean($0.boolValue) }
    case .double: (raw as? NSNumber).map { .double($0.doubleValue) }
    case .date: (raw as? Date).map { .date($0) }
    case .data: (raw as? Data).map { .data($0) }
    case .stringList: (raw as? [String]).map { .stringList($0) }
    }
  }

  // MARK: - Batches

  /// `atomicByZone` is always true here and a parameter nowhere in the boundary (`CKSyncEngine`'s
  /// default is false): `batchRequestFailed` then fails the whole zone batch for one bad record,
  /// so no sub-record of a failed batch may be acknowledged.
  ///
  /// An empty batch becomes `nil`, which `CKSyncEngine` expects when there is nothing to send.
  static func batch(
    from batch: PodcastCloudRecordBatch, in zoneID: CKRecordZone.ID
  ) -> CKSyncEngine.RecordZoneChangeBatch? {
    guard batch.isEmpty == false else { return nil }
    return CKSyncEngine.RecordZoneChangeBatch(
      recordsToSave: batch.saves.map {
        record(from: $0, in: zoneID, systemFields: batch.systemFields[$0.recordName])
      },
      recordIDsToDelete: batch.deletions.map { CKRecord.ID(recordName: $0, zoneID: zoneID) },
      atomicByZone: true)
  }

  // MARK: - Failures and account changes

  /// Only the failures application code owns get their own case. Everything `CKSyncEngine` retries
  /// on its own (`notAuthenticated`, temporary account unavailability, network errors, rate
  /// limiting, service unavailable, zone busy) maps to `.other`: naming them would invite an
  /// app-side retry timer that fights the engine's schedule.
  static func failure(for code: CKError.Code) -> PodcastCloudSendFailure {
    switch code {
    case .serverRecordChanged: .serverRecordChanged
    case .batchRequestFailed: .batchRequestFailed
    // A request-level signal: the batch was too big, so split again. Only a batch of one
    // lets the coordinator conclude the record itself is too large.
    case .limitExceeded: .limitExceeded
    case .quotaExceeded: .quotaExceeded
    case .invalidArguments, .constraintViolation: .malformedRecord
    default: .other
    }
  }

  /// A failed save or deletion as the coordinator sees it. A failure the coordinator will hold is
  /// logged here with the service's own text, because this is the only place that still has it:
  /// the text names the record type and field the service refused, which the code alone does not
  /// (SECURITY.md). It can carry the record's name, a keyed hash, and never a payload.
  static func failedRecord(
    recordName: String, error: CKError, serverRecord: PodcastCloudFetchedRecord? = nil
  ) -> PodcastCloudFailedRecord {
    let failure = failure(for: error.code)
    if failure == .malformedRecord {
      log.error(
        "Podcast sync save refused, service code \(error.code.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
    return PodcastCloudFailedRecord(
      recordName: recordName, failure: failure, serverRecord: serverRecord,
      retryAfter: error.retryAfterSeconds, serviceCode: error.code.rawValue)
  }

  /// `zoneNotFound` and `userDeletedZone` stay distinct because their recovery differs: one is a
  /// zone that was never established in this namespace, the other is a zone the user deleted.
  /// Neither ever triggers automatic recreation.
  static func zoneLoss(for code: CKError.Code) -> PodcastCloudZoneLoss? {
    switch code {
    case .zoneNotFound: .zoneNotFound
    case .userDeletedZone: .userDeletedZone
    default: nil
    }
  }

  static func accountChange(
    for changeType: CKSyncEngine.Event.AccountChange.ChangeType
  ) -> PodcastCloudAccountChange {
    switch changeType {
    case .signIn: .signIn
    case .signOut: .signOut
    case .switchAccounts: .switchAccounts
    // An unrecognized change is treated as a switch: that is the case which fences everything and
    // quarantines old-account transport, so an unknown future case fails closed.
    @unknown default: .switchAccounts
    }
  }
}
