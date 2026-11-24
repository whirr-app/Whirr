import Foundation
import Testing

@testable import ReaderCore

@Suite struct EPUBArchiveAdmissionTests {

  private let limits = EPUBArchiveLimits(
    maximumEntryCount: 10,
    maximumTotalExpandedBytes: 1_000,
    maximumEntryExpandedBytes: 400,
    maximumCompressionRatio: 50
  )

  private func entry(expanded: UInt64, stored: UInt64, compressed: Bool = true)
    -> EPUBArchiveEntry
  {
    EPUBArchiveEntry(expandedBytes: expanded, storedBytes: stored, isCompressed: compressed)
  }

  @Test func anOrdinaryPublicationIsAdmitted() {
    let entries = (0..<5).map { _ in entry(expanded: 100, stored: 40) }

    #expect(EPUBArchiveAdmission.refusal(forEntries: entries, limits: limits) == nil)
  }

  @Test func tooManyEntriesAreRefused() {
    let entries = (0..<11).map { _ in entry(expanded: 1, stored: 1) }

    #expect(EPUBArchiveAdmission.refusal(forEntries: entries, limits: limits) == .entryCount(11))
  }

  @Test func aSingleOversizedEntryIsRefused() {
    let entries = [entry(expanded: 401, stored: 10)]

    #expect(
      EPUBArchiveAdmission.refusal(forEntries: entries, limits: limits) == .entryExpandedBytes(401))
  }

  @Test func theRunningExpandedTotalIsRefusedBeforeEveryEntryIsRead() {
    // Four 300-byte entries pass individually and exceed the 1,000-byte total at the fourth.
    let entries = (0..<4).map { _ in entry(expanded: 300, stored: 20) }

    #expect(
      EPUBArchiveAdmission.refusal(forEntries: entries, limits: limits) == .totalExpandedBytes(1_200)
    )
  }

  @Test func anAbusiveCompressionRatioIsRefused() {
    // 200 expanded from 1 stored is 200:1, past the 50:1 bound, while both byte bounds still pass.
    let entries = [entry(expanded: 200, stored: 1)]

    #expect(
      EPUBArchiveAdmission.refusal(forEntries: entries, limits: limits) == .compressionRatio(200))
  }

  @Test func anUncompressedEntryIsNotJudgedOnRatio() {
    // Stored uncompressed, so expanded == stored is a 1:1 ratio no matter how the sizes compare.
    let entries = [entry(expanded: 300, stored: 0, compressed: false)]

    #expect(EPUBArchiveAdmission.refusal(forEntries: entries, limits: limits) == nil)
  }

  @Test func anEntryWithNoReportedExpandedLengthFallsBackToItsStoredLength() {
    // An unreadable length must not silently count as zero and buy an unbounded entry.
    let entries = [EPUBArchiveEntry(expandedBytes: nil, storedBytes: 401, isCompressed: false)]

    #expect(
      EPUBArchiveAdmission.refusal(forEntries: entries, limits: limits) == .entryExpandedBytes(401))
  }

  @Test func theReleaseLimitsAdmitAnOrdinaryBook() {
    // A 400-entry, 60 MB book compressed 4:1 is an ordinary illustrated EPUB.
    let entries = (0..<400).map { _ in entry(expanded: 150_000, stored: 37_500) }

    #expect(EPUBArchiveAdmission.refusal(forEntries: entries, limits: .release) == nil)
  }
}
