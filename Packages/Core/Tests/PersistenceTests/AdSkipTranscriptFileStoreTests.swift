import Foundation
import TestSupport
import Testing

@testable import Persistence

@Suite struct AdSkipTranscriptFileStoreTests {
  private typealias Store = AdSkipTranscriptFileStore
  private typealias StoreError = AdSkipTranscriptFileStoreError

  // MARK: - Codec

  @Test func roundTripsEmptyTranscript() throws {
    let transcript = StoredTranscript(words: [], silences: [], duration: 0)
    #expect(try Store.decode(Store.encode(transcript)) == transcript)
  }

  @Test func roundTripsNonASCIIText() throws {
    let transcript = StoredTranscript(
      words: [
        StoredTranscriptWord(text: "café", start: 0, end: 1),
        StoredTranscriptWord(text: "👩🏽‍🚀", start: 1, end: 2),
        StoredTranscriptWord(text: "", start: 2, end: 2.5),
      ], silences: [], duration: 3)
    #expect(try Store.decode(Store.encode(transcript)) == transcript)
  }

  @Test func roundTripsDoublesBitExactly() throws {
    let values: [Double] = [0.1, 1e-300, .greatestFiniteMagnitude, -0.0, 5e-324, 123.456789012345]
    let words = values.map { StoredTranscriptWord(text: "w", start: $0, end: $0) }
    let silences = values.map { StoredSilence(start: $0, end: $0) }
    let transcript = StoredTranscript(words: words, silences: silences, duration: -0.0)
    let decoded = try Store.decode(Store.encode(transcript))
    #expect(decoded.duration.bitPattern == (-0.0).bitPattern)
    #expect(decoded.silences.count == silences.count)
    for (original, restored) in zip(silences, decoded.silences) {
      #expect(restored.start.bitPattern == original.start.bitPattern)
      #expect(restored.end.bitPattern == original.end.bitPattern)
    }
    for (original, restored) in zip(words, decoded.words) {
      #expect(restored.start.bitPattern == original.start.bitPattern)
      #expect(restored.end.bitPattern == original.end.bitPattern)
    }
  }

  @Test func roundTripsSilences() throws {
    let transcript = StoredTranscript(
      words: [word("a")],
      silences: [StoredSilence(start: 1, end: 2.5), StoredSilence(start: 7.25, end: 8)],
      duration: 9)
    #expect(try Store.decode(Store.encode(transcript)) == transcript)
  }

  @Test func decodeRejectsVersionOne() throws {
    var data = Store.encode(sample)
    data[Store.magic.count] = 1
    #expect(throws: StoreError.unsupportedVersion) { try Store.decode(data) }
  }

  @Test func decodeRejectsTruncatedSilenceSection() throws {
    let data = Store.encode(
      StoredTranscript(words: [], silences: [StoredSilence(start: 1, end: 2)], duration: 1))
    // Cut one byte off the final covered span's end time.
    #expect(throws: StoreError.truncated) { try Store.decode(data.dropLast()) }
    // Claim more silences than the bytes hold.
    var inflated = data
    let countOffset = data.count - Self.coverageTail - 16 - 4
    inflated.replaceSubrange(countOffset..<countOffset + 4, with: [0xFF, 0xFF, 0xFF, 0x7F])
    #expect(throws: StoreError.truncated) { try Store.decode(inflated) }
  }

  /// A whole-file transcript's coverage section: a count and one span.
  private static let coverageTail = 4 + 16

  @Test func roundTripsCoverage() throws {
    let transcript = StoredTranscript(
      words: [word("a")], silences: [StoredSilence(start: 1, end: 2)], duration: 600,
      coverage: [StoredTimeSpan(start: 10, end: 70), StoredTimeSpan(start: 300, end: 400.5)])
    #expect(try Store.decode(Store.encode(transcript)) == transcript)
    let empty = StoredTranscript(words: [], silences: [], duration: 600, coverage: [])
    #expect(try Store.decode(Store.encode(empty)).coverage.isEmpty)
  }

  @Test func readsVersionTwoAsCoveringTheWholeFile() throws {
    // A version 2 file is version 3 without the coverage section.
    var data = Store.encode(sample).dropLast(Self.coverageTail)
    data[data.startIndex + Store.magic.count] = 2
    let decoded = try Store.decode(Data(data))
    #expect(decoded.words == sample.words)
    #expect(decoded.silences == sample.silences)
    #expect(decoded.coverage == [StoredTimeSpan(start: 0, end: sample.duration)])
  }

  @Test func decodeRejectsWrongMagic() throws {
    var data = Store.encode(sample)
    data[0] ^= 0xFF
    #expect(throws: StoreError.badMagic) { try Store.decode(data) }
  }

  @Test func decodeRejectsUnknownVersion() throws {
    var data = Store.encode(sample)
    data[Store.magic.count] = 4
    #expect(throws: StoreError.unsupportedVersion) { try Store.decode(data) }
  }

  @Test func decodeRejectsTruncationAtEveryLength() throws {
    let data = Store.encode(sample)
    for length in 0..<data.count {
      #expect(throws: StoreError.self) { try Store.decode(data.prefix(length)) }
    }
  }

  @Test func decodeRejectsTrailingBytes() throws {
    var data = Store.encode(sample)
    data.append(0)
    #expect(throws: StoreError.trailingBytes) { try Store.decode(data) }
  }

  @Test func decodeRejectsTextLengthOverrun() throws {
    var data = Store.encode(StoredTranscript(words: [word("ab")], silences: [], duration: 1))
    // Before the 4-byte silence count: u32 length then 2 text bytes. Inflate the length.
    let lengthOffset = data.count - Self.coverageTail - 4 - 2 - 4
    data.replaceSubrange(lengthOffset..<lengthOffset + 4, with: [0xFF, 0xFF, 0xFF, 0x7F])
    #expect(throws: StoreError.truncated) { try Store.decode(data) }
  }

  @Test func decodeRejectsHugeWordCountWithoutAllocating() throws {
    var data = Store.encode(StoredTranscript(words: [], silences: [], duration: 1))
    let countOffset = data.count - Self.coverageTail - 4 - 4
    data.replaceSubrange(countOffset..<countOffset + 4, with: [0xFF, 0xFF, 0xFF, 0xFF])
    #expect(throws: StoreError.truncated) { try Store.decode(data) }
  }

  @Test func decodeRejectsInvalidUTF8() throws {
    var data = Store.encode(StoredTranscript(words: [word("ab")], silences: [], duration: 1))
    data[data.count - Self.coverageTail - 4 - 2] = 0xFF
    data[data.count - Self.coverageTail - 4 - 1] = 0xFE
    #expect(throws: StoreError.invalidText) { try Store.decode(data) }
  }

  @Test func errorsNeverCarryTranscriptText() {
    #expect(!String(describing: StoreError.invalidText).contains("secret"))
    #expect(!String(describing: StoreError.invalidFileName).contains("secret"))
  }

  // MARK: - Store

  @Test func writeThenReadRoundTripsAndNamesAreUnique() throws {
    let (store, _, cleanup) = try makeStore()
    defer { cleanup() }
    let first = try store.write(sample)
    let second = try store.write(sample)
    #expect(first != second)
    #expect(first.hasSuffix(".words"))
    #expect(try store.read(fileName: first) == sample)
    #expect(try store.read(fileName: second) == sample)
  }

  @Test func rootIsProtectedBeforeAnyFileAndEachFileIsProtected() throws {
    let (store, root, cleanup, attributes) = try makeStoreWithFake()
    defer { cleanup() }
    #expect(attributes.downloadsRootProtectionCalls == [root])
    #expect(attributes.downloadsRootWasEmptyOnFirstProtection == true)
    let name = try store.write(sample)
    #expect(attributes.downloadedFileProtectionCalls.map(\.lastPathComponent) == [name])
  }

  @Test func rootIsReprotectedOnEveryConstruction() throws {
    let (_, root, cleanup, attributes) = try makeStoreWithFake()
    defer { cleanup() }
    _ = try Store(rootURL: root, fileAttributes: attributes)
    #expect(attributes.downloadsRootProtectionCalls.count == 2)
  }

  @Test func realApplierProtectsRootAndFile() throws {
    let (store, root, cleanup) = try makeStore(real: true)
    defer { cleanup() }
    let name = try store.write(sample)
    for url in [root, root.appendingPathComponent(name)] {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      #expect(
        attributes[.protectionKey] as? FileProtectionType
          == .completeUntilFirstUserAuthentication)
      let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
      #expect(values.isExcludedFromBackup == true)
    }
  }

  @Test func deleteIgnoresMissingAndInvalidNames() throws {
    let (store, root, cleanup) = try makeStore()
    defer { cleanup() }
    let name = try store.write(sample)
    let outside = root.deletingLastPathComponent().appendingPathComponent("x.words")
    try Data([1]).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    store.delete(fileNames: [
      "\(UUID().uuidString).words", "../x.words", "x.words", "", "a/b.words", name,
    ])
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
    #expect(FileManager.default.fileExists(atPath: outside.path))
  }

  @Test func readRejectsInvalidNames() throws {
    let (store, _, cleanup) = try makeStore()
    defer { cleanup() }
    for name in ["../x.words", "x.words", "", "/etc/passwd", "\(UUID().uuidString).words/.."] {
      #expect(throws: StoreError.invalidFileName) { try store.read(fileName: name) }
    }
  }

  @Test func readOfMissingFileThrows() throws {
    let (store, _, cleanup) = try makeStore()
    defer { cleanup() }
    #expect(throws: StoreError.unreadable) { try store.read(fileName: "\(UUID().uuidString).words") }
  }

  @Test func sweepRemovesUnreferencedAndTempFilesKeepsReferenced() throws {
    let (store, root, cleanup) = try makeStore()
    defer { cleanup() }
    let kept = try store.write(sample)
    let dropped = try store.write(sample)
    let temp = root.appendingPathComponent(".tmp-\(UUID().uuidString)")
    try Data([1, 2]).write(to: temp)
    let stray = root.appendingPathComponent("stray.txt")
    try Data([1]).write(to: stray)

    #expect(try store.sweep(keeping: [kept], modifiedBefore: .distantFuture) == 3)
    let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
    #expect(remaining == [kept])
    #expect(!remaining.contains(dropped))
    #expect(try store.sweep(keeping: [kept], modifiedBefore: .distantFuture) == 0)
  }

  @Test func audioPrintsRoundTripMappedAndShareTheSweepAndDelete() throws {
    let (store, root, cleanup) = try makeStore()
    defer { cleanup() }
    let words = Data([1, 0, 0, 0, 0xEF, 0xBE, 0xAD, 0xDE])
    let name = try store.writeAudioPrint(littleEndianWords: words)
    #expect(name.hasSuffix(".aprint"))
    #expect(try store.readAudioPrint(fileName: name) == words)
    // Each reader takes only its own kind of file.
    #expect(throws: StoreError.invalidFileName) { try store.read(fileName: name) }
    let transcript = try store.write(sample)
    #expect(throws: StoreError.invalidFileName) { try store.readAudioPrint(fileName: transcript) }
    // The sweep keeps a referenced print and removes an unreferenced one.
    let orphan = try store.writeAudioPrint(littleEndianWords: words)
    #expect(try store.sweep(keeping: [name, transcript], modifiedBefore: .distantFuture) == 1)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(orphan).path) == false)
    store.delete(fileNames: [name])
    #expect(throws: StoreError.unreadable) { try store.readAudioPrint(fileName: name) }
  }

  @Test func audioPrintReadRejectsABadHeaderOrPartialWord() throws {
    let (store, root, cleanup) = try makeStore()
    defer { cleanup() }
    let name = try store.writeAudioPrint(littleEndianWords: Data([1, 2, 3, 4]))
    let url = root.appendingPathComponent(name)
    var data = try Data(contentsOf: url)
    data.append(9)
    try data.write(to: url)
    #expect(throws: StoreError.trailingBytes) { try store.readAudioPrint(fileName: name) }
    data[0] ^= 0xFF
    try data.write(to: url)
    #expect(throws: StoreError.badMagic) { try store.readAudioPrint(fileName: name) }
  }

  @Test func sweepKeepsUnreferencedFilesNewerThanTheCutoff() throws {
    let (store, root, cleanup) = try makeStore()
    defer { cleanup() }
    let old = try store.write(sample)
    let pending = try store.write(sample)
    let cutoff = Date().addingTimeInterval(-600)
    try FileManager.default.setAttributes(
      [.modificationDate: cutoff.addingTimeInterval(-1)],
      ofItemAtPath: root.appendingPathComponent(old).path)

    #expect(try store.sweep(keeping: [], modifiedBefore: cutoff) == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [pending])
  }

  @Test func aWriteWhoseProtectionFailsLeavesNoFile() throws {
    struct ProtectionFailed: Error {}
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("AdSkip")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try Store(
      rootURL: root,
      fileAttributes: FakeFileAttributeApplying(downloadedFileProtectionError: ProtectionFailed()))

    #expect(throws: ProtectionFailed.self) { try store.write(sample) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  @Test func aMoveThatFailsLeavesNoTemporaryFile() throws {
    struct OutOfSpace: Error {}
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("AdSkip")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    let store = try Store(
      rootURL: root, fileAttributes: FakeFileAttributeApplying(),
      fileMover: FakeDownloadFileMoving(error: OutOfSpace()))

    #expect(throws: OutOfSpace.self) { try store.write(sample) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  @Test func onlyCanonicalUpperCaseNamesAreValid() {
    let uuid = UUID().uuidString
    #expect(Store.isValidFileName("\(uuid).words"))
    #expect(!Store.isValidFileName("\(uuid.lowercased()).words"))
    #expect(!Store.isValidFileName("\(uuid).txt"))
  }

  // MARK: - Helpers

  private var sample: StoredTranscript {
    StoredTranscript(
      words: [word("hello"), StoredTranscriptWord(text: "wörld", start: 1.5, end: 2.25)],
      silences: [StoredSilence(start: 3, end: 3.5)], duration: 10.5)
  }

  private func word(_ text: String) -> StoredTranscriptWord {
    StoredTranscriptWord(text: text, start: 0.5, end: 1)
  }

  private func makeStore(real: Bool = false) throws -> (Store, URL, () -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("AdSkip")
    let store = try Store(
      rootURL: root,
      fileAttributes: real ? POSIXFileAttributeApplier() : FakeFileAttributeApplying())
    return (store, root, { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) })
  }

  private func makeStoreWithFake() throws -> (Store, URL, () -> Void, FakeFileAttributeApplying) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("AdSkip")
    let attributes = FakeFileAttributeApplying()
    let store = try Store(rootURL: root, fileAttributes: attributes)
    return (
      store, root, { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) },
      attributes
    )
  }
}
