import Foundation
import Testing

@testable import ReaderCore

@Suite struct ReaderTraceTests {

  @Test("a line is greppable by prefix and carries its fields in the order given")
  func lineShape() {
    let line = ReaderTrace.line("state", ["item": "abc", "value": "downloading"])
    #expect(line == "WHIRRRDR state item=abc value=downloading")
  }

  @Test("an event with no fields is still a complete line")
  func eventWithoutFields() {
    #expect(ReaderTrace.line("begin", [:]) == "WHIRRRDR begin")
  }

  /// The trace is read with `log stream --predicate 'eventMessage CONTAINS "WHIRRRDR"'`, and a value
  /// carrying a space or a newline would split one record across lines and break that reading.
  @Test("whitespace inside a value cannot break the one-record-per-line contract")
  func valuesCannotSplitARecord() {
    let line = ReaderTrace.line("openfail", ["error": "bad\nzip entry", "kind": "unopenable"])
    #expect(line == "WHIRRRDR openfail error=bad_zip_entry kind=unopenable")
    #expect(line.contains("\n") == false)
  }

  /// Readium's errors are long and nested; an unbounded one would flood the stream and push the
  /// fields that identify which book off the far end of the record.
  @Test("a long value is truncated rather than flooding the stream")
  func longValuesAreTruncated() {
    let line = ReaderTrace.line("openfail", ["error": String(repeating: "x", count: 500)])
    #expect(line.count < 300)
    #expect(line.hasSuffix("…"))
  }

  @Test("a file is identified by name alone, never by its container path")
  func fileValuesDropTheirPath() {
    let url = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/ABCD/book.epub")
    #expect(ReaderTrace.fileValue(url) == "book.epub")
  }
}
