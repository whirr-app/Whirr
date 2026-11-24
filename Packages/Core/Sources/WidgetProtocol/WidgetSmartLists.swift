import Foundation

/// The smart lists the app publishes for the smart list widget and its Edit Widget picker, in a
/// file of their own beside the snapshot. A separate file leaves the snapshot's schema, and every
/// widget already drawing from it, untouched; and it can be larger, since every list is here
/// whether or not a widget shows it (the extension cannot query the database for a list the
/// listener picks while the app is closed).
///
/// Lists are named by their device-local row id: a widget's
/// configuration outlives every publication and every account binding, so the id must be stable.
/// Rows are named by opaque tokens, as on the snapshot's shelves.
public struct WidgetSmartLists: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let generatedAt: Date
  /// `nil` when signed out; then nothing else is carried.
  public let accountStamp: WidgetAccountStamp?
  /// The listener's intent to play (`isPlaybackIntended`); each list names its own loaded row.
  public let isPlaying: Bool
  /// Display order, at most `WidgetSmartListLimits.maxLists`.
  public let lists: [WidgetSmartList]

  public init(
    generatedAt: Date,
    accountStamp: WidgetAccountStamp?,
    isPlaying: Bool = false,
    lists: [WidgetSmartList] = []
  ) throws {
    self.schemaVersion = Self.currentSchemaVersion
    self.generatedAt = generatedAt
    self.accountStamp = accountStamp
    self.isPlaying = isPlaying
    self.lists = lists
    try validate()
  }

  public static func signedOut(generatedAt: Date) -> WidgetSmartLists {
    WidgetSmartLists(signedOutAt: generatedAt)
  }

  private init(signedOutAt generatedAt: Date) {
    self.schemaVersion = Self.currentSchemaVersion
    self.generatedAt = generatedAt
    self.accountStamp = nil
    self.isPlaying = false
    self.lists = []
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .schemaVersion)
    guard version == Self.currentSchemaVersion else {
      throw WidgetProtocolError.unsupportedVersion(version)
    }
    self.schemaVersion = version
    self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    self.accountStamp = try container.decodeIfPresent(WidgetAccountStamp.self, forKey: .accountStamp)
    self.isPlaying = try container.decode(Bool.self, forKey: .isPlaying)
    self.lists = try container.decode([WidgetSmartList].self, forKey: .lists)
    try validate()
  }

  public func list(id: Int64) -> WidgetSmartList? {
    lists.first { $0.id == id }
  }

  public func validate() throws {
    guard schemaVersion == Self.currentSchemaVersion else {
      throw WidgetProtocolError.unsupportedVersion(schemaVersion)
    }
    guard generatedAt.timeIntervalSinceReferenceDate.isFinite else {
      throw WidgetProtocolError.invalidValue
    }
    guard let accountStamp else {
      guard !isPlaying, lists.isEmpty else { throw WidgetProtocolError.invalidValue }
      return
    }
    try accountStamp.validate()
    guard lists.count <= WidgetSmartListLimits.maxLists else { throw WidgetProtocolError.tooManyItems }
    guard Set(lists.map(\.id)).count == lists.count else { throw WidgetProtocolError.invalidValue }
    // A list row's token is derived from its list, so no token appears twice in the file and a
    // token names one list's row.
    let tokens = lists.flatMap { $0.items.map(\.token) }
    guard Set(tokens).count == tokens.count else { throw WidgetProtocolError.invalidValue }
    for list in lists { try list.validate() }
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, generatedAt, accountStamp, isPlaying, lists
  }
}

/// One smart list as the widget draws it: its name, how many episodes match, and the first few.
public struct WidgetSmartList: Codable, Sendable, Equatable, Identifiable {
  public let id: Int64
  public let name: String
  /// `nil` when the reading did not count.
  public let matchCount: Int?
  public let items: [WidgetItem]
  /// The row whose episode the player has loaded, if one of `items` is it. The same episode may
  /// be a row of several lists under different tokens, so each list names its own.
  public let loadedToken: String?

  public init(
    id: Int64, name: String, matchCount: Int?, items: [WidgetItem], loadedToken: String? = nil
  ) throws {
    self.id = id
    self.name = name
    self.matchCount = matchCount
    self.items = items
    self.loadedToken = loadedToken
    try validate()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(Int64.self, forKey: .id)
    self.name = try container.decode(String.self, forKey: .name)
    self.matchCount = try container.decodeIfPresent(Int.self, forKey: .matchCount)
    self.items = try container.decode([WidgetItem].self, forKey: .items)
    self.loadedToken = try container.decodeIfPresent(String.self, forKey: .loadedToken)
    try validate()
  }

  public func validate() throws {
    guard WidgetSmartListID.isValid(id) else { throw WidgetProtocolError.invalidValue }
    try WidgetValidation.validateText(name)
    guard items.count <= WidgetSmartListLimits.maxItemsPerList else {
      throw WidgetProtocolError.tooManyItems
    }
    if let matchCount {
      guard matchCount >= items.count else { throw WidgetProtocolError.invalidValue }
    }
    guard Set(items.map(\.token)).count == items.count else { throw WidgetProtocolError.invalidValue }
    if let loadedToken {
      guard items.contains(where: { $0.token == loadedToken }) else { throw WidgetProtocolError.invalidValue }
    }
    for item in items {
      guard item.kind != .book, item.chapterNumber == nil else { throw WidgetProtocolError.invalidValue }
      try item.validate()
    }
  }

  private enum CodingKeys: String, CodingKey { case id, name, matchCount, items, loadedToken }
}

public enum WidgetSmartListLimits {
  public static let maxLists = 50
  public static let maxItemsPerList = 4
  /// Above the largest valid file (50 lists of four maximum-length rows and maximum-length names,
  /// about 175 KB), so the bound only catches a file that is not this one.
  public static let maxEncodedBytes = 192 * 1024
}

/// A list's identity in the widget's configuration, its link and the list file: the positive
/// row id, written as canonical decimal where it must be text.
public enum WidgetSmartListID {
  public static func isValid(_ id: Int64) -> Bool { id > 0 }

  public static func string(_ id: Int64) -> String { String(id) }

  /// Canonical decimal only: digits, no sign, no leading zero, within `Int64`, positive. Anything
  /// else did not come from `string(_:)`.
  public static func parse(_ value: String) -> Int64? {
    guard let first = value.utf8.first, first != UInt8(ascii: "0"),
      value.utf8.count <= 19, value.utf8.allSatisfy({ (48...57).contains($0) }),
      let id = Int64(value), isValid(id)
    else { return nil }
    return id
  }
}

/// Encodes and decodes the list file with the snapshot codec's rules: validate both ways, bound
/// the bytes, sorted keys so unchanged content is unchanged bytes.
public enum WidgetSmartListsCodec {
  private struct VersionProbe: Decodable {
    let schemaVersion: Int?
  }

  public static func encode(_ value: WidgetSmartLists) throws -> Data {
    try value.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .deferredToDate
    let data = try encoder.encode(value)
    guard data.count <= WidgetSmartListLimits.maxEncodedBytes else { throw WidgetProtocolError.tooLarge }
    return data
  }

  public static func decode(_ data: Data) throws -> WidgetSmartLists {
    guard data.count <= WidgetSmartListLimits.maxEncodedBytes else { throw WidgetProtocolError.tooLarge }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    let probe = try decoder.decode(VersionProbe.self, from: data)
    if let version = probe.schemaVersion, version != WidgetSmartLists.currentSchemaVersion {
      throw WidgetProtocolError.unsupportedVersion(version)
    }
    return try decoder.decode(WidgetSmartLists.self, from: data)
  }
}

/// The read side of the list file, shared by the widget's provider and the Edit Widget picker's
/// query, which runs in either process. `nil` for anything unreadable: no container, before the
/// first unlock, never published, or not a file this build understands.
public struct WidgetSmartListsReader: Sendable {
  public let containerURL: URL?

  public init(containerURL: URL?) {
    self.containerURL = containerURL
  }

  public static var production: WidgetSmartListsReader {
    WidgetSmartListsReader(
      containerURL: FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: WidgetStorageLayout.appGroupIdentifier))
  }

  public func read() -> WidgetSmartLists? {
    guard let containerURL else { return nil }
    let url = WidgetStorageLayout.smartListsFile(inContainer: containerURL)
    // Bound the read before loading, as the snapshot reader does.
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= WidgetSmartListLimits.maxEncodedBytes,
      let data = try? Data(contentsOf: url)
    else { return nil }
    return try? WidgetSmartListsCodec.decode(data)
  }
}
