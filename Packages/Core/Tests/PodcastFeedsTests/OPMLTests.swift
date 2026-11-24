import Foundation
import PodcastFeeds
import Testing

@Suite("OPML")
struct OPMLTests {
  @Test("parses nested subscription outlines")
  func parsesRepresentativeDocument() throws {
    let xml = """
      <opml version="2.0"><head><title>Subscriptions</title></head><body>
        <outline xmlUrl="https://example.com/one.xml" text="One" title="Ignored" />
        <outline title="Folder"><outline text="Two" htmlUrl="https://example.com/two" xmlUrl="https://example.com/two.xml" /></outline>
        <outline text="Folder only" />
        <outline xmlUrl="not-a-url" text="Skipped" />
        <outline title="Title only" xmlUrl="https://example.com/three.xml" />
      </body></opml>
      """
    let document = try OPML.parse(Data(xml.utf8))
    #expect(
      document
        == OPMLDocument(
          title: "Subscriptions",
          entries: [
            OPMLFeedEntry(title: "One", feedURL: URL(string: "https://example.com/one.xml")!, siteURL: nil),
            OPMLFeedEntry(
              title: "Two", feedURL: URL(string: "https://example.com/two.xml")!,
              siteURL: URL(string: "https://example.com/two")!),
            OPMLFeedEntry(title: "Title only", feedURL: URL(string: "https://example.com/three.xml")!, siteURL: nil),
          ]))
  }

  @Test("ignores a head nested inside a body outline")
  func nestedHeadDoesNotSupplyTitle() throws {
    let xml = """
      <opml><head><title>Real</title></head><body>
        <outline text="Folder"><head><title>Fake</title></head></outline>
      </body></opml>
      """
    #expect(try OPML.parse(Data(xml.utf8)).title == "Real")
    let headless = "<opml><body><outline><head><title>Fake</title></head></outline></body></opml>"
    #expect(try OPML.parse(Data(headless.utf8)).title == nil)
  }

  @Test("round trips escaped and optional values")
  func roundTrips() throws {
    let document = OPMLDocument(
      title: "A & <title> — Café's",
      entries: [
        OPMLFeedEntry(
          title: "A & <feed> \"quoted\" — Café's", feedURL: URL(string: "https://example.com/a?x=1&y=2")!,
          siteURL: URL(string: "https://example.com/site")!),
        OPMLFeedEntry(title: nil, feedURL: URL(string: "http://example.com/b")!, siteURL: nil),
      ])
    #expect(try OPML.parse(OPML.serialize(document)) == document)
    #expect(
      try OPML.parse(OPML.serialize(OPMLDocument(title: nil, entries: []))) == OPMLDocument(title: nil, entries: []))
  }

  @Test("enforces entry, string, and depth limits")
  func limits() {
    #expect(throws: FeedParseError.limitExceeded(.items)) {
      try OPML.parse(
        Data(
          "<opml><body><outline xmlUrl=\"https://example.com/a\"/><outline xmlUrl=\"https://example.com/b\"/></body></opml>"
            .utf8), limits: FeedParseLimits(maximumItems: 1))
    }
    #expect(throws: FeedParseError.limitExceeded(.stringBytes)) {
      try OPML.parse(
        Data("<opml><body><outline xmlUrl=\"https://example.com/a\" text=\"123456\"/></body></opml>".utf8),
        limits: FeedParseLimits(maximumStringBytes: 5))
    }
    let nested = String(repeating: "<outline>", count: 4) + String(repeating: "</outline>", count: 4)
    #expect(throws: FeedParseError.limitExceeded(.elementDepth)) {
      try OPML.parse(
        Data(("<opml><body>" + nested + "</body></opml>").utf8), limits: FeedParseLimits(maximumElementDepth: 4))
    }
  }

  @Test("rejects a local document above the feed transport byte cap")
  func documentByteLimit() {
    #expect(throws: FeedParseError.limitExceeded(.documentBytes)) {
      try OPML.parse(Data(repeating: 0x20, count: OPML.maximumDocumentBytes + 1))
    }
  }

  @Test("rejects a DOCTYPE with an internal entity subset before expansion")
  func rejectsInternalDTD() {
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE opml [
        <!ENTITY a "lol">
        <!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">
        <!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">
      ]>
      <opml><head><title>&c;</title></head><body></body></opml>
      """
    #expect(throws: FeedParseError.dtdNotAllowed) {
      try OPML.parse(Data(xml.utf8), limits: FeedParseLimits(maximumStringBytes: 32))
    }
  }

  @Test("rejects a DOCTYPE declaring an external SYSTEM entity")
  func rejectsExternalDTD() {
    let xml = """
      <!DOCTYPE opml [<!ENTITY hosts SYSTEM "file:///etc/hosts">]>
      <opml><head><title>&hosts;</title></head><body></body></opml>
      """
    #expect(throws: FeedParseError.dtdNotAllowed) {
      try OPML.parse(Data(xml.utf8))
    }
  }

  @Test("enforces the total element-count cap")
  func elementCountLimit() {
    let xml = "<opml><body><outline/><outline/><outline/></body></opml>"
    #expect(throws: FeedParseError.limitExceeded(.elementCount)) {
      try OPML.parse(Data(xml.utf8), limits: FeedParseLimits(maximumElements: 4))
    }
  }

  @Test("rejects malformed XML and non OPML roots")
  func rejectsInvalidDocuments() {
    #expect(throws: FeedParseError.self) { try OPML.parse(Data("<opml><body>".utf8)) }
    #expect(throws: FeedParseError.unrecognizedRoot) { try OPML.parse(Data("<rss />".utf8)) }
  }

  @Test("drops credential-bearing feed and site URLs")
  func rejectsCredentialedURLs() throws {
    let xml = """
      <opml><body>
        <outline text="Private" xmlUrl="https://user:secret@example.com/private.xml"/>
        <outline text="Public" xmlUrl="https://example.com/public.xml" htmlUrl="https://user:secret@example.com/"/>
      </body></opml>
      """

    let document = try OPML.parse(Data(xml.utf8))

    #expect(document.entries.count == 1)
    #expect(document.entries[0].feedURL == URL(string: "https://example.com/public.xml"))
    #expect(document.entries[0].siteURL == nil)
  }

  @Test("checked export enforces item, string, and credential-free URL limits")
  func checkedExportLimits() throws {
    let feedURL = URL(string: "https://feeds.example/show.xml")!
    let limits = FeedParseLimits(maximumItems: 1, maximumStringBytes: 8, maximumElementDepth: 8)
    #expect(throws: FeedParseError.limitExceeded(.items)) {
      try OPML.serializeChecked(
        OPMLDocument(
          title: nil,
          entries: [
            OPMLFeedEntry(title: nil, feedURL: feedURL, siteURL: nil),
            OPMLFeedEntry(title: nil, feedURL: feedURL, siteURL: nil),
          ]), limits: limits)
    }
    #expect(throws: FeedParseError.limitExceeded(.stringBytes)) {
      try OPML.serializeChecked(
        OPMLDocument(
          title: String(repeating: "x", count: 9),
          entries: []), limits: limits)
    }
    #expect(throws: OPMLSerializationError.invalidURL) {
      try OPML.serializeChecked(
        OPMLDocument(
          title: nil,
          entries: [
            OPMLFeedEntry(
              title: nil, feedURL: URL(string: "https://user:pass@feeds.example/show.xml")!,
              siteURL: nil)
          ]))
    }
  }

  @Test("serializes the OPML envelope and RSS outlines")
  func serializesGoldenDocument() throws {
    let document = OPMLDocument(
      title: "Show",
      entries: [
        OPMLFeedEntry(title: "Feed", feedURL: URL(string: "https://example.com/feed")!, siteURL: nil)
      ])
    let output = String(decoding: OPML.serialize(document), as: UTF8.self)
    #expect(
      output
        == "<?xml version=\"1.0\" encoding=\"UTF-8\"?><opml version=\"2.0\"><head><title>Show</title></head><body><outline type=\"rss\" text=\"Feed\" xmlUrl=\"https://example.com/feed\"/></body></opml>"
    )
    #expect(output.hasPrefix("<?xml version=\"1.0\""))
    #expect(output.contains("type=\"rss\""))
  }
}
