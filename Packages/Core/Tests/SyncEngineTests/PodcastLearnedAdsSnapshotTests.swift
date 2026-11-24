import Foundation
import Persistence
import Testing

@testable import SyncEngine

/// The learned-ads section of the podcast backup file (learned-ad backup plan, Phase A).
@Suite struct PodcastLearnedAdsSnapshotTests {
  private typealias Contents = NativePodcastBackupContents
  private typealias Seed = PodcastBackupSnapshotMappingTests
  private typealias Codec = PodcastLearnedAdsSnapshotCodec

  private static let feed = "https://example.com/feed"
  private static let format = "fp-test"

  /// Incompressible, so a budget test can count on its size.
  private static func print(_ seed: UInt64, bytes: Int = 4096) -> Data {
    var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    return Data(
      (0..<bytes).map { _ in
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return UInt8(truncatingIfNeeded: state >> 24)
      })
  }

  private static func ad(
    _ seed: UInt64, kind: AdSignatureKind = .learned, lastSeen: TimeInterval = 500, print: Data? = nil,
    teachers: Set<Contents.LearnedAd.Teacher> = [.init(feedURL: feed, identityKey: "zero")],
    confirmed: Bool = false
  ) -> Contents.LearnedAd {
    Contents.LearnedAd(
      kind: kind, lastSeen: Seed.date(lastSeen), startTime: 10, endTime: 40,
      hashes: [seed, seed &+ 1, UInt64.max &- seed], audioPrint: kind == .learned ? print : nil, teachers: teachers,
      confirmed: confirmed)
  }

  private static func contents(_ ads: [Contents.LearnedAd]) -> Contents {
    var contents = Seed.contents()
    contents.learnedAds = ads
    return contents
  }

  private static func file(_ contents: Contents, budget: Int = Codec.sectionByteBudget) throws -> Data {
    try PodcastStateSnapshotCodec.encodeWrapped(
      PodcastBackupSnapshotMapping.snapshot(
        from: contents, exportedAt: Seed.date(900), learnedAdPrintFormat: format, learnedAdByteBudget: budget
      ).snapshot)
  }

  private static func restored(_ file: Data, format: String = format) throws -> [Contents.LearnedAd] {
    PodcastBackupSnapshotMapping.contents(
      from: try PodcastStateSnapshotCodec.decodeWrapped(file), learnedAdPrintFormat: format
    ).learnedAds
  }

  @Test func learnedAdsSurviveTheFileRoundTrip() throws {
    let ads = [
      Self.ad(10, lastSeen: 700, print: Self.print(1)),
      Self.ad(20, kind: .tombstone, lastSeen: 600),
      Self.ad(30, lastSeen: 500, print: nil, teachers: []),
    ]
    let restored = try Self.restored(Self.file(Self.contents(ads)))
    #expect(restored == ads)
  }

  /// The listener's own ads stay theirs on another device, and a file written before the field
  /// existed reads as unconfirmed.
  @Test func aConfirmedAdSurvivesTheFileAndAnOlderFileReadsAsUnconfirmed() throws {
    let ads = [Self.ad(10, confirmed: true), Self.ad(20)]
    let file = try Self.file(Self.contents(ads))
    #expect(try Self.restored(file).map(\.confirmed).sorted { $0 && !$1 } == [true, false])

    let plain = try Self.file(Self.contents([Self.ad(20)]))
    #expect(String(decoding: plain, as: UTF8.self).contains("confirmed") == false)
    #expect(try Self.restored(plain).map(\.confirmed) == [false])
  }

  @Test func aBackupWithoutLearnedAdsIsTheFileItAlwaysWas() throws {
    let plain = try PodcastStateSnapshotCodec.encodeWrapped(
      PodcastBackupSnapshotMapping.snapshot(from: Seed.contents(), exportedAt: Seed.date(900)).snapshot)
    #expect(try Self.file(Seed.contents()) == plain)
    #expect(String(decoding: plain, as: UTF8.self).contains("learnedAds") == false)
  }

  /// What a build from before the section does with it: its decoder knows only the old keys.
  @Test func aBuildThatDoesNotKnowTheSectionReadsTheRest() throws {
    struct Envelope: Decodable { let payload: String }
    struct Before: Decodable {
      let version: Int
      let subscriptions: [SubscriptionSnapshot]
      let episodes: [EpisodeSnapshot]
    }
    let file = try Self.file(Self.contents([Self.ad(10, print: Self.print(1))]))
    let payload = try JSONDecoder().decode(Envelope.self, from: file).payload
    #expect(payload.contains("\"learnedAds\""))
    let before = try JSONDecoder().decode(Before.self, from: Data(payload.utf8))
    #expect(before.version == 1 && before.subscriptions.count == 1 && before.episodes.count == 3)
  }

  @Test func identicalStoresProduceIdenticalFiles() throws {
    let ads = (1...40).map { Self.ad(UInt64($0) * 100, lastSeen: 500, print: Self.print(UInt64($0), bytes: 64)) }
    #expect(try Self.file(Self.contents(ads)) == Self.file(Self.contents(ads.reversed())))
  }

  /// Past the budget the least recently seen ads lose their prints first, then are left out.
  @Test func theBudgetDropsPrintsThenAdsOldestFirst() throws {
    let ads = (1...6).map {
      Self.ad(UInt64($0) * 100, lastSeen: TimeInterval(100 * $0), print: Self.print(UInt64($0)), teachers: [])
    }
    let parents = [Self.feed: UUID()]
    let all = Codec.section(from: ads, printFormat: Self.format, parents: parents)
    #expect(all.adsDropped == 0 && all.adsWithoutPrint == 0)

    let tight = Codec.section(from: ads, printFormat: Self.format, parents: parents, byteBudget: 13_000)
    let written = try #require(tight.snapshot?.ads)
    let withPrint = written.prefix { $0.printBytes != nil }.count
    #expect(written.map(\.lastSeen) == written.map(\.lastSeen).sorted(by: >))
    #expect(written.first?.lastSeen == Seed.date(600))
    #expect((1..<ads.count).contains(withPrint))
    #expect(written.dropFirst(withPrint).allSatisfy { $0.printBytes == nil })
    #expect(tight.adsWithoutPrint == written.count - withPrint)

    let tighter = Codec.section(from: ads, printFormat: Self.format, parents: parents, byteBudget: 1_500)
    let kept = try #require(tighter.snapshot?.ads)
    #expect(kept.allSatisfy { $0.printBytes == nil } && kept.first?.lastSeen == Seed.date(600))
    #expect(tighter.adsDropped == ads.count - kept.count && tighter.adsDropped > 0)

    let none = Codec.section(from: ads, printFormat: Self.format, parents: parents, byteBudget: 0)
    #expect(none.snapshot == nil && none.adsDropped == ads.count)
  }

  @Test func theEstimateCoversTheBytesTheSectionAdds() throws {
    let ads = (1...30).map {
      Self.ad(UInt64($0) * 100, lastSeen: TimeInterval($0), print: Self.print(UInt64($0), bytes: 8192))
    }
    let budget = 100_000
    let grown = try Self.file(Self.contents(ads), budget: budget).count - Self.file(Seed.contents()).count
    #expect(grown > budget / 2 && grown <= budget)
  }

  /// Another build's prints cannot be matched against; the hashes still can.
  @Test func aDifferentPrintFormatKeepsTheAdAndDropsItsPrint() throws {
    let ad = Self.ad(10, print: Self.print(1))
    let restored = try Self.restored(Self.file(Self.contents([ad])), format: "fp-other")
    var expected = ad
    expected.audioPrint = nil
    #expect(restored == [expected])
  }

  @Test func aTeacherOfAShowTheFileDoesNotFollowIsLeftOut() throws {
    let ad = Self.ad(
      10,
      teachers: [
        .init(feedURL: Self.feed, identityKey: "zero"), .init(feedURL: "https://example.com/other", identityKey: "x"),
      ])
    let restored = try Self.restored(Self.file(Self.contents([ad])))
    #expect(restored.first?.teachers == [.init(feedURL: Self.feed, identityKey: "zero")])
  }

  @Test func aSectionOutsideItsLimitsMakesTheFileUnreadable() throws {
    let base = try PodcastBackupSnapshotMapping.snapshot(from: Seed.contents(), exportedAt: Seed.date(900)).snapshot
    func snapshot(_ ad: LearnedAdSnapshot) -> PodcastStateSnapshot {
      PodcastStateSnapshot(
        exportedAt: base.exportedAt, globalSettings: base.globalSettings, subscriptions: base.subscriptions,
        lastPlayed: base.lastPlayed, episodeIdentities: base.episodeIdentities, episodes: base.episodes,
        learnedAds: LearnedAdsSnapshot(
          printFormat: Self.format, compression: Codec.compression, ads: [ad], blob: Data([0])))
    }
    func ad(
      kind: String = "learned", start: Double = 10, hashCount: Int = 2, printBytes: Int? = nil
    ) -> LearnedAdSnapshot {
      LearnedAdSnapshot(
        kind: kind, lastSeen: Seed.date(500), start: start, end: 40, hashCount: hashCount, printBytes: printBytes,
        teachers: [])
    }
    try PodcastStateSnapshotCodec.validate(snapshot(ad()))
    let invalid = [
      ad(kind: "other"), ad(start: 50), ad(start: .nan), ad(hashCount: 0), ad(hashCount: Codec.maxHashesPerAd + 1),
      ad(kind: "tombstone", printBytes: 4), ad(printBytes: 0), ad(printBytes: 6),
      ad(printBytes: Codec.maxPrintBytes + 4),
    ]
    for ad in invalid {
      #expect(throws: PodcastStateSnapshotCodecError.invalidValue) {
        try PodcastStateSnapshotCodec.validate(snapshot(ad))
      }
    }
  }

  /// The store keeps a creative once for each episode that taught it. One stream pays for its
  /// audio once.
  @Test func aCreativeStoredUnderManyAdsIsPaidForOnce() throws {
    let creative = Self.print(1, bytes: 32 * 1024)
    let ads = (1...20).map { Self.ad(UInt64($0) * 100, lastSeen: TimeInterval($0), print: creative) }
    let file = try Self.file(Self.contents(ads))
    #expect(file.count - (try Self.file(Seed.contents()).count) < 2 * creative.count)
    #expect(try Self.restored(file).allSatisfy { $0.audioPrint == creative })
  }

  /// A blob is trusted only when it is exactly what the ads describe.
  @Test func aBlobThatIsNotWhatTheAdsDescribeYieldsNoAds() throws {
    func ads(hashCount: Int = 1, printBytes: Int? = 4, compression: String = Codec.compression, blob: Data)
      -> [Contents.LearnedAd]
    {
      Codec.learnedAds(
        from: LearnedAdsSnapshot(
          printFormat: Self.format, compression: compression,
          ads: [
            LearnedAdSnapshot(
              kind: "learned", lastSeen: Seed.date(500), start: 10, end: 40, hashCount: hashCount,
              printBytes: printBytes, teachers: [])
          ], blob: blob), printFormat: Self.format, addresses: [:])
    }
    let blob = try #require(Codec.compress(Codec.pack([7]) + Data([1, 0, 0, 0])))
    #expect(ads(blob: blob).map(\.hashes) == [[7]])
    #expect(ads(blob: blob).first?.audioPrint == Data([1, 0, 0, 0]))
    #expect(ads(printBytes: 8, blob: blob).isEmpty)
    #expect(ads(printBytes: nil, blob: blob).isEmpty)
    #expect(ads(compression: "other", blob: blob).isEmpty)
    #expect(ads(blob: Data([1, 2, 3, 4])).isEmpty)
    // A megabyte of zeros behind a few hundred bytes: refused at the first byte past the claim.
    let bomb = try #require(Codec.compress(Data(count: 1024 * 1024)))
    #expect(bomb.count < 4096 && ads(blob: bomb).isEmpty)
    #expect(Codec.decompress(bomb, expecting: 1024 * 1024) == Data(count: 1024 * 1024))
    // Hashes out of order are not a set this build wrote.
    let unordered = try #require(Codec.compress(Codec.pack([2]) + Codec.pack([1])))
    #expect(ads(hashCount: 2, printBytes: nil, blob: unordered).isEmpty)
  }

  /// A section in a shape this build does not read costs the ads, not the podcast state.
  @Test func aSectionWithoutABlobReadsAsEmpty() throws {
    let plain = try PodcastStateSnapshotCodec.encode(
      PodcastBackupSnapshotMapping.snapshot(from: Seed.contents(), exportedAt: Seed.date(900)).snapshot)
    var object = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
    object["learnedAds"] = ["printFormat": Self.format, "ads": [["kind": "learned", "hashes": "AAAA"]]]
    let decoded = try PodcastStateSnapshotCodec.decode(JSONSerialization.data(withJSONObject: object))
    #expect(decoded.learnedAds?.ads.isEmpty == true && decoded.subscriptions.count == 1)
    #expect(PodcastBackupSnapshotMapping.contents(from: decoded, learnedAdPrintFormat: Self.format).learnedAds.isEmpty)
  }
}
