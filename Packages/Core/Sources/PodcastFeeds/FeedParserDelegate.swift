import Foundation

/// The `XMLParser` delegate behind `FeedParser`: element bookkeeping, limits, cancellation and the
/// feed and item builders. One instance serves one synchronous `XMLParser.parse()` call and is
/// never shared. Which element feeds which field lives in `FeedParserDelegate+Fields.swift`.
final class FeedParserDelegate: NSObject, XMLParserDelegate {
  struct Frame {
    let localName: String
    let namespaceURI: String
    let textField: TextField?
    var text: String
    var overflowed = false
  }

  struct ItemBuilder {
    var guid: String?
    var title: String?
    var enclosure: ParsedEnclosure?
    var pubDate: String?
    var durationText: String?
    var synopsis: String?
    var content: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var artworkURL: URL?
    var seenGuid = false
    var seenTitle = false
    var seenEnclosure = false
    var seenPubDate = false
    var seenDuration = false
    var seenSynopsis = false
    var seenContent = false
    var seenSeasonNumber = false
    var seenEpisodeNumber = false
    var seenArtwork = false
  }

  let limits: FeedParseLimits
  let onStartElement: (@Sendable (Int) -> Void)?
  var frames: [Frame] = []
  var items: [ParsedFeedItem] = []
  var currentItem: ItemBuilder?
  var channelTitle: String?
  var author: String?
  var artworkURL: URL?
  var synopsis: String?
  var imageURL: URL?
  var language: String?
  var channelTitleSeen = false
  var authorSeen = false
  var artworkSeen = false
  var synopsisSeen = false
  var imageURLSeen = false
  var languageSeen = false
  var hasChannel = false
  var rootKind: FeedParser.RootKind?
  var failure: FeedParseError?
  var elementCount = 0
  var atomAuthorSeen = false
  var atomLogoSeen = false
  var atomIconSeen = false
  var atomPublishedSeen = false
  var atomUpdatedSeen = false
  var cancelled = false

  init(limits: FeedParseLimits, onStartElement: (@Sendable (Int) -> Void)?) {
    self.limits = limits
    self.onStartElement = onStartElement
  }

  func matches(_ frame: Frame, namespaceURI: String, localName: String) -> Bool {
    frame.namespaceURI == namespaceURI && frame.localName == localName
  }

  func trimmed(_ text: String) -> String? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  func validHTTPURL(_ string: String?) -> URL? {
    guard let string, let url = URL(string: string), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https", url.host?.isEmpty == false,
      url.user?.isEmpty != false, url.password?.isEmpty != false
    else { return nil }
    return url
  }

  func parsedEnclosure(
    urlString: String?, attributes: [String: String], parser: XMLParser
  ) -> ParsedEnclosure? {
    let type = attributes["type"].flatMap(trimmed)
    let length = attributes["length"].flatMap(Int64.init).flatMap { $0 > 0 ? $0 : nil }
    let relevantAttributes = [urlString, attributes["type"], attributes["length"]].compactMap { $0 }
    guard relevantAttributes.contains(where: { $0.utf8.count > limits.maximumStringBytes }) == false else {
      fail(.limitExceeded(.stringBytes), parser: parser)
      return nil
    }
    guard let url = validHTTPURL(urlString) else { return nil }
    return ParsedEnclosure(url: url, type: type, lengthBytes: length)
  }

  func appendCurrentItem() {
    guard let item = currentItem else { return }
    items.append(
      ParsedFeedItem(
        guid: item.guid, title: item.title, enclosure: item.enclosure, pubDate: item.pubDate,
        durationText: item.durationText, synopsis: item.synopsis, content: item.content,
        seasonNumber: item.seasonNumber,
        episodeNumber: item.episodeNumber, artworkURL: item.artworkURL))
    currentItem = nil
  }

  func fail(_ error: FeedParseError, parser: XMLParser) {
    if failure == nil { failure = error }
    parser.abortParsing()
  }

  func stopIfCancelled(_ parser: XMLParser) -> Bool {
    guard Task.isCancelled else { return false }
    cancelled = true
    parser.abortParsing()
    return true
  }

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
  ) {
    guard failure == nil, stopIfCancelled(parser) == false else { return }
    let uri = namespaceURI ?? ""
    let localName = elementName
    guard elementCount < limits.maximumElements else {
      fail(.limitExceeded(.elementCount), parser: parser)
      return
    }
    elementCount += 1
    onStartElement?(elementCount)
    guard stopIfCancelled(parser) == false else { return }
    guard frames.count < limits.maximumElementDepth else {
      fail(.limitExceeded(.elementDepth), parser: parser)
      return
    }

    if frames.isEmpty {
      rootKind =
        uri.isEmpty && localName == "rss"
        ? .rss : (uri == Self.atomNamespace && localName == "feed" ? .atom : nil)
    }
    let parent = frames.last
    let isChannel = rootKind == .rss && frames.count == 1 && uri.isEmpty && localName == "channel"
    if isChannel { hasChannel = true }

    let isAtomFeed = rootKind == .atom && frames.count == 1 && uri == Self.atomNamespace && localName == "feed"

    if isChannel == false, currentItem == nil,
      parent.map({ matches($0, namespaceURI: "", localName: "channel") }) == true,
      uri.isEmpty, localName == "item"
    {
      guard items.count < limits.maximumItems else {
        fail(.limitExceeded(.items), parser: parser)
        return
      }
      currentItem = ItemBuilder()
    }

    if isAtomFeed == false, currentItem == nil,
      parent.map({ matches($0, namespaceURI: Self.atomNamespace, localName: "feed") }) == true,
      rootKind == .atom, uri == Self.atomNamespace, localName == "entry"
    {
      guard items.count < limits.maximumItems else {
        fail(.limitExceeded(.items), parser: parser)
        return
      }
      currentItem = ItemBuilder()
      atomPublishedSeen = false
      atomUpdatedSeen = false
    }

    if let item = currentItem, parent.map({ matches($0, namespaceURI: "", localName: "item") }) == true,
      uri.isEmpty, localName == "enclosure", item.seenEnclosure == false
    {
      currentItem?.seenEnclosure = true
      let urlString = attributeDict["url"]
      currentItem?.enclosure = parsedEnclosure(
        urlString: urlString, attributes: attributeDict, parser: parser)
      guard failure == nil else { return }
    }

    if let item = currentItem,
      rootKind == .atom,
      parent.map({ matches($0, namespaceURI: Self.atomNamespace, localName: "entry") }) == true,
      uri == Self.atomNamespace, localName == "link", item.seenEnclosure == false,
      attributeDict["rel"] == "enclosure"
    {
      currentItem?.seenEnclosure = true
      let href = attributeDict["href"]
      currentItem?.enclosure = parsedEnclosure(
        urlString: href, attributes: attributeDict, parser: parser)
      guard failure == nil else { return }
    }

    if let item = currentItem, parent.map({ matches($0, namespaceURI: "", localName: "item") }) == true,
      uri == Self.iTunesNamespace, localName == "image", item.seenArtwork == false
    {
      currentItem?.seenArtwork = true
      // Unlike the channel image, an oversized item image drops the field rather than failing the
      // feed: episode art is optional, and one bad item must not stop the feed refreshing.
      if let href = attributeDict["href"], href.utf8.count <= limits.maximumStringBytes {
        currentItem?.artworkURL = validHTTPURL(href)
      }
    }

    if parent.map({ matches($0, namespaceURI: "", localName: "channel") }) == true,
      uri == Self.iTunesNamespace, localName == "image", artworkSeen == false
    {
      artworkSeen = true
      let href = attributeDict["href"]
      if let href, href.utf8.count > limits.maximumStringBytes {
        fail(.limitExceeded(.stringBytes), parser: parser)
        return
      }
      artworkURL = validHTTPURL(href)
    }

    let textField = fieldForStart(parent: parent, localName: localName, namespaceURI: uri)
    frames.append(Frame(localName: localName, namespaceURI: uri, textField: textField, text: ""))
  }

  func appendText(_ string: String, parser: XMLParser) {
    guard failure == nil, stopIfCancelled(parser) == false, frames.isEmpty == false else { return }
    guard let index = frames.lastIndex(where: { $0.textField != nil }) else { return }
    guard frames[index].overflowed == false else { return }
    let nextBytes = frames[index].text.utf8.count + string.utf8.count
    guard nextBytes <= limits.maximumStringBytes else {
      // See `ParsedFeedItem.synopsis`, `.content` and `ParsedFeed.language`: dropped, not fatal,
      // when oversized.
      if let field = frames[index].textField, Self.droppableTextFields.contains(field) {
        frames[index].overflowed = true
        frames[index].text = ""
        return
      }
      fail(.limitExceeded(.stringBytes), parser: parser)
      return
    }
    frames[index].text.append(string)
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    appendText(string, parser: parser)
  }

  /// CDATA arrives through its own callback, never `foundCharacters`. Real feeds routinely wrap
  /// descriptions in CDATA, so dropping this callback drops their synopses.
  func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
    guard stopIfCancelled(parser) == false else { return }
    appendText(String(decoding: cdataBlock, as: UTF8.self), parser: parser)
  }

  func parser(
    _ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?
  ) {
    fail(.dtdNotAllowed, parser: parser)
  }

  func parser(
    _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
    publicID: String?, systemID: String?
  ) {
    fail(.dtdNotAllowed, parser: parser)
  }

  func parser(
    _ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String,
    publicID: String?, systemID: String?, notationName: String?
  ) {
    fail(.dtdNotAllowed, parser: parser)
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    guard failure == nil, stopIfCancelled(parser) == false, let frame = frames.popLast() else { return }
    guard frame.localName == elementName else { return }
    let value = trimmed(frame.text)
    recordText(value, overflowed: frame.overflowed, for: frame.textField)

    if frame.namespaceURI.isEmpty, frame.localName == "item",
      frames.last.map({ matches($0, namespaceURI: "", localName: "channel") }) == true
    {
      appendCurrentItem()
    }
    if frame.namespaceURI.isEmpty, frame.localName == "channel", hasChannel,
      frames.last?.localName == "rss", rootKind == .rss, artworkURL == nil
    {
      artworkURL = imageURL
    }
    if frame.namespaceURI == Self.atomNamespace, frame.localName == "entry",
      frames.last.map({ matches($0, namespaceURI: Self.atomNamespace, localName: "feed") }) == true
    {
      appendCurrentItem()
    }
  }

  static let droppableTextFields: Set<TextField> = [
    .itemSynopsis, .atomItemSynopsis, .itemContent, .language,
  ]
  static let iTunesNamespace = "http://www.itunes.com/dtds/podcast-1.0.dtd"
  static let atomNamespace = "http://www.w3.org/2005/Atom"
  static let contentNamespace = "http://purl.org/rss/1.0/modules/content/"
}
