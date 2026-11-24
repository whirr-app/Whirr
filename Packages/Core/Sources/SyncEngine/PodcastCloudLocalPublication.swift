import Foundation
import GRDB
import Persistence

/// How a local mutation reaches the cloud, inside the transaction that made it.
///
/// Two writes, always together: the outbox row that sends the record, and the record recorded as
/// this device's accepted value. A later fetch merges against the second once the send is
/// acknowledged and the outbox row is gone; without it, a remote record that loses on one
/// register but wins on another could be misjudged by stamp alone.
public enum PodcastCloudLocalPublication {
  public static func publish(_ fields: PodcastCloudRecordFields, in db: Database) throws {
    let payload = try PodcastCloudRecordPayload.encode(fields)
    try recordAccepted(fields, payload: payload, in: db)
    try PodcastCloudTransportStore.enqueue(in: db, recordName: fields.recordName, payload: payload)
  }

  /// Records `fields` as the accepted value for its record name. The unstamped keyring records
  /// nothing: it is write-once and never merged.
  static func recordAccepted(
    _ fields: PodcastCloudRecordFields, payload: Data? = nil, in db: Database
  ) throws {
    guard let stamp = try PodcastCloudRecordMerge.governingStamp(of: fields) else { return }
    try PodcastCloudRegistryStore.recordAccepted(
      in: db, recordName: fields.recordName, stamp: PodcastCloudStampFields(stamp),
      payload: try payload ?? PodcastCloudRecordPayload.encode(fields))
  }
}
