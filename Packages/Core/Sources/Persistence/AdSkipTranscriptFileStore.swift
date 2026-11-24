import Foundation

/// One transcribed word. Persistence's own value type: this layer must not import `AdSkip`.
public struct StoredTranscriptWord: Sendable, Equatable {
  public let text: String
  public let start: Double
  public let end: Double

  public init(text: String, start: Double, end: Double) {
    self.text = text
    self.start = start
    self.end = end
  }
}

/// One detected silence: timestamps only, no content.
public struct StoredSilence: Sendable, Equatable {
  public let start: Double
  public let end: Double

  public init(start: Double, end: Double) {
    self.start = start
    self.end = end
  }
}

/// A stretch of the file that has been transcribed: times only.
public struct StoredTimeSpan: Sendable, Equatable {
  public let start: Double
  public let end: Double

  public init(start: Double, end: Double) {
    self.start = start
    self.end = end
  }
}

public struct StoredTranscript: Sendable, Equatable {
  public let words: [StoredTranscriptWord]
  public let silences: [StoredSilence]
  public let duration: Double
  /// The stretches the words were transcribed from. A whole-file transcript covers
  /// `[0, duration]`.
  public let coverage: [StoredTimeSpan]

  /// `coverage` nil means the whole file was transcribed.
  public init(
    words: [StoredTranscriptWord], silences: [StoredSilence], duration: Double,
    coverage: [StoredTimeSpan]? = nil
  ) {
    self.words = words
    self.silences = silences
    self.duration = duration
    self.coverage = coverage ?? [StoredTimeSpan(start: 0, end: duration)]
  }
}

/// Privacy-safe by construction: cases name the failure, never the content or the file name.
public enum AdSkipTranscriptFileStoreError: Error, Sendable, Equatable {
  case invalidFileName
  /// The file is missing or could not be read.
  case unreadable
  case badMagic
  case unsupportedVersion
  case truncated
  case trailingBytes
  case invalidText
}

/// Transcripts and audio prints as files, one of each per episode. A transcript is user content
/// and an audio print identifies a recording: neither is ever logged, put in diagnostics or
/// errors, or exported.
///
/// Binary format, little-endian throughout:
///
///     magic          4 bytes   "WTRX"
///     version        UInt16    3
///     duration       UInt64    Float64 bit pattern
///     wordCount      UInt32
///     per word:
///       start        UInt64    Float64 bit pattern
///       end          UInt64    Float64 bit pattern
///       textLength   UInt32    UTF-8 byte count
///       text         textLength bytes of UTF-8
///     silenceCount   UInt32
///     per silence:
///       start        UInt64    Float64 bit pattern
///       end          UInt64    Float64 bit pattern
///     coverageCount  UInt32                         (version 3 only)
///     per covered span:
///       start        UInt64    Float64 bit pattern
///       end          UInt64    Float64 bit pattern
///
/// Version 2 has no coverage and reads as covering the whole file. Version 1 (no silences) is
/// rejected as `unsupportedVersion`, so the episode is analysed again.
///
/// An audio print file (`<UUID>.aprint`) is the magic "WAPR", a UInt16 version 1, two zero bytes,
/// then the print's little-endian 32-bit words (4-byte aligned in a mapping).
///
/// Doubles travel as bit patterns so the ad arbiter, which re-scores from stored transcripts,
/// reproduces its results exactly (including -0.0 and subnormals).
///
/// Files are never overwritten: each `write` creates a new `<UUID>.words`, so a reader never sees
/// a partial file and callers swap references atomically in the database.
public struct AdSkipTranscriptFileStore: Sendable {
  public let rootURL: URL
  private let fileAttributes: FileAttributeApplying
  private let fileMover: DownloadFileMoving

  static let magic = Data("WTRX".utf8)
  static let formatVersion: UInt16 = 3
  /// The version without coverage, still read.
  static let wholeFileVersion: UInt16 = 2
  private static let fileExtension = "words"
  static let audioPrintMagic = Data("WAPR".utf8)
  static let audioPrintVersion: UInt16 = 1
  private static let audioPrintExtension = "aprint"
  private static let audioPrintHeaderSize = 8
  private static let temporaryPrefix = ".tmp-"
  /// start + end + textLength: the smallest an encoded word can be.
  private static let minimumWordSize = 8 + 8 + 4
  /// start + end: the size of an encoded silence.
  private static let silenceSize = 8 + 8

  /// Creates (if needed) and protects the root before any file is written into it, on every
  /// construction. The root shares the downloads posture (protected until first unlock,
  /// excluded from backup, via `protectDownloadsRoot` / `protectDownloadedFile`): transcripts are
  /// large, re-derivable and private.
  public init(
    rootURL: URL, fileAttributes: FileAttributeApplying,
    fileMover: DownloadFileMoving = POSIXDownloadFileMover()
  ) throws {
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try fileAttributes.protectDownloadsRoot(at: rootURL)
    self.rootURL = rootURL
    self.fileAttributes = fileAttributes
    self.fileMover = fileMover
  }

  /// Writes a new file and returns its name. Written under a temporary name inside the root,
  /// then moved into place, so a crash leaves only a temp file that `sweep` removes.
  public func write(_ transcript: StoredTranscript) throws -> String {
    try write(Self.encode(transcript), fileExtension: Self.fileExtension)
  }

  /// Writes a new audio print file from the print's little-endian words and returns its name.
  public func writeAudioPrint(littleEndianWords words: Data) throws -> String {
    var data = Data()
    data.append(Self.audioPrintMagic)
    data.appendLittleEndian(Self.audioPrintVersion)
    data.appendLittleEndian(UInt16(0))
    data.append(words)
    return try write(data, fileExtension: Self.audioPrintExtension)
  }

  private func write(_ data: Data, fileExtension: String) throws -> String {
    let name = "\(UUID().uuidString).\(fileExtension)"
    let temporaryURL = rootURL.appendingPathComponent(
      "\(Self.temporaryPrefix)\(UUID().uuidString)")
    let finalURL = rootURL.appendingPathComponent(name)
    do {
      try data.write(to: temporaryURL)
      try fileMover.moveItem(at: temporaryURL, to: finalURL)
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
    do {
      try fileAttributes.protectDownloadedFile(at: finalURL)
    } catch {
      try? FileManager.default.removeItem(at: finalURL)
      throw error
    }
    return name
  }

  public func read(fileName: String) throws -> StoredTranscript {
    guard Self.isValidFileName(fileName, fileExtension: Self.fileExtension) else {
      throw AdSkipTranscriptFileStoreError.invalidFileName
    }
    // Foundation's own error would carry the path, so it is replaced.
    guard let data = try? Data(contentsOf: rootURL.appendingPathComponent(fileName)) else {
      throw AdSkipTranscriptFileStoreError.unreadable
    }
    return try Self.decode(data)
  }

  /// An audio print's little-endian words, memory-mapped: matching reads every print in the
  /// library, and mapped pages are clean memory the system can drop.
  public func readAudioPrint(fileName: String) throws -> Data {
    guard Self.isValidFileName(fileName, fileExtension: Self.audioPrintExtension) else {
      throw AdSkipTranscriptFileStoreError.invalidFileName
    }
    guard
      let data = try? Data(
        contentsOf: rootURL.appendingPathComponent(fileName), options: .alwaysMapped)
    else { throw AdSkipTranscriptFileStoreError.unreadable }
    var reader = ByteReader(data: data.prefix(Self.audioPrintHeaderSize))
    guard try reader.bytes(Self.audioPrintMagic.count) == Self.audioPrintMagic else {
      throw AdSkipTranscriptFileStoreError.badMagic
    }
    guard try reader.uint16() == Self.audioPrintVersion, try reader.uint16() == 0 else {
      throw AdSkipTranscriptFileStoreError.unsupportedVersion
    }
    let words = data.dropFirst(Self.audioPrintHeaderSize)
    guard words.count % 4 == 0 else { throw AdSkipTranscriptFileStoreError.trailingBytes }
    return words
  }

  /// Missing files and names this store never generates are skipped silently.
  public func delete(fileNames: some Sequence<String>) {
    for name in fileNames
    where Self.isValidFileName(name, fileExtension: Self.fileExtension)
      || Self.isValidFileName(name, fileExtension: Self.audioPrintExtension)
    {
      try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(name))
    }
  }

  /// Removes every regular file in the root not named in `referenced` and last modified before
  /// `cutoff`, including leftover temporary files. Returns the number removed. A file `write` has
  /// produced but the database does not yet reference looks orphaned, so callers pass a cutoff far
  /// enough in the past to cover any write still waiting on its save.
  public func sweep(keeping referenced: Set<String>, modifiedBefore cutoff: Date) throws -> Int {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
    let entries = try FileManager.default.contentsOfDirectory(
      at: rootURL, includingPropertiesForKeys: Array(keys))
    var removed = 0
    for entry in entries where !referenced.contains(entry.lastPathComponent) {
      let values = try entry.resourceValues(forKeys: keys)
      guard values.isRegularFile == true,
        let modified = values.contentModificationDate, modified < cutoff
      else { continue }
      try FileManager.default.removeItem(at: entry)
      removed += 1
    }
    return removed
  }

  // MARK: - Names

  /// Only the exact shape `write` generates: canonical upper-case UUID plus the extension.
  static func isValidFileName(_ name: String, fileExtension: String = fileExtension) -> Bool {
    let suffix = ".\(fileExtension)"
    guard name.hasSuffix(suffix) else { return false }
    let stem = String(name.dropLast(suffix.count))
    guard let uuid = UUID(uuidString: stem) else { return false }
    return uuid.uuidString == stem
  }

  // MARK: - Codec

  static func encode(_ transcript: StoredTranscript) -> Data {
    var data = Data()
    data.append(magic)
    data.appendLittleEndian(formatVersion)
    data.appendLittleEndian(transcript.duration.bitPattern)
    precondition(transcript.words.count <= UInt32.max, "too many words to encode")
    data.appendLittleEndian(UInt32(transcript.words.count))
    for word in transcript.words {
      let text = Data(word.text.utf8)
      data.appendLittleEndian(word.start.bitPattern)
      data.appendLittleEndian(word.end.bitPattern)
      precondition(text.count <= UInt32.max, "word too long to encode")
      data.appendLittleEndian(UInt32(text.count))
      data.append(text)
    }
    precondition(transcript.silences.count <= UInt32.max, "too many silences to encode")
    data.appendLittleEndian(UInt32(transcript.silences.count))
    for silence in transcript.silences {
      data.appendLittleEndian(silence.start.bitPattern)
      data.appendLittleEndian(silence.end.bitPattern)
    }
    precondition(transcript.coverage.count <= UInt32.max, "too many spans to encode")
    data.appendLittleEndian(UInt32(transcript.coverage.count))
    for span in transcript.coverage {
      data.appendLittleEndian(span.start.bitPattern)
      data.appendLittleEndian(span.end.bitPattern)
    }
    return data
  }

  static func decode(_ data: Data) throws -> StoredTranscript {
    var reader = ByteReader(data: data)
    guard try reader.bytes(magic.count) == magic else {
      throw AdSkipTranscriptFileStoreError.badMagic
    }
    let version = try reader.uint16()
    guard version == formatVersion || version == wholeFileVersion else {
      throw AdSkipTranscriptFileStoreError.unsupportedVersion
    }
    let duration = Double(bitPattern: try reader.uint64())
    let count = Int(try reader.uint32())
    // Bound the allocation by what the remaining bytes could possibly hold.
    guard count <= reader.remaining / minimumWordSize else {
      throw AdSkipTranscriptFileStoreError.truncated
    }
    var words: [StoredTranscriptWord] = []
    words.reserveCapacity(count)
    for _ in 0..<count {
      let start = Double(bitPattern: try reader.uint64())
      let end = Double(bitPattern: try reader.uint64())
      let length = Int(try reader.uint32())
      guard let text = String(data: try reader.bytes(length), encoding: .utf8) else {
        throw AdSkipTranscriptFileStoreError.invalidText
      }
      words.append(StoredTranscriptWord(text: text, start: start, end: end))
    }
    let silenceCount = Int(try reader.uint32())
    guard silenceCount <= reader.remaining / silenceSize else {
      throw AdSkipTranscriptFileStoreError.truncated
    }
    var silences: [StoredSilence] = []
    silences.reserveCapacity(silenceCount)
    for _ in 0..<silenceCount {
      let start = Double(bitPattern: try reader.uint64())
      let end = Double(bitPattern: try reader.uint64())
      silences.append(StoredSilence(start: start, end: end))
    }
    var coverage: [StoredTimeSpan]?
    if version == formatVersion {
      let spanCount = Int(try reader.uint32())
      guard spanCount <= reader.remaining / silenceSize else {
        throw AdSkipTranscriptFileStoreError.truncated
      }
      var spans: [StoredTimeSpan] = []
      spans.reserveCapacity(spanCount)
      for _ in 0..<spanCount {
        let start = Double(bitPattern: try reader.uint64())
        let end = Double(bitPattern: try reader.uint64())
        spans.append(StoredTimeSpan(start: start, end: end))
      }
      coverage = spans
    }
    guard reader.remaining == 0 else { throw AdSkipTranscriptFileStoreError.trailingBytes }
    return StoredTranscript(words: words, silences: silences, duration: duration, coverage: coverage)
  }
}

private struct ByteReader {
  private let data: Data
  private var offset: Int

  init(data: Data) {
    self.data = Data(data)  // re-base indices to zero for slices
    self.offset = 0
  }

  var remaining: Int { data.count - offset }

  mutating func bytes(_ count: Int) throws -> Data {
    guard count >= 0, count <= remaining else { throw AdSkipTranscriptFileStoreError.truncated }
    defer { offset += count }
    return data.subdata(in: offset..<offset + count)
  }

  mutating func uint16() throws -> UInt16 {
    try integer(UInt16.self)
  }

  mutating func uint32() throws -> UInt32 {
    try integer(UInt32.self)
  }

  mutating func uint64() throws -> UInt64 {
    try integer(UInt64.self)
  }

  private mutating func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
    let slice = try bytes(MemoryLayout<T>.size)
    var value: T = 0
    for (index, byte) in slice.enumerated() {
      value |= T(byte) << (8 * index)
    }
    return value
  }
}

extension Data {
  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var little = value.littleEndian
    Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
  }
}
