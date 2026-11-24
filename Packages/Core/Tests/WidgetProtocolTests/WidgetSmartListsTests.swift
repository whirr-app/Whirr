import Foundation
import Testing

@testable import WidgetProtocol

@Suite struct WidgetSmartListsTests {

  private static func token(_ list: Int, _ row: Int) -> String {
    let prefix = "l\(list)r\(row)"
    return prefix + String(repeating: "0", count: 64 - prefix.count)
  }

  private static func episode(_ token: String, title: String = "Episode") throws -> WidgetItem {
    try WidgetFixtures.item(
      token: token, kind: .feedEpisode, title: title, subtitle: "Show", chapterNumber: nil,
      coverFileName: "\(token).jpg")
  }

  /// Every list at every bound: the most lists, the most rows, and maximum-length text.
  static func largest() throws -> WidgetSmartLists {
    let longText = String(repeating: "é", count: WidgetSnapshotLimits.maxTextBytes / 2)
    let lists = try (1...WidgetSmartListLimits.maxLists).map { list in
      try WidgetSmartList(
        id: Int64.max - Int64(list), name: longText, matchCount: Int.max,
        items: (0..<WidgetSmartListLimits.maxItemsPerList).map { try episode(token(list, $0), title: longText) },
        loadedToken: token(list, 0))
    }
    return try WidgetSmartLists(
      generatedAt: WidgetFixtures.generatedAt, accountStamp: WidgetFixtures.stamp(),
      isPlaying: true, lists: lists)
  }

  @Test func everyShapeRoundTrips() throws {
    let values = try [
      WidgetSmartLists.signedOut(generatedAt: WidgetFixtures.generatedAt),
      WidgetSmartLists(generatedAt: WidgetFixtures.generatedAt, accountStamp: WidgetFixtures.stamp()),
      WidgetSmartLists(
        generatedAt: WidgetFixtures.generatedAt, accountStamp: WidgetFixtures.stamp(),
        lists: [WidgetSmartList(id: 7, name: "Commute", matchCount: nil, items: [])]),
      Self.largest(),
    ]
    for value in values {
      #expect(try WidgetSmartListsCodec.decode(WidgetSmartListsCodec.encode(value)) == value)
    }
  }

  @Test func equalValuesEncodeToIdenticalBytes() throws {
    #expect(try WidgetSmartListsCodec.encode(Self.largest()) == WidgetSmartListsCodec.encode(Self.largest()))
  }

  @Test func largestValidFileFitsInsideTheBound() throws {
    let bytes = try WidgetSmartListsCodec.encode(Self.largest()).count
    #expect(bytes < WidgetSmartListLimits.maxEncodedBytes, "largest valid list file is \(bytes) bytes")
  }

  @Test func oversizedInputIsRefusedBeforeDecoding() {
    let data = Data(repeating: UInt8(ascii: " "), count: WidgetSmartListLimits.maxEncodedBytes + 1)
    #expect(throws: WidgetProtocolError.tooLarge) { try WidgetSmartListsCodec.decode(data) }
  }

  @Test func otherSchemaVersionsAreRefusedByNumber() throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: WidgetSmartListsCodec.encode(Self.largest())) as? [String: Any])
    object["schemaVersion"] = 2
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: WidgetProtocolError.unsupportedVersion(2)) { try WidgetSmartListsCodec.decode(data) }
  }

  @Test func theSignedOutShapeCarriesNothing() throws {
    let list = try WidgetSmartList(id: 1, name: "A", matchCount: 0, items: [])
    #expect(throws: WidgetProtocolError.invalidValue) {
      try WidgetSmartLists(generatedAt: WidgetFixtures.generatedAt, accountStamp: nil, lists: [list])
    }
    #expect(throws: WidgetProtocolError.invalidValue) {
      try WidgetSmartLists(generatedAt: WidgetFixtures.generatedAt, accountStamp: nil, isPlaying: true)
    }
  }

  @Test func tooManyListsOrRowsAreRefused() throws {
    let lists = try (1...(WidgetSmartListLimits.maxLists + 1)).map {
      try WidgetSmartList(id: Int64($0), name: "List", matchCount: nil, items: [])
    }
    #expect(throws: WidgetProtocolError.tooManyItems) {
      try WidgetSmartLists(generatedAt: WidgetFixtures.generatedAt, accountStamp: WidgetFixtures.stamp(), lists: lists)
    }
    let rows = try (0...WidgetSmartListLimits.maxItemsPerList).map { try Self.episode(Self.token(1, $0)) }
    #expect(throws: WidgetProtocolError.tooManyItems) {
      try WidgetSmartList(id: 1, name: "List", matchCount: nil, items: rows)
    }
  }

  @Test func duplicateIdsAndTokensAreRefused() throws {
    let row = try Self.episode(Self.token(1, 0))
    let first = try WidgetSmartList(id: 1, name: "A", matchCount: 1, items: [row])
    let sameID = try WidgetSmartList(id: 1, name: "B", matchCount: 0, items: [])
    let sameToken = try WidgetSmartList(id: 2, name: "B", matchCount: 1, items: [row])
    for lists in [[first, sameID], [first, sameToken]] {
      #expect(throws: WidgetProtocolError.invalidValue) {
        try WidgetSmartLists(
          generatedAt: WidgetFixtures.generatedAt, accountStamp: WidgetFixtures.stamp(), lists: lists)
      }
    }
    #expect(throws: WidgetProtocolError.invalidValue) {
      try WidgetSmartList(id: 1, name: "A", matchCount: nil, items: [row, row])
    }
  }

  @Test(arguments: [Int64(0), -1, .min])
  func nonPositiveIdsAreRefused(id: Int64) {
    #expect(throws: WidgetProtocolError.invalidValue) {
      try WidgetSmartList(id: id, name: "A", matchCount: nil, items: [])
    }
  }

  @Test func theLoadedTokenMustBeOneOfTheListsRows() throws {
    let row = try Self.episode(Self.token(1, 0))
    #expect(throws: WidgetProtocolError.invalidValue) {
      try WidgetSmartList(id: 1, name: "A", matchCount: 1, items: [row], loadedToken: Self.token(1, 1))
    }
    let list = try WidgetSmartList(
      id: 1, name: "A", matchCount: 1, items: [row], loadedToken: row.token)
    #expect(list.loadedToken == row.token)
  }

  @Test func aCountBelowTheRowsOrABookRowIsRefused() throws {
    let row = try Self.episode(Self.token(1, 0))
    #expect(throws: WidgetProtocolError.invalidValue) {
      try WidgetSmartList(id: 1, name: "A", matchCount: 0, items: [row])
    }
    let book = try WidgetFixtures.item(token: Self.token(1, 1))
    #expect(throws: WidgetProtocolError.invalidValue) {
      try WidgetSmartList(id: 1, name: "A", matchCount: nil, items: [book])
    }
  }

  @Test func listNamesAreDrawableTextOnly() {
    for name in ["", "https://example.com/feed", "/var/mobile", "tab\there"] {
      #expect(throws: (any Error).self) { try WidgetSmartList(id: 1, name: name, matchCount: nil, items: []) }
    }
  }

  @Test func decodingValidatesNestedValues() throws {
    let text = try #require(String(data: WidgetSmartListsCodec.encode(Self.largest()), encoding: .utf8))
    let tampered = [
      text.replacingOccurrences(of: "\"id\":\(Int64.max - 1)", with: "\"id\":0"),
      text.replacingOccurrences(of: "\"kind\":\"feedEpisode\"", with: "\"kind\":\"book\""),
      text.replacingOccurrences(of: WidgetFixtures.accountHash, with: "someone"),
    ]
    for variant in tampered {
      #expect(variant != text)
      #expect(throws: (any Error).self) { try WidgetSmartListsCodec.decode(Data(variant.utf8)) }
    }
  }

  @Test func listLookupIsById() throws {
    let value = try Self.largest()
    #expect(value.list(id: Int64.max - 3)?.id == Int64.max - 3)
    #expect(value.list(id: 1) == nil)
  }

  // MARK: - Identity

  @Test func idsRoundTripThroughText() {
    for id: Int64 in [1, 42, .max] {
      #expect(WidgetSmartListID.parse(WidgetSmartListID.string(id)) == id)
    }
  }

  @Test(arguments: ["", "0", "-1", "+1", "01", " 1", "1 ", "1.0", "9223372036854775808", "١", "0x1"])
  func onlyCanonicalPositiveDecimalsParse(text: String) {
    #expect(WidgetSmartListID.parse(text) == nil)
  }

  // MARK: - Reader

  @Test func theReaderReadsOnlyAValidFileInsideTheBound() throws {
    let container = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: container) }
    let reader = WidgetSmartListsReader(containerURL: container)
    #expect(reader.read() == nil)

    let url = WidgetStorageLayout.smartListsFile(inContainer: container)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let value = try Self.largest()
    try WidgetSmartListsCodec.encode(value).write(to: url)
    #expect(reader.read() == value)

    try Data("{}".utf8).write(to: url)
    #expect(reader.read() == nil)
    try Data(repeating: 32, count: WidgetSmartListLimits.maxEncodedBytes + 1).write(to: url)
    #expect(reader.read() == nil)
    #expect(WidgetSmartListsReader(containerURL: nil).read() == nil)
  }
}
