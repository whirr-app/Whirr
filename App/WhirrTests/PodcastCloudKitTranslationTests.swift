import CloudKit
import Foundation
import SyncEngine
import Testing

@testable import Whirr

/// The App's share of the CloudKit translation boundary. Everything here is local: no container is
/// created, no account is consulted, and no network call is made. `CKRecord`, `CKError.Code` and
/// `CKSyncEngine.Event.AccountChange.ChangeType` are all constructible in a host test;
/// `CKSyncEngine.Event` itself is not, which is why the adapter keeps every decision in the pure
/// functions below rather than in the delegate callbacks.
@Suite("Podcast CloudKit translation")
struct PodcastCloudKitTranslationTests {
  private let zoneID = CKRecordZone.ID(zoneName: "PodcastState", ownerName: CKCurrentUserDefaultName)

  private func globalSettings() throws -> PodcastCloudRecordFields {
    var builder = PodcastCloudRecordBuilder(
      type: PodcastCloudRecordLayout.globalSettings, recordName: "v1.globals")
    try builder.set("autoDownloadEnabled", .boolean(true))
    try builder.set("keepLatestCount", .integer(5))
    try builder.set("deleteAfterPlayed", .boolean(false))
    try builder.set("showOrderMode", .string("alphabetical"))
    try builder.set("enabledAt", .date(Date(timeIntervalSince1970: 1_700_000_000)))
    let stamp = try PodcastCloudMutationStamp(
      physicalMilliseconds: 1_234, logicalCounter: 7,
      installationUUID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      mutationUUID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    try builder.set(stamp: stamp, prefix: "write")
    return try builder.build()
  }

  @Test("a record survives the round trip through CloudKit's value types unchanged")
  func roundTripPreservesEveryKind() throws {
    let fields = try globalSettings()

    let record = PodcastCloudKitTranslation.record(from: fields, in: zoneID)
    let returned = try PodcastCloudKitTranslation.fields(from: record)

    #expect(returned == fields)
    #expect(record.recordID.zoneID == zoneID)
    #expect(record.recordID.recordName == "v1.globals")
    #expect(record.recordType == "PodcastGlobalSettings")
  }

  @Test("encrypted fields go to the encrypted compartment and only the schema marker is in the clear")
  func encryptionPlacementFollowsTheLayout() throws {
    let record = PodcastCloudKitTranslation.record(from: try globalSettings(), in: zoneID)

    // The property the layout-driven reader depends on: the two compartments are separate stores,
    // so an encrypted field is not reachable through the ordinary subscript. If this ever changed,
    // reading encrypted fields only from `encryptedValues` would stop being a rejection.
    let clearKeepLatest: (any CKRecordValueProtocol)? = record["keepLatestCount"]
    #expect(clearKeepLatest == nil)
    #expect((record.encryptedValues["keepLatestCount"] as? NSNumber)?.int64Value == 5)
    #expect((record.encryptedValues["autoDownloadEnabled"] as? NSNumber)?.boolValue == true)
    #expect(record.encryptedValues["showOrderMode"] as? String == "alphabetical")

    // Characterized against the iOS 27 SDK, because the plaintext audit depends on it: `allKeys()`
    // is not a list of fields in the clear. It reports both compartments, so an audit that read
    // it as "unencrypted keys" would flag every well-formed record. The clear set is `allKeys()`
    // minus `encryptedValues.allKeys()`, and by the encryption-coverage rule that difference must
    // be exactly the `schema` marker.
    let allKeys = Set(record.allKeys())
    let encryptedKeys = Set(record.encryptedValues.allKeys())
    #expect(allKeys.contains(PodcastCloudRecordLayout.schemaFieldName))
    #expect(encryptedKeys.contains("keepLatestCount"))
    #expect(allKeys.isSuperset(of: encryptedKeys))
    #expect(allKeys.subtracting(encryptedKeys) == PodcastCloudRecordLayout.permittedPlaintextFieldNames)
  }

  @Test("a record type this schema version does not declare is rejected, not silently emptied")
  func undeclaredRecordTypeIsRejected() throws {
    let record = CKRecord(
      recordType: "PodcastSomethingNewer",
      recordID: CKRecord.ID(recordName: "v1.newer.0", zoneID: zoneID))

    #expect(throws: PodcastCloudKitTranslation.Failure.undeclaredRecordType("PodcastSomethingNewer")) {
      try PodcastCloudKitTranslation.fields(from: record)
    }
  }

  @Test("a field a newer schema version added is ignored rather than admitted")
  func undeclaredFieldsAreIgnored() throws {
    let record = PodcastCloudKitTranslation.record(from: try globalSettings(), in: zoneID)
    record.encryptedValues["someFieldFromTheFuture"] = "surprise"

    let returned = try PodcastCloudKitTranslation.fields(from: record)
    let expected = try globalSettings()

    #expect(returned.encrypted["someFieldFromTheFuture"] == nil)
    #expect(returned == expected)
  }

  @Test("a batch is atomic by zone, which CKSyncEngine is not by default")
  func batchesAreAtomicByZone() throws {
    let batch = PodcastCloudRecordBatch(saves: [try globalSettings()], deletions: ["v1.bookmark"])

    let translated = try #require(PodcastCloudKitTranslation.batch(from: batch, in: zoneID))

    #expect(translated.atomicByZone)
    #expect(translated.recordsToSave.map(\.recordID.recordName) == ["v1.globals"])
    #expect(translated.recordIDsToDelete.map(\.recordName) == ["v1.bookmark"])
    #expect(translated.recordIDsToDelete.allSatisfy { $0.zoneID == zoneID })
  }

  @Test("a save is rebuilt from its system-fields archive so it stays conditional")
  func batchSavesCarryTheirSystemFields() throws {
    let fields = try globalSettings()
    let server = PodcastCloudKitTranslation.record(from: fields, in: zoneID)
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    server.encodeSystemFields(with: coder)
    coder.finishEncoding()
    let archive = coder.encodedData

    let rebuilt = PodcastCloudKitTranslation.record(from: fields, in: zoneID, systemFields: archive)
    let unconditional = PodcastCloudKitTranslation.record(from: fields, in: zoneID, systemFields: nil)
    let batch = try #require(
      PodcastCloudKitTranslation.batch(
        from: PodcastCloudRecordBatch(saves: [fields], systemFields: ["v1.globals": archive]),
        in: zoneID))

    #expect(rebuilt.recordID == server.recordID)
    #expect(try PodcastCloudKitTranslation.fields(from: rebuilt) == fields)
    #expect(unconditional.recordID == server.recordID)
    #expect(batch.recordsToSave.first?.recordID == server.recordID)
  }

  @Test("an archive for a different record is ignored rather than trusted")
  func mismatchedArchiveIsIgnored() throws {
    let fields = try globalSettings()
    let other = CKRecord(
      recordType: "PodcastGlobalSettings",
      recordID: CKRecord.ID(recordName: "v1.bookmark", zoneID: zoneID))
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    other.encodeSystemFields(with: coder)
    coder.finishEncoding()

    let rebuilt = PodcastCloudKitTranslation.record(
      from: fields, in: zoneID, systemFields: coder.encodedData)

    #expect(rebuilt.recordID.recordName == "v1.globals")
  }

  @Test("the plaintext audit reads the clear compartment, not allKeys()")
  func plaintextAuditSubtractsEncryptedKeys() throws {
    let record = PodcastCloudKitTranslation.record(from: try globalSettings(), in: zoneID)
    #expect(
      PodcastCloudKitTranslation.plaintextFieldNames(of: record)
        == PodcastCloudRecordLayout.permittedPlaintextFieldNames)

    // A field written in the clear by a defective or tampered writer is exactly what the audit
    // exists to report.
    record["strayField"] = "in the clear" as NSString
    #expect(
      PodcastCloudKitTranslation.plaintextFieldNames(of: record)
        == [PodcastCloudRecordLayout.schemaFieldName, "strayField"])
  }

  @Test("the keyring reads back through the layout, and a key in the clear is not adopted")
  func keyringKeyReadsThroughTheLayout() throws {
    let key = Data(repeating: 5, count: 32)
    let record = PodcastCloudKitTranslation.record(
      from: try PodcastCloudRecordCodec.encodeKeyring(recordNameKey: key), in: zoneID)
    #expect(try PodcastCloudKitKeyringStore.recordNameKey(from: record) == key)

    let clear = CKRecord(
      recordType: PodcastCloudRecordLayout.keyring.name,
      recordID: CKRecord.ID(recordName: PodcastCloudIdentity.keyringRecordName, zoneID: zoneID))
    clear[PodcastCloudRecordLayout.schemaFieldName] = 1 as NSNumber
    clear[PodcastCloudRecordLayout.recordNameKeyFieldName] = key as NSData
    #expect(throws: (any Error).self) { try PodcastCloudKitKeyringStore.recordNameKey(from: clear) }
  }

  @Test("an empty batch becomes nil rather than a batch reporting work that does not exist")
  func emptyBatchesBecomeNil() {
    #expect(PodcastCloudKitTranslation.batch(from: PodcastCloudRecordBatch(saves: []), in: zoneID) == nil)
  }

  @Test("a failed record carries the service's error code, which is what tells two rejections apart")
  func aFailedRecordCarriesTheServiceCode() {
    let rejected = PodcastCloudKitTranslation.failedRecord(
      recordName: "v1.settings.a", error: CKError(.invalidArguments))
    #expect(rejected.failure == .malformedRecord)
    #expect(rejected.serviceCode == CKError.Code.invalidArguments.rawValue)
    #expect(rejected.recordName == "v1.settings.a")

    let constrained = PodcastCloudKitTranslation.failedRecord(
      recordName: "v1.settings.a", error: CKError(.constraintViolation))
    #expect(constrained.failure == .malformedRecord)
    #expect(constrained.serviceCode == CKError.Code.constraintViolation.rawValue)
  }

  @Test("only the failures application code owns are named; the engine's own retries are not")
  func failureMappingNamesOnlyApplicationOwnedCases() {
    #expect(PodcastCloudKitTranslation.failure(for: .serverRecordChanged) == .serverRecordChanged)
    #expect(PodcastCloudKitTranslation.failure(for: .batchRequestFailed) == .batchRequestFailed)
    #expect(PodcastCloudKitTranslation.failure(for: .limitExceeded) == .limitExceeded)
    #expect(PodcastCloudKitTranslation.failure(for: .quotaExceeded) == .quotaExceeded)
    #expect(PodcastCloudKitTranslation.failure(for: .invalidArguments) == .malformedRecord)
    #expect(PodcastCloudKitTranslation.failure(for: .constraintViolation) == .malformedRecord)

    // Left unnamed: naming what CKSyncEngine already retries would invite an app-side timer that
    // fights its schedule.
    #expect(PodcastCloudKitTranslation.failure(for: .networkUnavailable) == .other)
    #expect(PodcastCloudKitTranslation.failure(for: .notAuthenticated) == .other)
    #expect(PodcastCloudKitTranslation.failure(for: .requestRateLimited) == .other)
    #expect(PodcastCloudKitTranslation.failure(for: .zoneBusy) == .other)
  }

  @Test("the two zone-loss codes stay distinct, because their recovery differs")
  func zoneLossKeepsTheTwoCodesApart() {
    #expect(PodcastCloudKitTranslation.zoneLoss(for: .zoneNotFound) == .zoneNotFound)
    #expect(PodcastCloudKitTranslation.zoneLoss(for: .userDeletedZone) == .userDeletedZone)
    #expect(PodcastCloudKitTranslation.zoneLoss(for: .serverRecordChanged) == nil)
  }

  @Test("every account change maps to the boundary's own vocabulary")
  func accountChangeMapping() {
    let user = CKRecord.ID(recordName: "_user")
    let other = CKRecord.ID(recordName: "_other")

    #expect(PodcastCloudKitTranslation.accountChange(for: .signIn(currentUser: user)) == .signIn)
    #expect(PodcastCloudKitTranslation.accountChange(for: .signOut(previousUser: user)) == .signOut)
    #expect(
      PodcastCloudKitTranslation.accountChange(
        for: .switchAccounts(previousUser: other, currentUser: user)) == .switchAccounts)
  }
}
