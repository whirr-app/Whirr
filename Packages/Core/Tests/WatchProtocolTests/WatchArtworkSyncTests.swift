import Foundation
import Testing

@testable import WatchProtocol

struct WatchArtworkSyncTests {
  let phone = try! WatchAccountStamp(accountIdentityHash: "phone", serverIdentityHash: "server")
  let watch = try! WatchAccountStamp(accountIdentityHash: "watch", serverIdentityHash: "server")

  func cover(_ id: String, revision: String = "1", size: WatchArtworkSize = .row) -> WatchArtworkCover {
    WatchArtworkCover(
      reference: WatchArtworkReference(source: .audiobookshelf(itemID: id), revision: revision), size: size)
  }

  @Test func manifestRoundTripsWithBothStamps() throws {
    let manifest = try WatchArtworkManifest(
      accountStamp: phone, authenticatedAccountStamp: watch,
      covers: [
        cover("a"), cover("b", size: .player),
        WatchArtworkCover(
          reference: WatchArtworkReference(source: .nativeFeed(feedID: "7")), size: .row),
      ])
    let decoded = try WatchWireCodec.decode(WatchArtworkManifest.self, from: WatchWireCodec.encode(manifest))
    #expect(decoded == manifest)
    #expect(decoded.hasSameCovers(as: manifest))
  }

  @Test func aFullSizedManifestFitsTheWireLimit() throws {
    let covers = (0..<WatchArtworkSyncLimits.maxManifestCovers).map {
      cover("li_\(UUID().uuidString.lowercased())_\($0)", revision: "1790000000123")
    }
    let manifest = try WatchArtworkManifest(accountStamp: phone, authenticatedAccountStamp: watch, covers: covers)
    let data = try WatchWireCodec.encode(manifest)
    #expect(data.count <= WatchArtworkManifest.maxWireBytes)
  }

  @Test func manifestRefusesTooManyOrDuplicateCovers() throws {
    let tooMany = (0...WatchArtworkSyncLimits.maxManifestCovers).map { cover("\($0)") }
    #expect(throws: WatchProtocolCodingError.tooLarge) {
      try WatchArtworkManifest(accountStamp: phone, authenticatedAccountStamp: nil, covers: tooMany)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchArtworkManifest(accountStamp: phone, authenticatedAccountStamp: nil, covers: [cover("a"), cover("a")])
    }
  }

  @Test func manifestsWithTheSameCoversCompareEqualDespiteNewIDs() throws {
    let first = try WatchArtworkManifest(accountStamp: phone, authenticatedAccountStamp: watch, covers: [cover("a")])
    let second = try WatchArtworkManifest(accountStamp: phone, authenticatedAccountStamp: watch, covers: [cover("a")])
    let changed = try WatchArtworkManifest(
      accountStamp: phone, authenticatedAccountStamp: watch, covers: [cover("a", revision: "2")])
    let otherWatch = try WatchArtworkManifest(accountStamp: phone, authenticatedAccountStamp: nil, covers: [cover("a")])
    #expect(first.id != second.id)
    #expect(first.hasSameCovers(as: second))
    #expect(!first.hasSameCovers(as: changed))
    #expect(!first.hasSameCovers(as: otherWatch))
  }

  @Test func wantListIsBoundedAndAnEmptyOneAsksForAManifest() throws {
    let ask = try WatchArtworkWantList(accountStamp: phone, manifestID: nil, covers: [])
    #expect(ask.isManifestRequest)
    let decoded = try WatchWireCodec.decode(WatchArtworkWantList.self, from: WatchWireCodec.encode(ask))
    #expect(decoded == ask)
    let full = try WatchArtworkWantList(
      accountStamp: phone, manifestID: UUID(),
      covers: (0..<WatchArtworkSyncLimits.maxWantedCovers).map { cover("li_\(UUID().uuidString)_\($0)") })
    #expect(!full.isManifestRequest)
    #expect(try WatchWireCodec.encode(full).count <= WatchArtworkWantList.maxWireBytes)
    #expect(throws: WatchProtocolCodingError.tooLarge) {
      try WatchArtworkWantList(
        accountStamp: phone, manifestID: nil,
        covers: (0...WatchArtworkSyncLimits.maxWantedCovers).map { cover("\($0)") })
    }
  }

  @Test func bundleCarriesImagesAndWhatThePhoneCouldNotServe() throws {
    let wantList = try WatchArtworkWantList(accountStamp: phone, manifestID: UUID(), covers: [cover("a"), cover("b")])
    let bundle = try WatchArtworkBundle(
      answering: wantList, entries: [WatchArtworkBundle.Entry(cover: cover("a"), imageData: Data([1, 2, 3]))],
      unavailable: [cover("b")], isFinal: true)
    let decoded = try WatchWireCodec.decode(WatchArtworkBundle.self, from: WatchWireCodec.encode(bundle))
    #expect(decoded == bundle)
    #expect(decoded.wantListID == wantList.id)
    #expect(decoded.accountStamp == phone)
  }

  @Test func bundleRefusesOversizedImagesAndOversizedTotals() throws {
    let wantList = try WatchArtworkWantList(accountStamp: phone, manifestID: nil, covers: [cover("a")])
    #expect(throws: WatchProtocolCodingError.tooLarge) {
      try WatchArtworkBundle(
        answering: wantList,
        entries: [
          WatchArtworkBundle.Entry(
            cover: cover("a"), imageData: Data(repeating: 1, count: WatchArtworkReply.maxImageBytes + 1))
        ], unavailable: [], isFinal: true)
    }
    let entries = (0..<30).map {
      WatchArtworkBundle.Entry(cover: cover("\($0)"), imageData: Data(repeating: 1, count: 40 * 1024))
    }
    #expect(throws: WatchProtocolCodingError.tooLarge) {
      try WatchArtworkBundle(answering: wantList, entries: entries, unavailable: [], isFinal: true)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchArtworkBundle(
        answering: wantList, entries: [WatchArtworkBundle.Entry(cover: cover("a"), imageData: Data())],
        unavailable: [], isFinal: true)
    }
  }

  @Test func aFullBundleFitsTheReceivedFileLimit() throws {
    let wantList = try WatchArtworkWantList(accountStamp: phone, manifestID: nil, covers: [])
    let entries = (0..<(WatchArtworkSyncLimits.maxBundleImageBytes / (40 * 1024))).map {
      WatchArtworkBundle.Entry(cover: cover("\($0)"), imageData: Data(repeating: 0xAB, count: 40 * 1024))
    }
    let bundle = try WatchArtworkBundle(answering: wantList, entries: entries, unavailable: [], isFinal: false)
    #expect(try WatchWireCodec.encode(bundle).count <= WatchArtworkSyncLimits.maxReceivedFileBytes)
  }

  @Test func decodingRefusesURLsSmuggledAsRevisions() throws {
    let manifest = try WatchArtworkManifest(accountStamp: phone, authenticatedAccountStamp: nil, covers: [cover("a")])
    let encoded = try WatchWireCodec.encode(manifest)
    let tampered = Data(
      String(decoding: encoded, as: UTF8.self)
        .replacingOccurrences(of: "\"revision\":\"1\"", with: "\"revision\":\"https://server/cover\"").utf8)
    #expect(throws: (any Error).self) { try WatchWireCodec.decode(WatchArtworkManifest.self, from: tampered) }
  }
}
