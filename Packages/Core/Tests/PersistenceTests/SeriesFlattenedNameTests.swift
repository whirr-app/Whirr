import Testing

@testable import Persistence

@Suite struct SeriesFlattenedNameTests {
  @Test("parses one sequenced series entry")
  func parsesOneSequencedEntry() {
    #expect(
      SeriesFlattenedName.entries(from: "Dungeon Crawler Carl #7")
        == [SeriesFlattenedName.Entry(name: "Dungeon Crawler Carl", sequence: "7")])
  }

  @Test("splits multiple sequenced series entries")
  func parsesMultipleSequencedEntries() {
    #expect(
      SeriesFlattenedName.entries(from: "Foo #1, Bar #3")
        == [
          SeriesFlattenedName.Entry(name: "Foo", sequence: "1"),
          SeriesFlattenedName.Entry(name: "Bar", sequence: "3"),
        ])
  }

  @Test("keeps an entry with no sequence")
  func parsesUnsequencedEntry() {
    #expect(
      SeriesFlattenedName.entries(from: "Foo")
        == [SeriesFlattenedName.Entry(name: "Foo", sequence: nil)])
  }

  @Test("keeps sequenced and unsequenced entries together")
  func parsesMixedEntries() {
    #expect(
      SeriesFlattenedName.entries(from: "Foo #1, Bar")
        == [
          SeriesFlattenedName.Entry(name: "Foo", sequence: "1"),
          SeriesFlattenedName.Entry(name: "Bar", sequence: nil),
        ])
  }

  @Test("nil and empty values produce no entries")
  func parsesEmptyValues() {
    #expect(SeriesFlattenedName.entries(from: nil).isEmpty)
    #expect(SeriesFlattenedName.entries(from: "").isEmpty)
    #expect(SeriesFlattenedName.entries(from: "   \t").isEmpty)
  }

  @Test("parses SQLite-style numeric prefixes")
  func parsesSequenceValues() {
    #expect(SeriesFlattenedName.sequenceValue("1") == 1.0)
    #expect(SeriesFlattenedName.sequenceValue("1.5") == 1.5)
    #expect(SeriesFlattenedName.sequenceValue(".5") == 0.5)
    #expect(SeriesFlattenedName.sequenceValue("-2") == -2.0)
    #expect(SeriesFlattenedName.sequenceValue("3a") == 3.0)
    #expect(SeriesFlattenedName.sequenceValue("three") == 0.0)
    #expect(SeriesFlattenedName.sequenceValue("") == 0.0)
    #expect(SeriesFlattenedName.sequenceValue("1e3") == 1_000.0)
    #expect(SeriesFlattenedName.sequenceValue(nil) == nil)
  }

  @Test("known limit: comma-space in a series name is split as two entries")
  func pinsCommaSpaceSeriesNameLimit() {
    #expect(
      SeriesFlattenedName.entries(from: "Mistborn, Era 2 #1")
        == [
          SeriesFlattenedName.Entry(name: "Mistborn", sequence: nil),
          SeriesFlattenedName.Entry(name: "Era 2", sequence: "1"),
        ])
  }

  @Test("known limit: hash-space in an unsequenced series name is parsed as a sequence")
  func pinsHashSpaceSeriesNameLimit() {
    #expect(
      SeriesFlattenedName.entries(from: "Project #X")
        == [SeriesFlattenedName.Entry(name: "Project", sequence: "X")])
  }

  @Test("known limit: comma-space in a sequence is split as a new entry")
  func pinsCommaSpaceSequenceLimit() {
    #expect(
      SeriesFlattenedName.entries(from: "Series #1, 2")
        == [
          SeriesFlattenedName.Entry(name: "Series", sequence: "1"),
          SeriesFlattenedName.Entry(name: "2", sequence: nil),
        ])
  }
}
