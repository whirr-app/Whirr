import Foundation

/// The bounded channel-level values extracted from one RSS feed.
public struct ParsedFeed: Sendable, Equatable {
  public let title: String
  public let author: String?
  public let artworkURL: URL?
  public let synopsis: String?
  /// The channel's first RSS `<language>`, trimmed but otherwise as declared (`en-GB`, `EN-us`).
  /// `nil` when absent, empty, or longer than `maximumLanguageBytes`; like `content:encoded`, an
  /// oversized value drops the field rather than failing the feed.
  public let language: String?
  public let items: [ParsedFeedItem]

  /// Generously above BCP 47's 35-character practical length; anything longer is not a tag.
  public static let maximumLanguageBytes = 64

  public init(
    title: String, author: String?, artworkURL: URL?, synopsis: String?, language: String? = nil,
    items: [ParsedFeedItem]
  ) {
    self.title = title
    self.author = author
    self.artworkURL = artworkURL
    self.synopsis = synopsis
    self.language = language
    self.items = items
  }
}

/// Raw item metadata extracted without interpreting publication dates.
public struct ParsedFeedItem: Sendable, Equatable {
  public let guid: String?
  public let title: String?
  public let enclosure: ParsedEnclosure?
  public let pubDate: String?
  public let durationText: String?
  /// The item's first `<description>` or `<itunes:summary>` (Atom: `<summary>`). Like `content`, a
  /// value over the string cap drops the field rather than failing the feed: community feeds can
  /// carry one episode with very long CDATA show notes, and that must not refuse the whole show.
  public let synopsis: String?
  /// The item's first RSS `<content:encoded>`, usually the richest form of the show notes, as
  /// HTML. `nil` when absent, empty, or over the string cap. Unlike other bounded fields, an
  /// oversized value drops the field rather than failing the feed, since `synopsis` still stands
  /// in for it.
  public let content: String?
  public let seasonNumber: Int?
  public let episodeNumber: Int?
  /// The item's first `<itunes:image href>`, nil when absent, non-HTTP(S), credentialed, or over the
  /// string cap. Like `content`, an oversized value drops the field rather than failing the feed.
  public let artworkURL: URL?

  public init(
    guid: String?, title: String?, enclosure: ParsedEnclosure?, pubDate: String?, durationText: String?,
    synopsis: String? = nil, content: String? = nil, seasonNumber: Int? = nil, episodeNumber: Int? = nil,
    artworkURL: URL? = nil
  ) {
    self.guid = guid
    self.title = title
    self.enclosure = enclosure
    self.pubDate = pubDate
    self.durationText = durationText
    self.synopsis = synopsis
    self.content = content
    self.seasonNumber = seasonNumber
    self.episodeNumber = episodeNumber
    self.artworkURL = artworkURL
  }
}

/// An enclosure with a validated absolute HTTP(S) URL.
public struct ParsedEnclosure: Sendable, Equatable {
  public let url: URL
  public let type: String?
  public let lengthBytes: Int64?

  public init(url: URL, type: String?, lengthBytes: Int64?) {
    self.url = url
    self.type = type
    self.lengthBytes = lengthBytes
  }
}

/// Resource limits enforced while the SAX parser is receiving XML callbacks.
public struct FeedParseLimits: Sendable, Equatable {
  public static let standard = FeedParseLimits()

  public let maximumItems: Int
  public let maximumElements: Int
  public let maximumStringBytes: Int
  public let maximumElementDepth: Int

  public init(
    maximumItems: Int = 20_000,
    maximumElements: Int = 250_000,
    maximumStringBytes: Int = 16 * 1024,
    maximumElementDepth: Int = 64
  ) {
    self.maximumItems = maximumItems
    self.maximumElements = maximumElements
    self.maximumStringBytes = maximumStringBytes
    self.maximumElementDepth = maximumElementDepth
  }
}

/// The bounded resource whose configured limit was exceeded.
public enum FeedParseLimit: Sendable, Equatable {
  case documentBytes
  case items
  case elementCount
  case stringBytes
  case elementDepth
}

/// Failures produced by RSS validation, XML parsing, or an active parse limit.
public enum FeedParseError: Error, Sendable, Equatable {
  case malformedXML(line: Int, column: Int)
  case dtdNotAllowed
  case unrecognizedRoot
  case limitExceeded(FeedParseLimit)
  case missingChannelTitle
}

/// Parses RSS 2.0 data synchronously without resolving external entities.
public enum FeedParser {
  /// The feed transport's hard document ceiling. This guard runs before Foundation receives the
  /// input, so one hostile attribute, text node, or CDATA block cannot exceed the admitted body.
  public static let maximumDocumentBytes = FeedFetchClient.maximumFeedBytes

  enum RootKind {
    case rss
    case atom
  }

  /// Parses a bounded RSS document from raw response bytes.
  public static func parseRSS(_ data: Data, limits: FeedParseLimits = .standard) throws -> ParsedFeed {
    try parse(data, limits: limits, expectedRoot: .rss)
  }

  /// Parses a bounded Atom document from raw response bytes.
  public static func parseAtom(_ data: Data, limits: FeedParseLimits = .standard) throws -> ParsedFeed {
    try parse(data, limits: limits, expectedRoot: .atom)
  }

  /// Parses a bounded RSS or Atom document from raw response bytes.
  public static func parse(_ data: Data, limits: FeedParseLimits = .standard) throws -> ParsedFeed {
    try parse(data, limits: limits, expectedRoot: nil)
  }

  static func parseForTesting(
    _ data: Data, limits: FeedParseLimits = .standard,
    onXMLParserCreation: (@Sendable () -> Void)? = nil,
    onStartElement: @escaping @Sendable (Int) -> Void
  ) throws -> ParsedFeed {
    try parse(
      data, limits: limits, expectedRoot: nil,
      onXMLParserCreation: onXMLParserCreation,
      onStartElement: onStartElement)
  }

  static func containsDOCTYPEInProlog(_ data: Data) -> Bool {
    let rawBytes = Array(data)
    let bytes: [UInt8]
    if rawBytes.starts(with: [0xFF, 0xFE]) {
      bytes = stride(from: 2, to: rawBytes.count, by: 2).map { rawBytes[$0] }
    } else if rawBytes.starts(with: [0xFE, 0xFF]) {
      bytes = stride(from: 3, to: rawBytes.count, by: 2).map { rawBytes[$0] }
    } else if rawBytes.starts(with: [0xEF, 0xBB, 0xBF]) {
      bytes = Array(rawBytes.dropFirst(3))
    } else if isSixteenBit(rawBytes) {
      bytes = stride(from: rawBytes[1] == 0 ? 0 : 1, to: rawBytes.count, by: 2).map { rawBytes[$0] }
    } else {
      bytes = rawBytes
    }
    return prologDOCTYPEStart(in: bytes) != nil
  }

  /// A prolog DOCTYPE without an internal subset declares nothing the parser could expand, and its
  /// external DTD is never loaded. XSLT site generators emit one (`<!DOCTYPE rss SYSTEM
  /// "about:legacy-compat">`), so it is overwritten with spaces, keeping line breaks so error
  /// positions hold, and `XMLParser` still never sees a DTD. Nil means reject: an internal subset,
  /// an unterminated declaration, a second DOCTYPE, or a UTF-16 document, where a blanked byte
  /// would not be a space.
  static func blankingBareDOCTYPE(_ data: Data) -> Data? {
    var bytes = Array(data)
    guard bytes.starts(with: [0xFF, 0xFE]) == false, bytes.starts(with: [0xFE, 0xFF]) == false,
      isSixteenBit(bytes) == false, let start = prologDOCTYPEStart(in: bytes)
    else { return nil }

    var end = start + "<!DOCTYPE".utf8.count
    var quote: UInt8?
    while end < bytes.count {
      let byte = bytes[end]
      if let open = quote {
        if byte == open { quote = nil }
      } else if byte == 0x22 || byte == 0x27 {
        quote = byte
      } else if byte == 0x5B {
        return nil  // `[` opens an internal subset.
      } else if byte == 0x3E {
        break
      }
      end += 1
    }
    guard end < bytes.count else { return nil }

    for index in start...end where bytes[index] != 0x0A && bytes[index] != 0x0D {
      bytes[index] = 0x20
    }
    let blanked = Data(bytes)
    return containsDOCTYPEInProlog(blanked) ? nil : blanked
  }

  private static func isSixteenBit(_ bytes: [UInt8]) -> Bool {
    bytes.count > 1 && (bytes[1] == 0 || bytes[0] == 0)
  }

  /// The index of the prolog's `<!DOCTYPE`, scanning past comments and processing instructions
  /// and stopping at the first element.
  private static func prologDOCTYPEStart(in bytes: [UInt8]) -> Int? {
    var index = 0
    while index < bytes.count {
      guard bytes[index] == 0x3C else {
        index += 1
        continue
      }

      if bytes[index...].starts(with: Array("<!--".utf8)) {
        guard let end = bytes[index...].firstRange(of: Array("-->".utf8))?.upperBound else {
          return nil
        }
        index = end
        continue
      }
      if bytes[index...].starts(with: Array("<?".utf8)) {
        guard let end = bytes[index...].firstRange(of: Array("?>".utf8))?.upperBound else {
          return nil
        }
        index = end
        continue
      }
      if bytes[index...].starts(with: Array("<!DOCTYPE".utf8)) {
        return index
      }
      if index + 1 < bytes.count,
        bytes[index + 1] == 0x21 || bytes[index + 1] == 0x2F || bytes[index + 1] == 0x3F
      {
        index += 1
        continue
      }
      if index + 1 < bytes.count,
        bytes[index + 1] == 0x3A || bytes[index + 1] == 0x5F
          || bytes[index + 1] >= 0x41 && bytes[index + 1] <= 0x5A
          || bytes[index + 1] >= 0x61 && bytes[index + 1] <= 0x7A
          || bytes[index + 1] >= 0x80
      {
        return nil
      }
      index += 1
    }
    return nil
  }

  private static func parse(
    _ data: Data, limits: FeedParseLimits, expectedRoot: RootKind?,
    onXMLParserCreation: (@Sendable () -> Void)? = nil,
    onStartElement: (@Sendable (Int) -> Void)? = nil
  ) throws -> ParsedFeed {
    try Task.checkCancellation()
    guard data.count <= maximumDocumentBytes else {
      throw FeedParseError.limitExceeded(.documentBytes)
    }
    var data = data
    if containsDOCTYPEInProlog(data) {
      guard let blanked = blankingBareDOCTYPE(data) else { throw FeedParseError.dtdNotAllowed }
      data = blanked
    }
    try Task.checkCancellation()

    let delegate = FeedParserDelegate(limits: limits, onStartElement: onStartElement)
    onXMLParserCreation?()
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
    guard let rootKind = delegate.rootKind, expectedRoot == nil || expectedRoot == rootKind else {
      throw FeedParseError.unrecognizedRoot
    }
    guard rootKind == .atom || delegate.hasChannel else { throw FeedParseError.unrecognizedRoot }
    guard let title = delegate.channelTitle else { throw FeedParseError.missingChannelTitle }
    return ParsedFeed(
      title: title, author: delegate.author, artworkURL: delegate.artworkURL,
      synopsis: delegate.synopsis, language: delegate.language, items: delegate.items)
  }
}
