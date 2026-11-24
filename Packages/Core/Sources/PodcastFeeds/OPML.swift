import Foundation

public struct OPMLDocument: Sendable, Equatable {
  public let title: String?
  public let entries: [OPMLFeedEntry]

  public init(title: String?, entries: [OPMLFeedEntry]) {
    self.title = title
    self.entries = entries
  }
}

public struct OPMLFeedEntry: Sendable, Equatable {
  public let title: String?
  public let feedURL: URL
  public let siteURL: URL?

  public init(title: String?, feedURL: URL, siteURL: URL?) {
    self.title = title
    self.feedURL = feedURL
    self.siteURL = siteURL
  }
}

public enum OPMLSerializationError: Error, Sendable, Equatable {
  case invalidURL
}

public enum OPML {
  /// Matches the bounded feed-document transport. A local import must not become an unbounded XML
  /// allocation merely because it arrived through the file picker rather than HTTP.
  public static let maximumDocumentBytes = FeedFetchClient.maximumFeedBytes

  public static func parse(_ data: Data, limits: FeedParseLimits = .standard) throws -> OPMLDocument {
    try Task.checkCancellation()
    guard data.count <= maximumDocumentBytes else {
      throw FeedParseError.limitExceeded(.documentBytes)
    }
    guard FeedParser.containsDOCTYPEInProlog(data) == false else {
      throw FeedParseError.dtdNotAllowed
    }
    try Task.checkCancellation()
    final class Delegate: NSObject, XMLParserDelegate {
      enum TextField {
        case documentTitle
      }

      struct Frame {
        let localName: String
        let namespaceURI: String
        let textField: TextField?
        var text: String
      }

      let limits: FeedParseLimits
      var frames: [Frame] = []
      var entries: [OPMLFeedEntry] = []
      var documentTitle: String?
      var documentTitleSeen = false
      var rootIsOPML = false
      var failure: FeedParseError?
      var elementCount = 0
      var cancelled = false

      init(limits: FeedParseLimits) {
        self.limits = limits
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
          url.user == nil, url.password == nil
        else { return nil }
        return url
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
        guard elementCount < limits.maximumElements else {
          fail(.limitExceeded(.elementCount), parser: parser)
          return
        }
        elementCount += 1
        guard frames.count < limits.maximumElementDepth else {
          fail(.limitExceeded(.elementDepth), parser: parser)
          return
        }

        if frames.isEmpty {
          rootIsOPML = uri.isEmpty && elementName == "opml"
        }

        for value in attributeDict.values where value.utf8.count > limits.maximumStringBytes {
          fail(.limitExceeded(.stringBytes), parser: parser)
          return
        }

        let parent = frames.last
        // The document title comes only from the root-level <head>; a <head> nested
        // inside a body outline must not supply it.
        let textField: TextField? =
          parent.map {
            matches($0, namespaceURI: "", localName: "head") && frames.count == 2 && uri.isEmpty
              && elementName == "title" && documentTitleSeen == false
              ? .documentTitle : nil
          } ?? nil

        if uri.isEmpty, elementName == "outline",
          frames.contains(where: { matches($0, namespaceURI: "", localName: "body") })
        {
          if let feedURL = validHTTPURL(attributeDict["xmlUrl"]) {
            guard entries.count < limits.maximumItems else {
              fail(.limitExceeded(.items), parser: parser)
              return
            }
            entries.append(
              OPMLFeedEntry(
                title: trimmed(attributeDict["text"] ?? "") ?? trimmed(attributeDict["title"] ?? ""),
                feedURL: feedURL, siteURL: validHTTPURL(attributeDict["htmlUrl"])))
          }
        }

        frames.append(Frame(localName: elementName, namespaceURI: uri, textField: textField, text: ""))
      }

      func appendText(_ string: String, parser: XMLParser) {
        guard failure == nil, frames.isEmpty == false else { return }
        guard let index = frames.lastIndex(where: { $0.textField != nil }) else { return }
        let nextBytes = frames[index].text.utf8.count + string.utf8.count
        guard nextBytes <= limits.maximumStringBytes else {
          fail(.limitExceeded(.stringBytes), parser: parser)
          return
        }
        frames[index].text.append(string)
      }

      func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string, parser: parser)
      }

      func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
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
        let value = trimmed(frame.text)
        if frame.textField == .documentTitle {
          documentTitleSeen = true
          documentTitle = value
        }
      }
    }

    let delegate = Delegate(limits: limits)
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.shouldProcessNamespaces = true
    parser.shouldResolveExternalEntities = false
    parser.externalEntityResolvingPolicy = .never
    guard parser.parse() else {
      if delegate.cancelled || Task.isCancelled { throw CancellationError() }
      if let failure = delegate.failure { throw failure }
      throw FeedParseError.malformedXML(line: parser.lineNumber, column: parser.columnNumber)
    }
    try Task.checkCancellation()
    guard delegate.rootIsOPML else { throw FeedParseError.unrecognizedRoot }
    return OPMLDocument(title: delegate.documentTitle, entries: delegate.entries)
  }

  public static func serialize(_ document: OPMLDocument) -> Data {
    func escaped(_ value: String) -> String {
      value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
    }

    var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    xml += "<opml version=\"2.0\"><head>"
    if let title = document.title {
      xml += "<title>\(escaped(title))</title>"
    }
    xml += "</head><body>"
    for entry in document.entries {
      xml += "<outline type=\"rss\""
      if let title = entry.title { xml += " text=\"\(escaped(title))\"" }
      xml += " xmlUrl=\"\(escaped(entry.feedURL.absoluteString))\""
      if let siteURL = entry.siteURL { xml += " htmlUrl=\"\(escaped(siteURL.absoluteString))\"" }
      xml += "/>"
    }
    xml += "</body></opml>"
    return Data(xml.utf8)
  }

  /// Checked export keeps locally assembled subscription lists inside the same resource envelope
  /// as imported OPML. The legacy serializer remains available for already-bounded fixtures.
  public static func serializeChecked(
    _ document: OPMLDocument, limits: FeedParseLimits = .standard
  ) throws -> Data {
    guard document.entries.count <= limits.maximumItems else {
      throw FeedParseError.limitExceeded(.items)
    }
    let strings =
      [document.title]
      + document.entries.flatMap {
        [$0.title, $0.feedURL.absoluteString, $0.siteURL?.absoluteString]
      }
    guard strings.compactMap({ $0 }).allSatisfy({ $0.utf8.count <= limits.maximumStringBytes }) else {
      throw FeedParseError.limitExceeded(.stringBytes)
    }
    for entry in document.entries {
      guard validExportURL(entry.feedURL), entry.siteURL.map(validExportURL) ?? true else {
        throw OPMLSerializationError.invalidURL
      }
    }
    let data = serialize(document)
    guard data.count <= maximumDocumentBytes else {
      throw FeedParseError.limitExceeded(.documentBytes)
    }
    return data
  }

  private static func validExportURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return (scheme == "http" || scheme == "https") && url.host?.isEmpty == false
      && url.user == nil && url.password == nil
  }
}
