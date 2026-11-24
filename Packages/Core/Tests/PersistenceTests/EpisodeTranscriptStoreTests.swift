import Foundation
import GRDB
import Testing

@testable import Persistence

/// `EpisodeTranscriptStore`: one row per downloaded file for the listener's transcript, its words
/// in a file on its own root. Progress swaps the file under the row; a row whose file has gone
/// reads as no transcript and is deleted.
@Suite struct EpisodeTranscriptStoreTests {

  private struct Fixture {
    let database: AppDatabase
    let files: AdSkipTranscriptFileStore
    let store: EpisodeTranscriptStore
    let root: URL

    func fileNames() throws -> Set<String> {
      Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func fixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("EpisodeTranscript-\(UUID().uuidString)", isDirectory: true)
    let database = try AppDatabase.inMemory()
    let files = try AdSkipTranscriptFileStore(
      rootURL: root, fileAttributes: FakeFileAttributeApplying())
    return Fixture(
      database: database, files: files,
      store: EpisodeTranscriptStore(database: database, files: files), root: root)
  }

  private let rss = AdSkipEpisodeIdentity(
    source: .rss, accountId: nil, itemID: "rss:1", episodeID: "guid-1")
  private let abs = AdSkipEpisodeIdentity(
    source: .abs, accountId: 7, itemID: "item-1", episodeID: "episode-1")
  private let fingerprint = EpisodeTranscriptFingerprint(
    fileByteSize: 1_000, fileModificationTime: 1_700_000_000.123_456)
  private let now = Date(timeIntervalSince1970: 1_700_000_100)

  private func transcript(through end: Double, duration: Double = 3_600) -> StoredTranscript {
    StoredTranscript(
      words: [
        StoredTranscriptWord(text: "Hello", start: 1, end: 1.5),
        StoredTranscriptWord(text: "there.", start: 1.5, end: 2),
      ],
      silences: [], duration: duration, coverage: [StoredTimeSpan(start: 0, end: end)])
  }

  @Test func savedProgressReadsBackWithItsTranscript() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let saved = try await fixture.store.saveProgress(
      transcript(through: 600), for: rss, fingerprint: fingerprint,
      transcriberRevision: "speech-2 iOS 27.2", isComplete: false, at: now)

    let entry = try #require(try await fixture.store.transcript(for: rss))
    #expect(entry.record == saved)
    #expect(entry.record.state == .partial)
    #expect(entry.record.fileModificationTime == 1_700_000_000.123_456)
    #expect(entry.record.transcriberRevision == "speech-2 iOS 27.2")
    #expect(entry.record.updatedAt == now)
    #expect(entry.transcript == transcript(through: 600))
  }

  @Test func moreProgressSwapsTheFileAndDeletesTheOldOne() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let first = try await fixture.store.saveProgress(
      transcript(through: 600), for: rss, fingerprint: fingerprint, transcriberRevision: "r",
      isComplete: false, at: now)

    let second = try await fixture.store.saveProgress(
      transcript(through: 3_600), for: rss, fingerprint: fingerprint, transcriberRevision: "r",
      isComplete: true, at: now.addingTimeInterval(60))

    #expect(second.id == first.id)
    #expect(second.state == .complete)
    #expect(second.transcriptFileName != first.transcriptFileName)
    #expect(try fixture.fileNames() == [try #require(second.transcriptFileName)])
    let entry = try #require(try await fixture.store.transcript(for: rss))
    #expect(entry.transcript.coverage == [StoredTimeSpan(start: 0, end: 3_600)])
    #expect(try await fixture.store.allRecords().count == 1)
  }

  @Test func failureKeepsTheRowAndDropsTheFile() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    _ = try await fixture.store.saveProgress(
      transcript(through: 600), for: rss, fingerprint: fingerprint, transcriberRevision: "r",
      isComplete: false, at: now)

    let failed = try await fixture.store.markFailed(
      rss, fingerprint: fingerprint, transcriberRevision: "r2", at: now)

    #expect(failed.state == .failed)
    #expect(failed.transcriptFileName == nil)
    #expect(failed.transcriberRevision == "r2")
    #expect(try fixture.fileNames().isEmpty)
    #expect(try await fixture.store.transcript(for: rss) == nil)
    #expect(try await fixture.store.record(for: rss) == failed)
  }

  @Test func aRowWhoseFileIsMissingReadsAsNoTranscriptAndIsDeleted() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let saved = try await fixture.store.saveProgress(
      transcript(through: 600), for: rss, fingerprint: fingerprint, transcriberRevision: "r",
      isComplete: false, at: now)
    try FileManager.default.removeItem(
      at: fixture.root.appendingPathComponent(try #require(saved.transcriptFileName)))

    #expect(try await fixture.store.transcript(for: rss) == nil)
    #expect(try await fixture.store.record(for: rss) == nil)
  }

  @Test func deletingAnEpisodeRemovesItsRowAndFile() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    _ = try await fixture.store.saveProgress(
      transcript(through: 600), for: rss, fingerprint: fingerprint, transcriberRevision: "r",
      isComplete: false, at: now)
    let kept = try await fixture.store.saveProgress(
      transcript(through: 600), for: abs, fingerprint: fingerprint, transcriberRevision: "r",
      isComplete: false, at: now)

    try await fixture.store.deleteEpisodes([rss])

    #expect(try await fixture.store.record(for: rss) == nil)
    #expect(try await fixture.store.allRecords() == [kept])
    #expect(try fixture.fileNames() == [try #require(kept.transcriptFileName)])
  }

  @Test func rssRowsWithoutAnAccountCollideOnTheIdentityIndex() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    _ = try await fixture.store.saveProgress(
      transcript(through: 600), for: rss, fingerprint: fingerprint, transcriberRevision: "r",
      isComplete: false, at: now)

    await #expect(throws: DatabaseError.self) {
      try await fixture.database.writeAsync { db in
        try db.execute(
          sql: """
            INSERT INTO episodeTranscript
              (source, accountId, itemID, episodeID, fileByteSize, fileModificationTime,
               transcriberRevision, state, transcriptFileName, updatedAt)
            VALUES ('rss', NULL, 'rss:1', 'guid-1', 1, 1, 'r', 'failed', NULL, 0)
            """)
      }
    }
  }

  @Test func anAccountIsRequiredExactlyForServerRows() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    for (source, accountId) in [("abs", "NULL"), ("rss", "1")] {
      await #expect(throws: DatabaseError.self) {
        try await fixture.database.writeAsync { db in
          try db.execute(
            sql: """
              INSERT INTO episodeTranscript
                (source, accountId, itemID, episodeID, fileByteSize, fileModificationTime,
                 transcriberRevision, state, transcriptFileName, updatedAt)
              VALUES ('\(source)', \(accountId), 'i', 'e', 1, 1, 'r', 'failed', NULL, 0)
              """)
        }
      }
    }
  }

  @Test func sweepingRemovesOnlyFilesNoRowNames() async throws {
    let fixture = try fixture()
    defer { fixture.cleanUp() }
    let saved = try await fixture.store.saveProgress(
      transcript(through: 600), for: rss, fingerprint: fingerprint, transcriberRevision: "r",
      isComplete: false, at: now)
    let orphan = try fixture.files.write(transcript(through: 60))

    let removed = try await fixture.store.sweepFiles(modifiedBefore: .distantFuture)

    #expect(removed == 1)
    #expect(try fixture.fileNames() == [try #require(saved.transcriptFileName)])
    #expect(try fixture.fileNames().contains(orphan) == false)
  }
}
