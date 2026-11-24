import Compression
import Foundation
import Persistence

/// The optional learned-ads section of a podcast backup (learned-ad backup plan, Phase A).
///
/// Sits under snapshot version 1 as a key older builds ignore. Shingle hashes and audio prints
/// only, never transcript text (SECURITY rule 20).
public struct LearnedAdsSnapshot: Codable, Sendable, Equatable {
  /// Names the audio print algorithm and its parameters. A build whose own differs keeps the
  /// hashes and drops the prints, which it could not match against.
  public let printFormat: String
  /// How `blob` is compressed. Only `PodcastLearnedAdsSnapshotCodec.compression` is read.
  public let compression: String
  public let ads: [LearnedAdSnapshot]
  /// Each ad's hashes and then its print, in `ads` order, compressed as one stream. The same
  /// creative is often stored under several ads, and one stream pays for its audio once, where
  /// compressing each print alone cannot.
  public let blob: Data

  public init(printFormat: String, compression: String, ads: [LearnedAdSnapshot], blob: Data) {
    self.printFormat = printFormat
    self.compression = compression
    self.ads = ads
    self.blob = blob
  }

  /// A section with no blob is not one this build can read. It decodes as empty, so the podcast
  /// state beside it still restores.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    printFormat = try container.decode(String.self, forKey: .printFormat)
    guard let blob = try container.decodeIfPresent(Data.self, forKey: .blob) else {
      compression = PodcastLearnedAdsSnapshotCodec.compression
      ads = []
      self.blob = Data()
      return
    }
    self.blob = blob
    compression = try container.decode(String.self, forKey: .compression)
    ads = try container.decode([LearnedAdSnapshot].self, forKey: .ads)
  }
}

public struct LearnedAdSnapshot: Codable, Sendable, Equatable {
  /// `learned` or `tombstone`.
  public let kind: String
  public let lastSeen: Date
  public let start: Double
  public let end: Double
  /// The ad's 64-bit hashes in the blob: little-endian, strictly ascending.
  public let hashCount: Int
  /// The bytes of the ad's audio print in the blob, as little-endian 32-bit words. Nil when the
  /// ad travels without one. Learned ads only.
  public let printBytes: Int?
  public let teachers: [LearnedAdTeacherSnapshot]
  /// A listener's mark taught the ad, so the store keeps it. Absent in a file an older build made
  /// and written only when true, so such a build still reads the file and ignores the key.
  public let confirmed: Bool?

  public init(
    kind: String, lastSeen: Date, start: Double, end: Double, hashCount: Int, printBytes: Int?,
    teachers: [LearnedAdTeacherSnapshot], confirmed: Bool = false
  ) {
    self.kind = kind
    self.lastSeen = lastSeen
    self.start = start
    self.end = end
    self.hashCount = hashCount
    self.printBytes = printBytes
    self.teachers = teachers
    self.confirmed = confirmed ? true : nil
  }
}

public struct LearnedAdTeacherSnapshot: Codable, Sendable, Equatable {
  public let subscriptionUUID: UUID
  public let identityKey: String

  public init(subscriptionUUID: UUID, identityKey: String) {
    self.subscriptionUUID = subscriptionUUID
    self.identityKey = identityKey
  }
}

public enum PodcastLearnedAdsSnapshotCodec {
  public static let compression = "lzma"
  public static let maxAds = 20_000
  public static let maxHashesPerAd = 20_000
  public static let maxTeachersPerAd = 256
  public static let maxPrintBytes = 1024 * 1024
  /// The most the blob may hold before compression. It bounds what reading a section allocates,
  /// whatever its compressed bytes claim.
  public static let maxBlobBytes = 64 * 1024 * 1024
  /// What the section may add to the file. The whole file's limit is the snapshot codec's 32 MiB;
  /// the rest is left for the podcast state and the envelope's escaping.
  public static let sectionByteBudget = 24 * 1024 * 1024

  public struct Section: Sendable, Equatable {
    public let snapshot: LearnedAdsSnapshot?
    /// Learned ads written without their audio print, to stay inside the budget or because the
    /// print was too large. They still match by hash.
    public let adsWithoutPrint: Int
    /// Ads left out altogether, least recently seen first.
    public let adsDropped: Int
  }

  /// Most recently seen first. Past the budget, the remaining ads lose their prints; past it
  /// again, they are dropped. `parents` maps a feed address to its subscription.
  public static func section(
    from ads: [NativePodcastBackupContents.LearnedAd], printFormat: String, parents: [String: UUID],
    byteBudget: Int = sectionByteBudget
  ) -> Section {
    let ordered = ads.filter { $0.hashes.isEmpty == false && $0.hashes.count <= maxHashesPerAd }
      .map { (ad: $0, hashes: pack($0.hashes)) }
      .sorted { lhs, rhs in
        lhs.ad.lastSeen != rhs.ad.lastSeen
          ? lhs.ad.lastSeen > rhs.ad.lastSeen : lhs.hashes.lexicographicallyPrecedes(rhs.hashes)
      }
      .prefix(maxAds)
    // The compressed size is only known once the stream is written, so the selection is made
    // against an allowance of uncompressed bytes, which shrinks until the result fits.
    var allowance = maxBlobBytes
    while true {
      let draft = selection(from: ordered, parents: parents, allowance: allowance)
      guard draft.ads.isEmpty == false, let blob = compress(draft.blob) else {
        return Section(snapshot: nil, adsWithoutPrint: 0, adsDropped: ads.count)
      }
      let encoded = draft.used - draft.blob.count + (blob.count + 2) / 3 * 4
      if encoded <= byteBudget {
        return Section(
          snapshot: LearnedAdsSnapshot(printFormat: printFormat, compression: compression, ads: draft.ads, blob: blob),
          adsWithoutPrint: draft.withoutPrint, adsDropped: ads.count - draft.ads.count)
      }
      let scaled = Double(draft.used) * Double(max(0, byteBudget)) / Double(encoded) * 0.9
      allowance = min(Int(scaled), draft.used - 1)
    }
  }

  private struct Selection {
    var ads: [LearnedAdSnapshot] = []
    var blob = Data()
    /// The blob's bytes and an upper estimate of the ads' own JSON.
    var used = 0
    var withoutPrint = 0
  }

  private static func selection(
    from ordered: some Sequence<(ad: NativePodcastBackupContents.LearnedAd, hashes: Data)>, parents: [String: UUID],
    allowance: Int
  ) -> Selection {
    var selection = Selection()
    var printsAllowed = true
    for (ad, hashes) in ordered {
      let teachers = ad.teachers.compactMap { teacher -> LearnedAdTeacherSnapshot? in
        guard let uuid = parents[teacher.feedURL], teacher.identityKey.isEmpty == false,
          teacher.identityKey.utf8.count <= PodcastStateSnapshotCodec.maxStringBytes
        else { return nil }
        return LearnedAdTeacherSnapshot(subscriptionUUID: uuid, identityKey: teacher.identityKey)
      }
      .sorted {
        ($0.subscriptionUUID.uuidString, $0.identityKey) < ($1.subscriptionUUID.uuidString, $1.identityKey)
      }
      .prefix(maxTeachersPerAd)
      // Every quote in an ad's JSON is escaped again inside the envelope's string.
      let fixed = hashes.count + 320 + teachers.reduce(0) { $0 + 160 + $1.identityKey.utf8.count * 2 }
      var print: Data?
      if ad.kind == .learned, let raw = ad.audioPrint, raw.isEmpty == false, raw.count % 4 == 0,
        raw.count <= maxPrintBytes
      {
        if printsAllowed, selection.used + fixed + raw.count <= allowance {
          print = raw
        } else {
          printsAllowed = false
        }
      }
      let cost = fixed + (print?.count ?? 0)
      guard selection.used + cost <= allowance else { break }
      selection.used += cost
      if ad.kind == .learned, print == nil, ad.audioPrint != nil { selection.withoutPrint += 1 }
      selection.blob.append(hashes)
      if let print { selection.blob.append(print) }
      selection.ads.append(
        LearnedAdSnapshot(
          kind: ad.kind.rawValue, lastSeen: ad.lastSeen, start: ad.startTime, end: ad.endTime,
          hashCount: hashes.count / 8, printBytes: print?.count, teachers: Array(teachers),
          confirmed: ad.kind == .learned && ad.confirmed))
    }
    return selection
  }

  /// The restore writer's input. Prints are kept only when the section's print format is this
  /// build's. `addresses` maps a subscription to the feed address the restore knows it by. A blob
  /// that is not exactly what the ads describe yields no ads.
  public static func learnedAds(
    from section: LearnedAdsSnapshot, printFormat: String, addresses: [UUID: String]
  ) -> [NativePodcastBackupContents.LearnedAd] {
    guard section.compression == compression, let size = blobBytes(of: section.ads), size > 0,
      let blob = decompress(section.blob, expecting: size)
    else { return [] }
    var offset = 0
    return section.ads.compactMap { ad in
      let hashes = blob.subdata(in: offset..<(offset + ad.hashCount * 8))
      offset += hashes.count
      let print = ad.printBytes.map { blob.subdata(in: offset..<(offset + $0)) }
      offset += print?.count ?? 0
      guard let kind = AdSignatureKind(rawValue: ad.kind), let hashes = unpack(hashes) else { return nil }
      return NativePodcastBackupContents.LearnedAd(
        kind: kind, lastSeen: ad.lastSeen, startTime: ad.start, endTime: ad.end, hashes: hashes,
        audioPrint: kind == .learned && section.printFormat == printFormat ? print : nil,
        teachers: Set(
          ad.teachers.compactMap { teacher in
            addresses[teacher.subscriptionUUID].map { .init(feedURL: $0, identityKey: teacher.identityKey) }
          }),
        confirmed: ad.confirmed == true)
    }
  }

  static func validate(_ section: LearnedAdsSnapshot) throws {
    guard section.ads.count <= maxAds, section.printFormat.utf8.count <= 256, section.compression == compression,
      section.blob.count <= sectionByteBudget
    else { throw PodcastStateSnapshotCodecError.invalidValue }
    for ad in section.ads {
      guard let kind = AdSignatureKind(rawValue: ad.kind), ad.lastSeen.timeIntervalSince1970.isFinite,
        ad.start.isFinite, ad.end.isFinite, ad.start >= 0, ad.start < ad.end,
        (1...maxHashesPerAd).contains(ad.hashCount), ad.teachers.count <= maxTeachersPerAd
      else { throw PodcastStateSnapshotCodecError.invalidValue }
      if let bytes = ad.printBytes {
        guard kind == .learned, bytes > 0, bytes % 4 == 0, bytes <= maxPrintBytes else {
          throw PodcastStateSnapshotCodecError.invalidValue
        }
      }
      for teacher in ad.teachers {
        guard teacher.identityKey.isEmpty == false else { throw PodcastStateSnapshotCodecError.invalidValue }
        guard teacher.identityKey.utf8.count <= PodcastStateSnapshotCodec.maxStringBytes else {
          throw PodcastStateSnapshotCodecError.oversizedString
        }
      }
    }
    guard blobBytes(of: section.ads) != nil else { throw PodcastStateSnapshotCodecError.invalidValue }
  }

  /// The uncompressed blob the ads describe, or nil past `maxBlobBytes`. Each ad is within its
  /// own limits once `validate` has passed.
  private static func blobBytes(of ads: [LearnedAdSnapshot]) -> Int? {
    var total = 0
    for ad in ads {
      guard (1...maxHashesPerAd).contains(ad.hashCount), (0...maxPrintBytes).contains(ad.printBytes ?? 0) else {
        return nil
      }
      total += ad.hashCount * 8 + (ad.printBytes ?? 0)
      guard total <= maxBlobBytes else { return nil }
    }
    return total
  }

  static func pack(_ hashes: Set<UInt64>) -> Data {
    var data = Data(capacity: hashes.count * 8)
    for hash in hashes.sorted() {
      withUnsafeBytes(of: hash.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }

  /// Nil unless the bytes are a non-empty, strictly ascending list within the per-ad limit, which
  /// is the one form `pack` writes.
  static func unpack(_ data: Data) -> Set<UInt64>? {
    guard data.isEmpty == false, data.count % 8 == 0, data.count / 8 <= maxHashesPerAd else { return nil }
    var hashes: Set<UInt64> = []
    hashes.reserveCapacity(data.count / 8)
    var previous: UInt64?
    for offset in stride(from: 0, to: data.count, by: 8) {
      var value: UInt64 = 0
      for byte in 0..<8 { value |= UInt64(data[data.startIndex + offset + byte]) << (8 * UInt64(byte)) }
      if let previous, value <= previous { return nil }
      previous = value
      hashes.insert(value)
    }
    return hashes
  }

  static func compress(_ data: Data) -> Data? {
    guard data.isEmpty == false else { return nil }
    // Incompressible input grows by a container header and a little per block.
    var output = Data(count: data.count + data.count / 8 + 4096)
    let capacity = output.count
    let written = output.withUnsafeMutableBytes { destination in
      data.withUnsafeBytes { source in
        compression_encode_buffer(
          destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZMA)
      }
    }
    guard written > 0 else { return nil }
    output.count = written
    return output
  }

  /// Nil unless the data decompresses to exactly `size` bytes. The buffer is one byte larger, so
  /// a stream that would expand further is seen and refused without being followed.
  static func decompress(_ data: Data, expecting size: Int) -> Data? {
    guard data.isEmpty == false, size > 0, size <= maxBlobBytes else { return nil }
    var output = Data(count: size + 1)
    let written = output.withUnsafeMutableBytes { destination in
      data.withUnsafeBytes { source in
        compression_decode_buffer(
          destination.bindMemory(to: UInt8.self).baseAddress!, size + 1,
          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZMA)
      }
    }
    guard written == size else { return nil }
    output.count = size
    return output
  }
}
