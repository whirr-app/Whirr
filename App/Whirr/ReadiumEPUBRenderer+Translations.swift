import DesignSystem
import Foundation
import ReaderCore
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer

typealias ReadiumLink = ReadiumShared.Link

extension ReadiumEPUBRenderer {
  // MARK: - Pure translations

  /// Translates a Readium locator, refusing one whose href exceeds the shared string bound.
  ///
  /// A locator arriving from `locationDidChange` is publication-controlled content that has crossed
  /// the WebKit seam, so its href is untrusted and unbounded until this point. `validated` voids the
  /// position rather than truncating an href into a different resource; callers drop it.
  static func readingPosition(from locator: Locator) -> ReadingPosition? {
    ReadingPosition.validated(
      href: locator.href.string,
      progression: locator.locations.progression ?? 0,
      totalProgression: locator.locations.totalProgression ?? 0,
      position: locator.locations.position,
      cfi: locator.locations.partialCFI
    )
  }

  static func locator(from position: ReadingPosition) -> Locator {
    var otherLocations: [String: JSONValue] = [:]
    if let cfi = position.cfi {
      otherLocations["partialCfi"] = .string(cfi)
    }
    return Locator(
      href: AnyURL(string: position.href)!,
      mediaType: MediaType("application/xhtml+xml")!,
      locations: Locator.Locations(
        progression: position.progression,
        totalProgression: position.totalProgression,
        position: position.position,
        otherLocations: otherLocations
      )
    )
  }

  /// Chooses the navigator's initial location and the privacy-safe source label used in tracing.
  /// A failed progression lookup follows the same fallback path as a missing target, even when the
  /// publication has no generated positions and the navigator ultimately receives nil.
  static func resolveInitialLocation(
    for initialLocation: EPUBInitialLocation?,
    positions: [Locator]?,
    progressionLocator: Locator?
  ) -> (locator: Locator?, target: String) {
    switch initialLocation {
    case .position(let position):
      return (Self.locator(from: position), "position")
    case .totalProgression:
      if let progressionLocator {
        return (progressionLocator, "progression")
      }
      return (positions?.first, "fallback")
    case nil:
      guard let first = positions?.first else { return (nil, "none") }
      return (first, "fallback")
    }
  }

  /// Paginated columns, set on the navigator once and applied by CSS at every page size.
  ///
  /// ReadiumCSS gives two columns only above a 60em (960-pixel) viewport, and `--USER__colCount`
  /// is read only inside that same media query, so no preference reaches a 951-point open iPhone
  /// Duo. These inline properties take precedence over the stylesheet; scroll mode resets
  /// `columns` itself, so they do not affect it.
  static let readingSystemProperties = CSSRSProperties(
    colWidth: ReaderColumnWidth(),
    colCount: .two
  )

  static func epubPreferences(
    for preferences: ReaderPreferences,
    systemTheme: Theme
  ) -> EPUBPreferences {
    let theme: Theme =
      switch preferences.theme {
      case .system: systemTheme
      case .light: .light
      case .sepia: .sepia
      case .dark: .dark
      }
    let fontFamily: FontFamily? =
      switch preferences.fontFamily {
      case .publisherDefault: nil
      case .serif: .serif
      case .sansSerif: .sansSerif
      case .monospaced: .monospace
      case .openDyslexic: .openDyslexic
      }
    let textAlign: ReadiumNavigator.TextAlignment? =
      switch preferences.textAlignment {
      case .publisherDefault: nil
      case .left: .start
      case .justify: .justify
      }
    let typography = ReaderTypography(preferences: preferences)
    let hyphens: Bool? = preferences.hyphenation ? true : nil
    let isScroll = preferences.readingMode == .scroll

    // The page takes the palette's colours, not Readium's theme values: Readium's sepia (#FAF4E8)
    // is far paler than the palette's page, so the page would look almost white against sepia
    // chrome and leave a seam between the web view and the view behind it.
    let palette: ReaderThemePalette =
      switch theme {
      case .light: .light
      case .sepia: .sepia
      case .dark: .dark
      }

    return EPUBPreferences(
      backgroundColor: readiumColor(palette.background),
      // `.auto`, not `.one`. Readium writes this straight through to `--USER__colCount`, and
      // ReadiumCSS's responsive rule (one column, two above a 60em viewport with a 20em column
      // floor) applies only while that variable is neither "1" nor "2". Pinning `.one` also pins
      // `--RS__colWidth: 100vw`, so a landscape iPad paginates one full-width column. Scroll mode
      // leaves it unset; columns do not apply there.
      columnCount: isScroll ? nil : .auto,
      fontFamily: fontFamily,
      fontSize: typography.fontScale,
      hyphens: hyphens,
      letterSpacing: typography.letterSpacing,
      lineHeight: typography.lineHeight,
      pageMargins: typography.pageMargins,
      paragraphSpacing: typography.paragraphSpacing,
      // The reader's own flag, not an inference. ReadiumCSS reads textAlign, lineHeight,
      // letterSpacing, wordSpacing, paragraphSpacing, and hyphens only while this is off, so the
      // appearance panel disables those controls rather than silently clearing the flag.
      publisherStyles: preferences.publisherStyles,
      scroll: isScroll,
      textAlign: textAlign,
      textColor: readiumColor(palette.foreground),
      theme: theme,
      wordSpacing: typography.wordSpacing
    )
  }

  /// A palette colour in Readium's packed-integer colour type.
  static func readiumColor(_ color: WhirrRGBColor) -> ReadiumNavigator.Color {
    func channel(_ component: Double) -> Int { Int((component * 255).rounded()) }
    return ReadiumNavigator.Color(
      rawValue: channel(color.red) << 16 | channel(color.green) << 8 | channel(color.blue)
    )
  }

  /// Builds the first one-based publication position for each normalized resource href.
  ///
  /// Readium 3.11's navigation parser leaves TOC `Link.href` values such as
  /// `Text/chapter.xhtml#section`, while a position's `Locator.href.string` is the normalized
  /// resource href. Both go through Readium's URL normalization and lose their fragment before
  /// comparison; queries are kept. Positions are one-based (`Locator.Locations.position` is
  /// documented ">= 1"), so a missing value falls back to the array offset plus one.
  static func pageNumberByResourceHref(_ positions: [ReadingPosition]) -> [String: Int] {
    positions.enumerated().reduce(into: [String: Int]()) { result, element in
      let href = normalizedResourceHref(element.element.href)
      if result[href] == nil {
        result[href] = element.element.position ?? element.offset + 1
      }
    }
  }

  /// Builds the whole-publication start fraction for each normalized resource href, resolved the
  /// same way `pageNumberByResourceHref` resolves page numbers. This is what a stored contents
  /// entry carries so the detail screen can mark it read against `mediaProgress.ebookProgress`
  /// without reopening the publication.
  static func startProgressionByResourceHref(_ positions: [ReadingPosition]) -> [String: Double] {
    positions.reduce(into: [String: Double]()) { result, position in
      let href = normalizedResourceHref(position.href)
      if result[href] == nil {
        result[href] = position.totalProgression
      }
    }
  }

  /// Flattens a navigation document, bounded in both nesting depth and total entries.
  ///
  /// The bounds guard untrusted structure: depth protects the stack at open, count protects memory.
  /// Exceeding either truncates the contents list without failing the open; the book is still
  /// readable.
  static func flattenTOC(
    _ links: [ReadiumLink],
    positionsByResourceHref: [String: Int] = [:],
    progressionsByResourceHref: [String: Double] = [:],
    depth: Int = 0
  ) -> [TOCEntry] {
    var entries: [TOCEntry] = []
    appendFlattenedTOC(
      links,
      positionsByResourceHref: positionsByResourceHref,
      progressionsByResourceHref: progressionsByResourceHref,
      depth: depth,
      into: &entries
    )
    return entries
  }

  private static func appendFlattenedTOC(
    _ links: [ReadiumLink],
    positionsByResourceHref: [String: Int],
    progressionsByResourceHref: [String: Double],
    depth: Int,
    into entries: inout [TOCEntry]
  ) {
    guard depth <= TOCEntry.maximumDepth else { return }
    for link in links {
      guard entries.count < TOCEntry.maximumCount else { return }
      let resourceHref = link.href.isEmpty ? nil : normalizedResourceHref(link.href)
      entries.append(
        TOCEntry(
          title: link.title ?? link.href,
          href: link.href.isEmpty ? nil : link.href,
          position: resourceHref.flatMap { positionsByResourceHref[$0] },
          depth: depth,
          startProgression: resourceHref.flatMap { progressionsByResourceHref[$0] }
        ))
      appendFlattenedTOC(
        link.children,
        positionsByResourceHref: positionsByResourceHref,
        progressionsByResourceHref: progressionsByResourceHref,
        depth: depth + 1,
        into: &entries
      )
    }
  }

  private static func normalizedResourceHref(_ href: String) -> String {
    if let url = AnyURL(string: href) ?? AnyURL(legacyHREF: href) {
      return url.normalized.removingFragment().string
    }
    return String(href.prefix(while: { $0 != "#" }))
  }

  static func classifyOpenFailure(_ error: Error) -> EPUBRenderingOpenFailure {
    if let error = error as? EPUBNavigatorViewController.EPUBError {
      switch error {
      case .publicationRestricted:
        return .drmProtected
      case .serverFailure:
        return .serverFailure
      case .spreadNotLoaded:
        return .unopenable
      }
    }
    if let error = error as? PublicationOpenError {
      switch error {
      case .formatNotSupported, .reading:
        return .unopenable
      }
    }
    if let error = error as? AssetRetrieveURLError {
      switch error {
      case .schemeNotSupported, .formatNotSupported, .reading:
        return .unopenable
      }
    }
    return .unopenable
  }

  static func localFileFailure(for url: URL) -> EPUBRenderingOpenFailure? {
    guard url.isFileURL else { return .noEbook }
    guard FileManager.default.fileExists(atPath: url.path) else { return .noEbook }
    return nil
  }

  static func tapZone(for x: CGFloat, width: CGFloat) -> ReadiumEPUBTapZone {
    guard width > 0 else { return .center }
    if x < width / 3 { return .left }
    if x >= width * 2 / 3 { return .right }
    return .center
  }
}

/// The column width that decides between one and two paginated columns.
///
/// Two columns appear once the page is twice this wide. The floor keeps every column at least
/// ReadiumCSS's own 20em, so large type falls back to one; the cap keeps ReadiumCSS's rule that a
/// page 60em wide or more gets two; between them, two columns need a page at least 1.2 times as
/// wide as it is tall, which an open iPhone Duo or a phone on its side is and a portrait iPad is not.
/// The `em` values follow the reader's font size; `vh` is the page's own height.
struct ReaderColumnWidth: CSSLength {
  static let minimumEm = 20
  static let wideEm = 30
  static let heightPercent = 60

  func css() -> String? {
    "max(\(Self.minimumEm)em, min(\(Self.heightPercent)vh, \(Self.wideEm)em))"
  }
}
