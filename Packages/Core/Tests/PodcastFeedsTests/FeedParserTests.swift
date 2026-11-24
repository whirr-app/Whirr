import Foundation
import PodcastFeeds
import Testing

@Suite("Feed parser")
struct FeedParserTests {
  @Test("maps a representative RSS feed")
  func mapsRepresentativeFeed() throws {
    let feed = try parse(
      """
      <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
        <channel>
          <title>My Podcast</title>
          <itunes:author>Jane Host</itunes:author>
          <itunes:image href="https://example.com/art.jpg" />
          <description>All about the show</description>
          <item><guid>one</guid><title>First</title><enclosure url="https://example.com/one.mp3" type="audio/mpeg" length="1234" /><pubDate>Mon, 01 Jan 2024 00:00:00 GMT</pubDate><itunes:duration> 45:12 </itunes:duration></item>
          <item><guid>two</guid><title>Second</title><enclosure url="https://example.com/two.mp3" type="audio/mpeg" length="5678" /><pubDate>Tue, 02 Jan 2024 00:00:00 GMT</pubDate></item>
        </channel>
      </rss>
      """)

    #expect(feed.title == "My Podcast")
    #expect(feed.author == "Jane Host")
    #expect(feed.artworkURL?.absoluteString == "https://example.com/art.jpg")
    #expect(feed.synopsis == "All about the show")
    #expect(feed.items.count == 2)
    #expect(
      feed.items[0]
        == ParsedFeedItem(
          guid: "one", title: "First",
          enclosure: ParsedEnclosure(
            url: try #require(URL(string: "https://example.com/one.mp3")), type: "audio/mpeg", lengthBytes: 1234),
          pubDate: "Mon, 01 Jan 2024 00:00:00 GMT", durationText: "45:12", synopsis: nil,
          seasonNumber: nil, episodeNumber: nil))
  }

  @Test("maps a representative Atom feed")
  func mapsRepresentativeAtomFeed() throws {
    let feed = try FeedParser.parseAtom(
      Data(
        """
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <title>Atom Show</title><author><name>Atom Host</name></author>
          <logo>https://example.com/logo.png</logo><icon>https://example.com/icon.png</icon>
          <subtitle>Atom synopsis</subtitle>
          <entry><id>one</id><title>First Atom</title>
            <link rel="alternate" href="https://example.com/one" />
            <link rel="enclosure" href="https://example.com/one.mp3" type="audio/mpeg" length="1234" />
            <published>2026-08-13T10:15:49Z</published><itunes:duration>45:12</itunes:duration>
          </entry>
          <entry><id>two</id><title>Second Atom</title>
            <link rel="alternate" href="https://example.com/two" />
            <updated>2026-08-13T10:15:49+02:00</updated>
          </entry>
        </feed>
        """.utf8))

    #expect(feed.title == "Atom Show")
    #expect(feed.author == "Atom Host")
    #expect(feed.artworkURL?.absoluteString == "https://example.com/logo.png")
    #expect(feed.synopsis == "Atom synopsis")
    #expect(
      feed.items == [
        ParsedFeedItem(
          guid: "one", title: "First Atom",
          enclosure: ParsedEnclosure(
            url: try #require(URL(string: "https://example.com/one.mp3")), type: "audio/mpeg", lengthBytes: 1234),
          pubDate: "2026-08-13T10:15:49Z", durationText: "45:12", synopsis: nil, seasonNumber: nil,
          episodeNumber: nil),
        ParsedFeedItem(
          guid: "two", title: "Second Atom", enclosure: nil,
          pubDate: "2026-08-13T10:15:49+02:00", durationText: nil, synopsis: nil, seasonNumber: nil,
          episodeNumber: nil),
      ])
  }

  @Test("dispatches RSS and Atom roots")
  func dispatchesRoots() throws {
    let rss = Data("<rss><channel><title>RSS</title></channel></rss>".utf8)
    let atom = Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Atom</title></feed>".utf8)
    #expect(try FeedParser.parse(rss).title == "RSS")
    #expect(try FeedParser.parse(atom).title == "Atom")
    #expect(throws: FeedParseError.unrecognizedRoot) {
      try FeedParser.parse(Data("<html />".utf8))
    }
    #expect(throws: FeedParseError.unrecognizedRoot) { try FeedParser.parseRSS(atom) }
    #expect(throws: FeedParseError.unrecognizedRoot) { try FeedParser.parseAtom(rss) }
  }

  @Test("enforces Atom item and string limits")
  func atomLimits() {
    let xml =
      "<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Show</title>"
      + String(repeating: "<entry />", count: 4) + "</feed>"
    #expect(throws: FeedParseError.limitExceeded(.items)) {
      try FeedParser.parseAtom(Data(xml.utf8), limits: FeedParseLimits(maximumItems: 3))
    }
    let oversized =
      "<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Show</title><entry><title>123456</title></entry></feed>"
    #expect(throws: FeedParseError.limitExceeded(.stringBytes)) {
      try FeedParser.parseAtom(Data(oversized.utf8), limits: FeedParseLimits(maximumStringBytes: 5))
    }
  }

  @Test("keeps the first iTunes duration and trims empty values")
  func durationFirstOccurrenceWins() throws {
    let feed = try parse(
      "<rss xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel><title>Show</title><item><itunes:duration> first </itunes:duration><itunes:duration>second</itunes:duration></item><item><itunes:duration>   </itunes:duration></item></channel></rss>"
    )
    #expect(feed.items[0].durationText == "first")
    #expect(feed.items[1].durationText == nil)
  }

  @Test("parses item synopsis and positive season and episode numbers")
  func itemFields() throws {
    let feed = try parse(
      "<rss xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel><title>Show</title><item><description>first</description><itunes:summary>second</itunes:summary><itunes:season> 2 </itunes:season><itunes:episode>7</itunes:episode></item><item><itunes:season>nope</itunes:season><itunes:episode>0</itunes:episode></item><item /></channel></rss>"
    )
    #expect(feed.items[0].synopsis == "first")
    #expect(feed.items[0].seasonNumber == 2)
    #expect(feed.items[0].episodeNumber == 7)
    #expect(feed.items[1].seasonNumber == nil)
    #expect(feed.items[1].episodeNumber == nil)
    #expect(feed.items[2].synopsis == nil)
    #expect(feed.items[2].seasonNumber == nil)
    #expect(feed.items[2].episodeNumber == nil)
  }

  @Test("parses the first item content:encoded beside the synopsis")
  func itemContentEncoded() throws {
    let feed = try parse(
      "<rss xmlns:content=\"http://purl.org/rss/1.0/modules/content/\"><channel><title>Show</title><item><description>teaser</description><content:encoded><![CDATA[<p>Full notes.</p>]]></content:encoded><content:encoded>second</content:encoded></item><item><description>only</description></item></channel></rss>"
    )
    #expect(feed.items[0].synopsis == "teaser")
    #expect(feed.items[0].content == "<p>Full notes.</p>")
    #expect(feed.items[1].synopsis == "only")
    #expect(feed.items[1].content == nil)
  }

  @Test("matches content:encoded by namespace URI, not prefix, and never at channel level")
  func contentEncodedNamespace() throws {
    let feed = try parse(
      "<rss xmlns:c=\"http://purl.org/rss/1.0/modules/content/\" xmlns:content=\"urn:other\"><channel><title>Show</title><c:encoded>channel</c:encoded><item><content:encoded>wrong</content:encoded><c:encoded>right</c:encoded></item></channel></rss>"
    )
    #expect(feed.items[0].content == "right")
    #expect(feed.synopsis == nil)
  }

  @Test("an oversized content:encoded drops the field and keeps the feed")
  func oversizedContentDropsField() throws {
    let xml =
      "<rss xmlns:content=\"http://purl.org/rss/1.0/modules/content/\"><channel><title>S</title><item><description>short</description><content:encoded><![CDATA[1234567890]]></content:encoded></item><item><content:encoded>ok</content:encoded></item></channel></rss>"
    let feed = try FeedParser.parseRSS(Data(xml.utf8), limits: FeedParseLimits(maximumStringBytes: 5))
    #expect(feed.items[0].synopsis == "short")
    #expect(feed.items[0].content == nil)
    #expect(feed.items[1].content == "ok")

  }

  @Test("an oversized item description or summary drops the synopsis and keeps the feed")
  func oversizedItemSynopsisDropsField() throws {
    let xml =
      "<rss xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel><title>S</title><item><title>A</title><description><![CDATA[1234567890]]></description></item><item><itunes:summary>1234567890</itunes:summary><description>later</description></item><item><description>ok</description></item></channel></rss>"
    let feed = try FeedParser.parseRSS(Data(xml.utf8), limits: FeedParseLimits(maximumStringBytes: 5))
    #expect(feed.items.map(\.synopsis) == [nil, nil, "ok"])
    #expect(feed.items[0].title == "A")

    let atom =
      "<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>S</title><entry><id>1</id><summary>1234567890</summary></entry></feed>"
    let atomFeed = try FeedParser.parseAtom(Data(atom.utf8), limits: FeedParseLimits(maximumStringBytes: 5))
    #expect(atomFeed.items.map(\.synopsis) == [nil])
  }

  @Test("an oversized channel description still fails the parse")
  func oversizedChannelDescriptionFails() {
    let xml = "<rss><channel><title>S</title><description>1234567890</description></channel></rss>"
    #expect(throws: FeedParseError.limitExceeded(.stringBytes)) {
      try FeedParser.parseRSS(Data(xml.utf8), limits: FeedParseLimits(maximumStringBytes: 5))
    }
  }

  @Test(
    "reads the channel language tag as declared, trimmed",
    arguments: [
      ("en", "en"), ("en-GB", "en-GB"), ("EN-us", "EN-us"), ("fr", "fr"), ("  en-AU\n", "en-AU"),
    ])
  func channelLanguage(declared: String, expected: String) throws {
    let feed = try parse("<rss><channel><title>Show</title><language>\(declared)</language></channel></rss>")
    #expect(feed.language == expected)
  }

  @Test("an empty or missing channel language is absent")
  func absentChannelLanguage() throws {
    #expect(try parse("<rss><channel><title>Show</title><language> </language></channel></rss>").language == nil)
    #expect(try parse("<rss><channel><title>Show</title><language/></channel></rss>").language == nil)
    #expect(try parse("<rss><channel><title>Show</title></channel></rss>").language == nil)
  }

  @Test("only the first plain channel language counts, never an item's or a namespaced one")
  func channelLanguageScope() throws {
    let feed = try parse(
      "<rss xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><channel><title>Show</title><dc:language>de</dc:language><item><language>fr</language></item><language>en</language><language>es</language></channel></rss>"
    )
    #expect(feed.language == "en")
  }

  @Test("an overlong channel language drops the field and keeps the feed")
  func overlongChannelLanguageDropsField() throws {
    let overTag = String(repeating: "a", count: ParsedFeed.maximumLanguageBytes + 1)
    #expect(try parse("<rss><channel><title>S</title><language>\(overTag)</language></channel></rss>").language == nil)

    let xml = "<rss><channel><title>S</title><language>1234567890</language><item><guid>g</guid></item></channel></rss>"
    let feed = try FeedParser.parseRSS(Data(xml.utf8), limits: FeedParseLimits(maximumStringBytes: 5))
    #expect(feed.language == nil)
    #expect(feed.items.map(\.guid) == ["g"])
  }

  @Test("parses Atom item synopsis and season and episode numbers")
  func atomItemFields() throws {
    let feed = try FeedParser.parseAtom(
      Data(
        "<feed xmlns=\"http://www.w3.org/2005/Atom\" xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><title>Show</title><entry><summary><![CDATA[Episode summary]]></summary><itunes:season>3</itunes:season><itunes:episode>4</itunes:episode></entry></feed>"
          .utf8))
    #expect(feed.items[0].synopsis == "Episode summary")
    #expect(feed.items[0].seasonNumber == 3)
    #expect(feed.items[0].episodeNumber == 4)
  }

  @Test("preserves entity text delivered in multiple character chunks")
  func preservesEntities() throws {
    let feed = try parse("<rss><channel><title>A &amp; Host &#8217;s Show</title></channel></rss>")
    #expect(feed.title == "A & Host ’s Show")
  }

  @Test("matches iTunes tags regardless of prefix spelling")
  func matchesNamespaceURI() throws {
    let feed = try parse(
      """
      <rss xmlns:it="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Show</title><it:author>Host</it:author><it:image href="https://example.com/a" /></channel></rss>
      """)
    #expect(feed.author == "Host")
    #expect(feed.artworkURL?.absoluteString == "https://example.com/a")
  }

  @Test("uses the plain RSS image fallback")
  func imageFallback() throws {
    let feed = try parse(
      "<rss><channel><title>Show</title><image><url>https://example.com/a</url></image></channel></rss>")
    #expect(feed.artworkURL?.absoluteString == "https://example.com/a")
  }

  @Test("captures CDATA text and keeps its markup literal")
  func capturesCDATA() throws {
    let feed = try parse(
      "<rss><channel><title>Show</title><description><![CDATA[Bold & <i>brash</i>]]></description></channel></rss>"
    )
    #expect(feed.synopsis == "Bold & <i>brash</i>")
  }

  @Test("accepts DTD-looking text inside CDATA")
  func acceptsDTDLookingCDATA() throws {
    let xml = """
      <rss version="2.0">
        <channel>
          <title>My Podcast</title>
          <description><![CDATA[<!DOCTYPE html><p>Show notes about HTML</p>]]></description>
          <item><guid>one</guid><title>First</title><enclosure url="https://example.com/one.mp3" type="audio/mpeg" length="1234" /></item>
        </channel>
      </rss>
      """

    let feed = try FeedParser.parse(Data(xml.utf8))
    #expect(feed.synopsis == "<!DOCTYPE html><p>Show notes about HTML</p>")
    #expect(feed.items.count == 1)
  }

  @Test("accepts DTD-looking text in an ordinary element")
  func acceptsDTDLookingElementText() throws {
    let xml = """
      <rss version="2.0">
        <channel>
          <title>My Podcast</title>
          <description>&lt;!ENTITY example&gt; Show notes about entities</description>
        </channel>
      </rss>
      """

    let feed = try FeedParser.parse(Data(xml.utf8))
    #expect(feed.synopsis == "<!ENTITY example> Show notes about entities")
  }

  @Test("enforces the string byte limit on CDATA text")
  func cdataStringLimit() {
    let xml = "<rss><channel><title>S</title><description><![CDATA[123456]]></description></channel></rss>"
    #expect(throws: FeedParseError.limitExceeded(.stringBytes)) {
      try FeedParser.parseRSS(Data(xml.utf8), limits: FeedParseLimits(maximumStringBytes: 5))
    }
  }

  @Test("ignores an image url inside an item")
  func itemImageDoesNotBecomeArtwork() throws {
    let feed = try parse(
      "<rss><channel><title>Show</title><item><image><url>https://example.com/item.jpg</url></image></item></channel></rss>"
    )
    #expect(feed.artworkURL == nil)
  }

  @Test("falls back to the RSS image when the iTunes image href is invalid")
  func invalidITunesImageFallsBack() throws {
    let feed = try parse(
      """
      <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>Show</title><itunes:image href="not a url" /><image><url>https://example.com/a</url></image></channel></rss>
      """)
    #expect(feed.artworkURL?.absoluteString == "https://example.com/a")
  }

  @Test("item titles do not clobber channel titles and later channel title maps")
  func titleScopes() throws {
    let feed = try parse("<rss><channel><item><title>Episode</title></item><title>Show</title></channel></rss>")
    #expect(feed.title == "Show")
    #expect(feed.items[0].title == "Episode")
  }

  @Test("rejects missing channel title")
  func missingTitle() {
    #expect(throws: FeedParseError.missingChannelTitle) {
      try FeedParser.parseRSS(Data("<rss><channel><description>No title</description></channel></rss>".utf8))
    }
  }

  @Test("rejects a non RSS root")
  func nonRSS() {
    #expect(throws: FeedParseError.unrecognizedRoot) {
      try FeedParser.parseRSS(Data("<feed><title>Not RSS</title></feed>".utf8))
    }
  }

  @Test("reports malformed XML")
  func malformedXML() {
    #expect(throws: FeedParseError.self) {
      try FeedParser.parseRSS(Data("<rss><channel><title>Unclosed</channel></rss>".utf8))
    }
  }

  @Test("enforces the item limit during parsing")
  func itemLimit() {
    let xml = "<rss><channel><title>Show</title>" + String(repeating: "<item />", count: 4) + "</channel></rss>"
    #expect(throws: FeedParseError.limitExceeded(.items)) {
      try FeedParser.parseRSS(Data(xml.utf8), limits: FeedParseLimits(maximumItems: 3))
    }
  }

  @Test("enforces the string byte limit during text accumulation")
  func stringLimit() {
    let xml = "<rss><channel><title>123456</title></channel></rss>"
    #expect(throws: FeedParseError.limitExceeded(.stringBytes)) {
      try FeedParser.parseRSS(Data(xml.utf8), limits: FeedParseLimits(maximumStringBytes: 5))
    }
  }

  @Test("enforces the element depth limit")
  func depthLimit() {
    let xml =
      "<rss><channel><title>Show</title>" + String(repeating: "<x>", count: 4) + "deep"
      + String(repeating: "</x>", count: 4) + "</channel></rss>"
    #expect(throws: FeedParseError.limitExceeded(.elementDepth)) {
      try FeedParser.parseRSS(Data(xml.utf8), limits: FeedParseLimits(maximumElementDepth: 4))
    }
  }

  @Test("keeps items with invalid enclosure URLs and malformed lengths")
  func invalidEnclosureValues() throws {
    let feed = try parse(
      """
      <rss><channel><title>Show</title><item><title>Episode</title><enclosure url="relative.mp3" length="not-a-number" /></item></channel></rss>
      """)
    #expect(feed.items.count == 1)
    #expect(feed.items[0].enclosure == nil)
  }

  @Test("accepts only positive enclosure lengths in RSS and Atom")
  func enclosureLengths() throws {
    let rss = try parse(
      """
      <rss><channel><title>RSS</title>
        <item><enclosure url="https://example.com/positive.mp3" length="42" /></item>
        <item><enclosure url="https://example.com/zero.mp3" length="0" /></item>
        <item><enclosure url="https://example.com/negative.mp3" length="-1" /></item>
        <item><enclosure url="https://example.com/malformed.mp3" length="many" /></item>
      </channel></rss>
      """)
    #expect(rss.items.map { $0.enclosure?.lengthBytes } == [42, nil, nil, nil])

    let atom = try FeedParser.parseAtom(
      Data(
        """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Atom</title>
          <entry><link rel="enclosure" href="https://example.com/positive.mp3" length="42" /></entry>
          <entry><link rel="enclosure" href="https://example.com/zero.mp3" length="0" /></entry>
          <entry><link rel="enclosure" href="https://example.com/negative.mp3" length="-1" /></entry>
          <entry><link rel="enclosure" href="https://example.com/malformed.mp3" length="many" /></entry>
        </feed>
        """.utf8))
    #expect(atom.items.map { $0.enclosure?.lengthBytes } == [42, nil, nil, nil])
  }

  /// A feed can name any length of enclosure URL. The attribute is capped like every other string
  /// the parser retains, and the failure is fatal rather than silently dropping the episode.
  @Test("an enclosure URL over the string byte limit fails the parse")
  func oversizedEnclosureURLFailsTheParse() {
    let oversizedURL =
      "https://example.com/"
      + String(repeating: "e", count: FeedParseLimits.standard.maximumStringBytes + 1) + ".mp3"
    let xml =
      "<rss><channel><title>Show</title><item><enclosure url=\"\(oversizedURL)\" /></item></channel></rss>"

    #expect(throws: FeedParseError.limitExceeded(.stringBytes)) {
      try FeedParser.parseRSS(
        Data(xml.utf8), limits: FeedParseLimits(maximumStringBytes: FeedParseLimits.standard.maximumStringBytes))
    }
  }

  @Test("rejects credential-bearing enclosures and artwork in RSS and Atom")
  func rejectsCredentialBearingURLs() throws {
    let rss = try FeedParser.parseRSS(
      Data(
        """
        <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>RSS</title><itunes:image href="https://art-user:art-pass@example.com/art.jpg" /><item><enclosure url="https://audio-user:audio-pass@example.com/episode.mp3" /></item></channel></rss>
        """.utf8))
    #expect(rss.artworkURL == nil)
    #expect(rss.items[0].enclosure == nil)

    let atom = try FeedParser.parseAtom(
      Data(
        """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Atom</title><logo>https://art-user:art-pass@example.com/logo.png</logo><entry><link rel="enclosure" href="https://audio-user:audio-pass@example.com/episode.mp3" /></entry></feed>
        """.utf8))
    #expect(atom.artworkURL == nil)
    #expect(atom.items[0].enclosure == nil)
  }

  @Test("reads an item's first iTunes image href as its artwork")
  func itemArtworkReadsFirstITunesImage() throws {
    let feed = try parse(
      "<rss xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel><title>Show</title><item><guid>one</guid><itunes:image href=\"https://example.com/ep.jpg\" /></item><item><guid>two</guid></item></channel></rss>"
    )
    #expect(feed.items[0].artworkURL?.absoluteString == "https://example.com/ep.jpg")
    #expect(feed.items[1].artworkURL == nil)
  }

  @Test("the first item iTunes image wins, even when it is invalid")
  func itemArtworkFirstOccurrenceWins() throws {
    let feed = try parse(
      "<rss xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel><title>Show</title><item><itunes:image href=\"https://example.com/first.jpg\" /><itunes:image href=\"https://example.com/second.jpg\" /></item><item><itunes:image href=\"ftp://example.com/bad.jpg\" /><itunes:image href=\"https://example.com/second.jpg\" /></item></channel></rss>"
    )
    #expect(feed.items[0].artworkURL?.absoluteString == "https://example.com/first.jpg")
    #expect(feed.items[1].artworkURL == nil)
  }

  @Test("an oversized item image href drops the artwork and keeps the feed")
  func oversizedItemArtworkDropsField() throws {
    let xml =
      "<rss xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel><title>S</title><item><guid>a</guid><itunes:image href=\"https://example.com/long.jpg\" /></item><item><guid>b</guid></item></channel></rss>"
    let feed = try FeedParser.parseRSS(Data(xml.utf8), limits: FeedParseLimits(maximumStringBytes: 5))
    #expect(feed.items.map(\.guid) == ["a", "b"])
    #expect(feed.items.map(\.artworkURL) == [nil, nil])
    #expect(feed.artworkURL == nil)
  }

  @Test(
    "rejects non-HTTP(S) and credential-bearing item image hrefs",
    arguments: [
      "ftp://example.com/ep.jpg",
      "file:///tmp/ep.jpg",
      "https://art-user:art-pass@example.com/ep.jpg",
    ])
  func itemArtworkRejectsUnsafeURLs(href: String) throws {
    let feed = try parse(
      "<rss xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel><title>Show</title><item><itunes:image href=\"\(href)\" /></item></channel></rss>"
    )
    #expect(feed.items[0].artworkURL == nil)
  }

  @Test("item artwork never replaces or inherits the channel image")
  func itemArtworkIsScopedToItsItem() throws {
    let feed = try parse(
      "<rss xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><channel><title>Show</title><itunes:image href=\"https://example.com/channel.jpg\" /><item><itunes:image href=\"https://example.com/item.jpg\" /></item><item><guid>plain</guid></item></channel></rss>"
    )
    #expect(feed.artworkURL?.absoluteString == "https://example.com/channel.jpg")
    #expect(feed.items[0].artworkURL?.absoluteString == "https://example.com/item.jpg")
    #expect(feed.items[1].artworkURL == nil)
  }

  @Test("an Atom entry's image is not read as artwork")
  func atomEntryHasNoArtwork() throws {
    let feed = try FeedParser.parseAtom(
      Data(
        "<feed xmlns=\"http://www.w3.org/2005/Atom\" xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"><title>Atom</title><entry><id>one</id><itunes:image href=\"https://example.com/ep.jpg\" /></entry></feed>"
          .utf8))
    #expect(feed.items.count == 1)
    #expect(feed.items[0].artworkURL == nil)
    #expect(feed.artworkURL == nil)
  }

  private func parse(_ xml: String) throws -> ParsedFeed {
    try FeedParser.parseRSS(Data(xml.utf8))
  }
}
