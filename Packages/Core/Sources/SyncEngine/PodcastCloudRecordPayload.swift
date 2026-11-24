import Foundation

/// Durable serialization of one record's fields, for the `podcastCloudOutbox.payload` column.
///
/// The outbox is the source of truth for unsent work (the engine's pending set is a discardable
/// cache), so a pending save survives process death as bytes: rows written by one build are
/// decoded by the next.
///
/// Versioned; an unrecognised version is an error. An undecodable payload stays in the outbox as
/// an unsent, visibly broken row rather than sending a half-understood record.
///
/// Deterministic (sorted keys) because `enqueue` coalesces on `recordName`: byte-identical output
/// for an unchanged record lets a caller compare payloads.
///
/// Decoding validates against `PodcastCloudRecordLayout` so the compartment split survives the
/// round trip; otherwise an encrypted field in `plaintext` would reach CloudKit in the clear.
public enum PodcastCloudRecordPayload {
  /// Bumped only for a format change that older readers cannot understand.
  public static let version = 1

  public enum PayloadError: Error, Sendable, Equatable {
    case unsupportedVersion(Int)
    case unknownRecordType(String)
    case unknownValueKind(String)
    /// The field arrived in the compartment the layout does not declare for it.
    case wrongCompartment(field: String, encryptedInLayout: Bool)
    case malformed
  }

  public static func encode(_ fields: PodcastCloudRecordFields) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(Envelope(fields))
  }

  /// Round-trips `encode`, then re-checks the result against the layout.
  public static func decode(_ payload: Data) throws -> PodcastCloudRecordFields {
    let envelope: Envelope
    do {
      envelope = try JSONDecoder().decode(Envelope.self, from: payload)
    } catch let error as PayloadError {
      throw error
    } catch {
      throw PayloadError.malformed
    }
    guard envelope.version == version else {
      throw PayloadError.unsupportedVersion(envelope.version)
    }
    guard let type = PodcastCloudRecordLayout.recordType(named: envelope.recordType) else {
      throw PayloadError.unknownRecordType(envelope.recordType)
    }
    let fields = PodcastCloudRecordFields(
      recordType: envelope.recordType, recordName: envelope.recordName,
      plaintext: envelope.plaintext.mapValues(\.value),
      encrypted: envelope.encrypted.mapValues(\.value))
    try validate(fields, against: type)
    return fields
  }

  private static func validate(
    _ fields: PodcastCloudRecordFields, against type: PodcastCloudRecordLayout.RecordType
  ) throws {
    for (compartmentIsEncrypted, values) in [(false, fields.plaintext), (true, fields.encrypted)] {
      for (name, value) in values {
        guard let field = type.fields.first(where: { $0.name == name }) else {
          throw PodcastCloudRecordMappingError.undeclaredField(name)
        }
        guard field.isEncrypted == compartmentIsEncrypted else {
          throw PayloadError.wrongCompartment(field: name, encryptedInLayout: field.isEncrypted)
        }
        guard value.kind == field.kind else {
          throw PodcastCloudRecordMappingError.kindMismatch(field: name, expected: field.kind)
        }
      }
    }
  }

  private struct Envelope: Codable {
    let version: Int
    let recordType: String
    let recordName: String
    let plaintext: [String: Tagged]
    let encrypted: [String: Tagged]

    init(_ fields: PodcastCloudRecordFields) {
      version = PodcastCloudRecordPayload.version
      recordType = fields.recordType
      recordName = fields.recordName
      plaintext = fields.plaintext.mapValues(Tagged.init)
      encrypted = fields.encrypted.mapValues(Tagged.init)
    }
  }

  /// A value tagged with its `ValueKind`. The tag reuses the layout's own kind names rather than
  /// inventing a parallel set, so a new kind cannot be added to the layout and forgotten here.
  private struct Tagged: Codable {
    let value: PodcastCloudRecordValue

    init(_ value: PodcastCloudRecordValue) { self.value = value }

    private enum CodingKeys: String, CodingKey { case kind, value }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(value.kind.rawValue, forKey: .kind)
      switch value {
      case .string(let inner): try container.encode(inner, forKey: .value)
      case .integer(let inner): try container.encode(inner, forKey: .value)
      case .boolean(let inner): try container.encode(inner, forKey: .value)
      case .double(let inner): try container.encode(inner, forKey: .value)
      // Seconds since 1970 as a Double, which JSON round-trips exactly. `Date` itself is not
      // encoded directly because that would inherit whatever date strategy a future caller sets.
      case .date(let inner): try container.encode(inner.timeIntervalSince1970, forKey: .value)
      case .data(let inner): try container.encode(inner, forKey: .value)
      case .stringList(let inner): try container.encode(inner, forKey: .value)
      }
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let rawKind = try container.decode(String.self, forKey: .kind)
      guard let kind = PodcastCloudRecordLayout.ValueKind(rawValue: rawKind) else {
        throw PayloadError.unknownValueKind(rawKind)
      }
      switch kind {
      case .string: value = .string(try container.decode(String.self, forKey: .value))
      case .integer: value = .integer(try container.decode(Int64.self, forKey: .value))
      case .boolean: value = .boolean(try container.decode(Bool.self, forKey: .value))
      case .double: value = .double(try container.decode(Double.self, forKey: .value))
      case .date:
        value = .date(
          Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .value)))
      case .data: value = .data(try container.decode(Data.self, forKey: .value))
      case .stringList: value = .stringList(try container.decode([String].self, forKey: .value))
      }
    }
  }
}
