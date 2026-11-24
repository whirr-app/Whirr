import Foundation

/// A portable field value. The kinds are `PodcastCloudRecordLayout.ValueKind`, so a value
/// can always be checked against the field the layout declares before it reaches CloudKit.
public enum PodcastCloudRecordValue: Sendable, Equatable {
  case string(String)
  case integer(Int64)
  case boolean(Bool)
  case double(Double)
  case date(Date)
  case data(Data)
  case stringList([String])

  public var kind: PodcastCloudRecordLayout.ValueKind {
    switch self {
    case .string: .string
    case .integer: .integer
    case .boolean: .boolean
    case .double: .double
    case .date: .date
    case .data: .data
    case .stringList: .stringList
    }
  }
}

public enum PodcastCloudRecordMappingError: Error, Sendable, Equatable {
  /// A field name the record type does not declare. The layout is the whole inventory; a mapping
  /// that invents a field would create an undeclared CloudKit field on first write.
  case undeclaredField(String)
  case kindMismatch(field: String, expected: PodcastCloudRecordLayout.ValueKind)
  case missingRequiredField(String)
  case schemaMismatch(Int)
  case nonFiniteValue(String)
}

/// A record's fields, already split by the layout's encryption decision. The App writes
/// `encrypted` through `CKRecord.encryptedValues` and `plaintext` through the record's ordinary
/// subscript, so no caller can place an encrypted field in the clear. `plaintext` can only ever
/// hold the `schema` marker.
public struct PodcastCloudRecordFields: Sendable, Equatable {
  public let recordType: String
  public let recordName: String
  public let plaintext: [String: PodcastCloudRecordValue]
  public let encrypted: [String: PodcastCloudRecordValue]

  public init(
    recordType: String, recordName: String, plaintext: [String: PodcastCloudRecordValue],
    encrypted: [String: PodcastCloudRecordValue]
  ) {
    self.recordType = recordType
    self.recordName = recordName
    self.plaintext = plaintext
    self.encrypted = encrypted
  }
}

/// Builds one record's fields against its layout entry. Every `set` is checked, so the encryption
/// placement of a field is decided by the layout table and never by the calling code.
public struct PodcastCloudRecordBuilder: Sendable {
  private let type: PodcastCloudRecordLayout.RecordType
  private let recordName: String
  private var values: [String: PodcastCloudRecordValue] = [:]

  public init(type: PodcastCloudRecordLayout.RecordType, recordName: String) {
    self.type = type
    self.recordName = recordName
  }

  /// A `nil` value clears the field: absence is meaningful in this schema (no state row, no saved
  /// register, an omitted optional), so it is represented by the field not being written at all.
  public mutating func set(_ name: String, _ value: PodcastCloudRecordValue?) throws {
    guard let field = type.fields.first(where: { $0.name == name }) else {
      throw PodcastCloudRecordMappingError.undeclaredField(name)
    }
    guard let value else {
      values.removeValue(forKey: name)
      return
    }
    guard value.kind == field.kind else {
      throw PodcastCloudRecordMappingError.kindMismatch(field: name, expected: field.kind)
    }
    if case .double(let number) = value, !number.isFinite {
      throw PodcastCloudRecordMappingError.nonFiniteValue(name)
    }
    values[name] = value
  }

  public mutating func set(stamp: PodcastCloudMutationStamp, prefix: String) throws {
    try set("\(prefix)PhysicalMilliseconds", .integer(stamp.physicalMilliseconds))
    try set("\(prefix)LogicalCounter", .integer(stamp.logicalCounter))
    try set("\(prefix)InstallationUUID", .string(stamp.installationUUID.uuidString.lowercased()))
    try set("\(prefix)MutationUUID", .string(stamp.mutationUUID.uuidString.lowercased()))
  }

  public func build() throws -> PodcastCloudRecordFields {
    var plaintext: [String: PodcastCloudRecordValue] = [
      PodcastCloudRecordLayout.schemaFieldName: .integer(Int64(PodcastCloudRecordLayout.schemaVersion))
    ]
    var encrypted: [String: PodcastCloudRecordValue] = [:]
    for (name, value) in values {
      guard let field = type.fields.first(where: { $0.name == name }) else {
        throw PodcastCloudRecordMappingError.undeclaredField(name)
      }
      if name == PodcastCloudRecordLayout.schemaFieldName { continue }
      if field.isEncrypted {
        encrypted[name] = value
      } else {
        plaintext[name] = value
      }
    }
    return PodcastCloudRecordFields(
      recordType: type.name, recordName: recordName, plaintext: plaintext, encrypted: encrypted)
  }
}

/// Reads a record's fields back. The reader takes the same layout entry, so a field that arrived
/// in the wrong compartment (an encrypted field delivered in the clear by an older or tampered
/// writer) is not silently accepted.
public struct PodcastCloudRecordReader: Sendable {
  private let type: PodcastCloudRecordLayout.RecordType
  private let fields: PodcastCloudRecordFields

  public init(type: PodcastCloudRecordLayout.RecordType, fields: PodcastCloudRecordFields) {
    self.type = type
    self.fields = fields
  }

  public func validateSchema() throws {
    guard case .integer(let version)? = fields.plaintext[PodcastCloudRecordLayout.schemaFieldName]
    else { throw PodcastCloudRecordMappingError.missingRequiredField(PodcastCloudRecordLayout.schemaFieldName) }
    guard version == Int64(PodcastCloudRecordLayout.schemaVersion) else {
      throw PodcastCloudRecordMappingError.schemaMismatch(Int(version))
    }
  }

  public func value(_ name: String) throws -> PodcastCloudRecordValue? {
    guard let field = type.fields.first(where: { $0.name == name }) else {
      throw PodcastCloudRecordMappingError.undeclaredField(name)
    }
    let value = field.isEncrypted ? fields.encrypted[name] : fields.plaintext[name]
    guard let value else { return nil }
    guard value.kind == field.kind else {
      throw PodcastCloudRecordMappingError.kindMismatch(field: name, expected: field.kind)
    }
    return value
  }

  public func required(_ name: String) throws -> PodcastCloudRecordValue {
    guard let value = try value(name) else {
      throw PodcastCloudRecordMappingError.missingRequiredField(name)
    }
    return value
  }

  public func string(_ name: String) throws -> String? {
    if case .string(let value)? = try self.value(name) { return value }
    return nil
  }

  public func integer(_ name: String) throws -> Int64? {
    if case .integer(let value)? = try self.value(name) { return value }
    return nil
  }

  public func boolean(_ name: String) throws -> Bool? {
    if case .boolean(let value)? = try self.value(name) { return value }
    return nil
  }

  public func double(_ name: String) throws -> Double? {
    if case .double(let value)? = try self.value(name) { return value }
    return nil
  }

  public func date(_ name: String) throws -> Date? {
    if case .date(let value)? = try self.value(name) { return value }
    return nil
  }

  public func stringList(_ name: String) throws -> [String]? {
    if case .stringList(let value)? = try self.value(name) { return value }
    return nil
  }

  public func stamp(prefix: String) throws -> PodcastCloudMutationStamp {
    guard case .integer(let physical) = try required("\(prefix)PhysicalMilliseconds"),
      case .integer(let logical) = try required("\(prefix)LogicalCounter"),
      case .string(let installation) = try required("\(prefix)InstallationUUID"),
      case .string(let mutation) = try required("\(prefix)MutationUUID"),
      let installationUUID = UUID(uuidString: installation),
      let mutationUUID = UUID(uuidString: mutation)
    else { throw PodcastCloudRecordMappingError.missingRequiredField("\(prefix)Stamp") }
    return try PodcastCloudMutationStamp(
      physicalMilliseconds: physical, logicalCounter: logical, installationUUID: installationUUID,
      mutationUUID: mutationUUID)
  }
}
