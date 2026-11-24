import Foundation
import TestSupport
import Testing

@testable import PodcastFeeds

@Suite("Real feed conformance", .timeLimit(.minutes(1)))
struct RealFeedConformanceTests {
  // The fixtures are synthetic, but each one reproduces the markup of a real-world feed family:
  // compact single-line iTunes RSS with CDATA notes, pretty-printed RSS whose content:encoded
  // repeats the description, a single-line broadcaster feed with namespaced enclosure variants,
  // a WordPress/PowerPress feed with numeric character references, and a linkblog Atom feed.
  @Test("parses the real-world-shaped RSS fixtures")
  func parsesRealRSSCaptures() throws {
    let expected: [(String, String, String, String)] = [
      (
        "compact-itunes-rss", "Fixture Tech Talk", "312: A Balanced Fixture Breakfast",
        "https://cdn.example.com/artwork"
      ),
      (
        "content-encoded-rss", "Fixture Morning Briefing",
        "Fixture Headline One, Fixture Headline Two, Fixture Headline Three",
        "https://images.example.com/dims3/default/strip/false/crop/3000x3000+0+0/resize/1400/quality/66/format/jpg/?url=http%3A%2F%2Fstorage.example.org%2Fe0%2F7a%2Ffixture%2Fshow.png"
      ),
      (
        "single-line-rss", "Fixture World Report", "Fixture correspondent reports from the example region",
        "http://images.example.org/ic/3000x3000/fixture01.jpg"
      ),
      (
        "powerpress-rss", "Fixture Conversations Podcast",
        "#500 – Fixture Guest: Topic One, Topic Two, Topic Three & Topic Four",
        "https://example.com/wordpress/wp-content/uploads/powerpress/artwork_3000-230.png"
      ),
    ]

    for (name, title, firstItemTitle, artworkURL) in expected {
      let feed = try FeedParser.parseRSS(try fixture(named: name))
      #expect(feed.title == title)
      #expect(feed.artworkURL?.absoluteString == artworkURL)
      #expect(feed.items.count == 4)
      #expect(feed.items.first?.title == firstItemTitle)
      for item in feed.items {
        #expect(item.guid != nil)
        #expect(item.pubDate != nil)
        #expect(item.enclosure != nil)
        #expect(
          item.enclosure?.url.scheme?.lowercased() == "http" || item.enclosure?.url.scheme?.lowercased() == "https")
        #expect(item.enclosure?.url.host?.isEmpty == false)
      }
    }

    let contentEncoded = try FeedParser.parseRSS(try fixture(named: "content-encoded-rss"))
    #expect(contentEncoded.items[0].enclosure?.url.absoluteString.contains("?awCollectionId=") == true)
    #expect(contentEncoded.items[0].enclosure?.url.absoluteString.contains("&awEpisodeId=") == true)
    #expect(contentEncoded.items.allSatisfy { $0.content != nil && $0.content == $0.synopsis })

    let atom = try FeedParser.parseAtom(try fixture(named: "linkblog-atom"))
    #expect(atom.items.allSatisfy { $0.content == nil })
  }

  @Test("parses the real-world-shaped Atom fixture")
  func parsesRealAtomCapture() throws {
    let feed = try FeedParser.parseAtom(try fixture(named: "linkblog-atom"))
    #expect(feed.title == "Fixture Linkblog")
    #expect(feed.items.count == 4)
    #expect(feed.items[0].title == "Fixture Design Spills Its Coffee on Example/Social")
    #expect(feed.items[0].guid == "tag:linkblog.example.com,2026:/linked//6.10001")
    #expect(feed.items[0].pubDate == "2026-08-13T01:03:45Z")
    #expect(feed.items[1].pubDate == "2026-08-12T21:23:30Z")
    for item in feed.items {
      #expect(item.enclosure == nil)
    }
  }

  // Community-radio shape: one item's CDATA show notes run past the string cap. The live feed is
  // served as `application/xml`, which the transport does not gate on.
  @Test("an item description over the string cap drops its synopsis and keeps the feed")
  func parsesFeedWithOversizedItemDescription() throws {
    let feed = try FeedParser.parseRSS(try fixture(named: "oversized-item-description-rss"))
    #expect(feed.title == "Fixture Community Radio")
    #expect(feed.artworkURL?.absoluteString == "http://radio.example.org/images/feed_itunes.png")
    #expect(feed.items.count == 2)
    #expect(feed.items[0].synopsis == "<p>A short episode.</p>")
    #expect(feed.items[1].title == "FCR0001: An episode with very long show notes")
    #expect(feed.items[1].synopsis == nil)
    #expect(feed.items.allSatisfy { $0.enclosure != nil && $0.guid != nil && $0.pubDate != nil })
  }

  // XSLT-generated shape: an HTML5-style `<!DOCTYPE rss SYSTEM "about:legacy-compat">` prologue
  // and no XML declaration.
  @Test("a bare DOCTYPE prologue does not stop an RSS feed parsing")
  func parsesFeedWithBareDOCTYPEPrologue() throws {
    let feed = try FeedParser.parseRSS(try fixture(named: "doctype-legacy-compat-rss"))
    #expect(feed.title == "Fixture Freedom Podcast")
    #expect(feed.artworkURL?.absoluteString == "https://example.org/graphics/podcast-logo-3000.png")
    #expect(feed.items.map(\.title) == ["FFP#2: Second episode", "FFP#1: First episode"])
    #expect(feed.items[0].content == "<h1>FFP#2</h1><p>Second episode notes.</p>")
    #expect(feed.items.allSatisfy { $0.enclosure != nil && $0.durationText != nil })
  }

  private func fixture(named name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
  }
}

@Suite("Feed parser hardening", .timeLimit(.minutes(1)))
struct FeedParserHardeningTests {
  @Test("a cancelled task does not finish parsing a feed")
  func cancellation() async {
    let gate = ParseCancellationGate()
    let data = Data("<rss><channel><title>Cancelled</title></channel></rss>".utf8)
    let task = Task {
      await gate.wait()
      return try FeedParser.parseRSS(data)
    }

    task.cancel()
    await gate.release()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }

  @Test("cancellation interrupts an in-progress shallow element flood")
  func cancellationDuringElementFlood() async {
    let elements = String(repeating: "<x/>", count: 1_000)
    let data = Data("<rss><channel><title>Cancelled</title>\(elements)</channel></rss>".utf8)
    let recorder = ElementCountRecorder()
    let task = Task {
      try FeedParser.parseForTesting(data) { elementCount in
        recorder.record(elementCount)
        guard elementCount == 100 else { return }
        withUnsafeCurrentTask { $0?.cancel() }
      }
    }

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
    #expect(recorder.lastElementCount == 100)
  }

  @Test("enforces item and realistic CDATA string caps")
  func enforcesCapsOnRealisticMarkup() throws {
    let items = String(repeating: "<item><guid>x</guid></item>", count: 4)
    let oversizedFeed = "<rss><channel><title>Show</title>\(items)</channel></rss>"
    #expect(throws: FeedParseError.limitExceeded(.items)) {
      try FeedParser.parseRSS(Data(oversizedFeed.utf8), limits: FeedParseLimits(maximumItems: 3))
    }

    let oversizedText = try hostileFixture(named: "hostile-oversized-cdata")
    #expect(throws: FeedParseError.limitExceeded(.stringBytes)) {
      try FeedParser.parseRSS(oversizedText, limits: FeedParseLimits(maximumStringBytes: 32))
    }
  }

  @Test("rejects a document over the feed byte cap before XMLParser is created")
  func rejectsOversizedDocumentBeforeXMLParserCreation() throws {
    let parserCreations = ElementCountRecorder()
    let elementCallbacks = ElementCountRecorder()
    let data = paddedRSS(byteCount: FeedParser.maximumDocumentBytes + 1)

    #expect(throws: FeedParseError.limitExceeded(.documentBytes)) {
      try FeedParser.parseForTesting(
        data,
        onXMLParserCreation: { parserCreations.record(1) },
        onStartElement: { elementCallbacks.record($0) })
    }
    #expect(parserCreations.lastElementCount == 0)
    #expect(elementCallbacks.lastElementCount == 0)
  }

  @Test("accepts a valid RSS document exactly at the feed byte cap")
  func acceptsDocumentAtByteCap() throws {
    let data = paddedRSS(byteCount: FeedParser.maximumDocumentBytes)

    #expect(try FeedParser.parseRSS(data).title == "Boundary")
  }

  @Test("rejects malformed and non-XML input")
  func rejectsMalformedInput() throws {
    let malformedInputs = try [
      Data("<rss><channel><title>Truncated".utf8),
      Data("<rss><channel><title>Wrong</channel></rss>".utf8),
      Data("<rss><channel><title>Show</title></channel></rss>trailing".utf8),
      hostileFixture(named: "hostile-malformed"),
    ]

    for input in malformedInputs {
      expectMalformedXML {
        _ = try FeedParser.parseRSS(input)
      }
    }
    #expect(throws: FeedParseError.malformedXML(line: 0, column: 0)) {
      try FeedParser.parseRSS(Data())
    }
    #expect(throws: FeedParseError.unrecognizedRoot) {
      try FeedParser.parseRSS(Data("<html><body>temporary error</body></html>".utf8))
    }
  }

  @Test("accepts declared Latin-1 and BOM encoded feeds")
  func acceptsDeclaredLatin1AndBOMEncodedFeeds() throws {
    let latin1Prefix = Data("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><rss><channel><title>Caf".utf8)
    let latin1Suffix = Data("</title></channel></rss>".utf8)
    var latin1 = latin1Prefix
    latin1.append(0xE9)
    latin1.append(latin1Suffix)
    #expect(try FeedParser.parseRSS(latin1).title == "Café")

    let utf8BOM = Data([0xEF, 0xBB, 0xBF]) + Data("<rss><channel><title>BOM</title></channel></rss>".utf8)
    #expect(try FeedParser.parseRSS(utf8BOM).title == "BOM")

    let utf16LE = Data([0xFF, 0xFE]) + Data("<rss><channel><title>Wide</title></channel></rss>".utf16LittleEndianBytes)
    #expect(try FeedParser.parseRSS(utf16LE).title == "Wide")
  }

  @Test("rejects invalid bytes for the declared encoding")
  func rejectsInvalidDeclaredEncoding() {
    var data = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><rss><channel><title>Bad ".utf8)
    data.append(contentsOf: [0xC3, 0x28])
    data.append(Data("</title></channel></rss>".utf8))
    expectMalformedXML {
      _ = try FeedParser.parseRSS(data)
    }
  }

  @Test("rejects a committed mixed-encoding fixture as malformed XML")
  func rejectsMixedEncodingFixture() throws {
    let data = try hostileFixture(named: "hostile-mixed-encoding")
    expectMalformedXML {
      _ = try FeedParser.parseRSS(data)
    }
  }

  @Test("rejects internal DTDs before entity expansion")
  func rejectsInternalDTDBeforeEntityExpansion() throws {
    let data = try hostileFixture(named: "hostile-recursive-entity")
    #expect(throws: FeedParseError.dtdNotAllowed) {
      try FeedParser.parseRSS(data, limits: FeedParseLimits(maximumStringBytes: 32))
    }
  }

  @Test("does not expand external entities")
  func doesNotExpandExternalEntity() throws {
    let data = try hostileFixture(named: "hostile-external-entity")
    #expect(throws: FeedParseError.dtdNotAllowed) {
      try FeedParser.parseRSS(data)
    }
  }

  @Test(
    "still rejects a DOCTYPE with an internal subset, or a second DOCTYPE",
    arguments: [
      "<!DOCTYPE rss SYSTEM \"about:legacy-compat\" [<!ENTITY a \"ha\">]><rss><channel><title>&a;</title></channel></rss>",
      "<!DOCTYPE rss SYSTEM \"a]>b\" [<!ENTITY a \"ha\">]><rss><channel><title>&a;</title></channel></rss>",
      "<!DOCTYPE rss><!DOCTYPE rss [<!ENTITY a \"ha\">]><rss><channel><title>&a;</title></channel></rss>",
      "<!DOCTYPE rss SYSTEM \"unterminated><rss><channel><title>T</title></channel></rss>",
    ])
  func rejectsInternalSubsetBesideBareDOCTYPE(xml: String) {
    #expect(throws: FeedParseError.dtdNotAllowed) {
      try FeedParser.parseRSS(Data(xml.utf8))
    }
  }

  @Test("a bare DOCTYPE's external DTD is never loaded")
  func bareDOCTYPEDoesNotLoadExternalDTD() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let dtd = directory.appending(path: "feed.dtd")
    try Data("<!ENTITY leaked \"from the external DTD\">".utf8).write(to: dtd)

    let xml = "<!DOCTYPE rss SYSTEM \"\(dtd.absoluteString)\"><rss><channel><title>&leaked;</title></channel></rss>"
    expectMalformedXML { _ = try FeedParser.parseRSS(Data(xml.utf8)) }
  }

  @Test("a bare DOCTYPE is blanked without moving later line numbers, even with a BOM")
  func bareDOCTYPEKeepsLineNumbers() {
    let xml = "\u{FEFF}<!DOCTYPE rss\nSYSTEM \"a>b\">\n<rss><channel><title>T</title>\n<broken></channel></rss>"
    do {
      _ = try FeedParser.parseRSS(Data(xml.utf8))
      Issue.record("Expected malformed XML")
    } catch FeedParseError.malformedXML(let line, _) {
      #expect(line == 4)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("a bare DOCTYPE in UTF-16 is still rejected")
  func rejectsUTF16BareDOCTYPE() {
    let xml = "<!DOCTYPE rss><rss><channel><title>T</title></channel></rss>"
    let data = Data([0xFF, 0xFE] + xml.utf16LittleEndianBytes)
    #expect(throws: FeedParseError.dtdNotAllowed) {
      try FeedParser.parseRSS(data)
    }
  }

  @Test("enforces the element depth cap")
  func enforcesDepthCap() throws {
    let data = try hostileFixture(named: "hostile-deep-nesting")
    #expect(throws: FeedParseError.limitExceeded(.elementDepth)) {
      try FeedParser.parseRSS(data, limits: FeedParseLimits(maximumElementDepth: 4))
    }
  }

  @Test("enforces the total element-count cap on shallow input")
  func enforcesElementCountCap() throws {
    let data = try hostileFixture(named: "hostile-shallow-elements")
    #expect(throws: FeedParseError.limitExceeded(.elementCount)) {
      try FeedParser.parseRSS(data, limits: FeedParseLimits(maximumElements: 8))
    }
  }

  private func hostileFixture(named name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
  }

  private func paddedRSS(byteCount: Int) -> Data {
    let prefix = Data("<rss><channel><title>Boundary</title>".utf8)
    let suffix = Data("</channel></rss>".utf8)
    var data = prefix
    data.append(Data(repeating: 0x20, count: byteCount - prefix.count - suffix.count))
    data.append(suffix)
    return data
  }
}

private actor ParseCancellationGate {
  // The test cancels the parsing task before opening the gate, so a parked call must stay parked.
  private nonisolated let gate = TestGate<Void>(
    label: "ParseCancellationGate", ignoresCancellation: true)

  init() { gate.hold() }

  func wait() async { await gate.pass() }

  func release() { gate.release() }
}

private final class ElementCountRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  var lastElementCount: Int { lock.withLock { value } }

  func record(_ elementCount: Int) {
    lock.withLock { value = elementCount }
  }
}

private func expectMalformedXML(_ operation: () throws -> Void, sourceLocation: SourceLocation = #_sourceLocation) {
  do {
    try operation()
    Issue.record("Expected malformed XML", sourceLocation: sourceLocation)
  } catch let error as FeedParseError {
    guard case .malformedXML = error else {
      Issue.record("Expected malformed XML, got \(error)", sourceLocation: sourceLocation)
      return
    }
  } catch {
    Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
  }
}

extension String {
  fileprivate var utf16LittleEndianBytes: [UInt8] {
    utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
  }
}
