import DesignSystem
import Foundation
import ReaderCore
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import Testing
import UIKit

@testable import Whirr

@MainActor
@Suite struct ReadiumEPUBRendererTests {

  @Test func pageSwipeObserverWatchesTheHostWithoutClaimingTouches() {
    let host = ReadiumEPUBRendererHostViewController()
    host.loadViewIfNeeded()
    let recognizer = host.pageSwipeRecognizer

    #expect(host.view.gestureRecognizers?.contains(recognizer) == true)
    #expect(recognizer.cancelsTouchesInView == false)
    #expect(recognizer.delaysTouchesBegan == false)
    #expect(recognizer.delaysTouchesEnded == false)
    #expect(
      host.gestureRecognizer(recognizer, shouldRecognizeSimultaneouslyWith: UIPanGestureRecognizer()))
  }

  @Test func pageSwipeFiresOnceWhenTheDragBegins() {
    let host = ReadiumEPUBRendererHostViewController()
    var swipes = 0
    host.onPageSwipe = { swipes += 1 }

    host.pageSwipeStateChanged(to: .possible)
    #expect(swipes == 0)
    host.pageSwipeStateChanged(to: .began)
    host.pageSwipeStateChanged(to: .changed)
    host.pageSwipeStateChanged(to: .ended)

    #expect(swipes == 1)
  }

  @Test func locatorTranslationKeepsPositionFieldsAndDropsTextContext() throws {
    let locator = try makeLocator(
      href: "Text/chapter.xhtml",
      progression: 0.25,
      totalProgression: 0.42,
      position: 17,
      cfi: "/4/2/1:0",
      text: Locator.Text(after: "book text after", before: "book text before", highlight: "book text")
    )

    let position = try #require(ReadiumEPUBRenderer.readingPosition(from: locator))

    #expect(position.href == "Text/chapter.xhtml")
    #expect(position.progression == 0.25)
    #expect(position.totalProgression == 0.42)
    #expect(position.position == 17)
    #expect(position.cfi == nil)
    #expect(position.ebookLocation == nil)
  }

  @Test func locatorTranslationAcceptsOnlyACompleteCFIShape() throws {
    let locator = try makeLocator(
      href: "Text/chapter.xhtml",
      progression: 0.5,
      totalProgression: 0.5,
      cfi: "epubcfi(/6/4!/4/2/1:0)"
    )

    let position = try #require(ReadiumEPUBRenderer.readingPosition(from: locator))

    #expect(position.cfi == "epubcfi(/6/4!/4/2/1:0)")
    #expect(position.ebookLocation == position.cfi)
  }

  @Test func readingPositionTranslationBuildsAReadiumLocatorForNavigation() throws {
    let position = ReadingPosition(
      href: "Text/chapter.xhtml",
      progression: 0.25,
      totalProgression: 0.42,
      position: 17,
      cfi: "epubcfi(/6/4!/4/2/1:0)"
    )

    let locator = ReadiumEPUBRenderer.locator(from: position)

    #expect(locator.href.string == position.href)
    #expect(locator.mediaType.string == "application/xhtml+xml")
    #expect(locator.locations.progression == position.progression)
    #expect(locator.locations.totalProgression == position.totalProgression)
    #expect(locator.locations.position == position.position)
    #expect(locator.locations.partialCFI == position.cfi)
    #expect(locator.text == Locator.Text())
  }

  @Test func exactPositionInitialLocationUsesThePositionLocator() throws {
    let position = ReadingPosition(
      href: "Text/chapter.xhtml",
      progression: 0.25,
      totalProgression: 0.42,
      position: 17,
      cfi: "epubcfi(/6/4!/4/2/1:0)"
    )
    let fallback = try makeLocator(
      href: "Text/first.xhtml", progression: 0, totalProgression: 0, position: 1)

    let resolved = ReadiumEPUBRenderer.resolveInitialLocation(
      for: .position(position),
      positions: [fallback],
      progressionLocator: nil
    )

    #expect(resolved.target == "position")
    #expect(resolved.locator?.href.string == position.href)
    #expect(resolved.locator?.locations.position == position.position)
    #expect(resolved.locator?.locations.totalProgression == position.totalProgression)
    #expect(resolved.locator?.locations.partialCFI == position.cfi)
  }

  @Test func failedProgressionResolutionUsesTheFallbackWithoutPositions() {
    let resolved = ReadiumEPUBRenderer.resolveInitialLocation(
      for: .totalProgression(0.75),
      positions: nil,
      progressionLocator: nil
    )

    #expect(resolved.locator == nil)
    #expect(resolved.target == "fallback")
  }

  @Test func paginatedColumnsAreSetBelowReadiumCSSsSixtyEmBreakpoint() {
    // Both `--USER__colCount` values sit inside ReadiumCSS's 60em media query, so neither `.auto`
    // nor `.two` reaches a 951-point open iPhone Duo. The reading-system properties are injected
    // inline with `!important` and apply at every width.
    let properties = ReadiumEPUBRenderer.readingSystemProperties.cssProperties()

    #expect(properties["--RS__colCount"] == "2")
    #expect(properties["--RS__colWidth"] == "max(20em, min(60vh, 30em))")
  }

  @Test(arguments: [
    (width: 951.0, height: 669.0, columns: 2),  // open iPhone Duo
    (width: 951.0, height: 485.0, columns: 2),  // open iPhone Duo, inside the regular insets
    (width: 1180.0, height: 820.0, columns: 2),  // iPad Air 11-inch, landscape
    (width: 1032.0, height: 1366.0, columns: 2),  // iPad Pro 13-inch portrait, past 60em
    (width: 874.0, height: 402.0, columns: 2),  // iPhone 17 Pro, landscape
    (width: 466.0, height: 678.0, columns: 1),  // closed iPhone Duo
    (width: 402.0, height: 874.0, columns: 1),  // iPhone 17 Pro, portrait
    (width: 834.0, height: 1194.0, columns: 1),  // iPad Pro 11-inch, portrait
    (width: 744.0, height: 1133.0, columns: 1),  // iPad mini, portrait
  ])
  func paginatedColumnCountFollowsThePageShape(width: Double, height: Double, columns: Int) {
    #expect(Self.cssColumnCount(pageWidth: width, pageHeight: height, rootFontSize: 16) == columns)
  }

  @Test func largeTypeFallsBackToOneColumnOnTheOpenDuo() {
    // 20em at the largest font step (2x) is 640 pixels, so two columns no longer fit in 951.
    #expect(Self.cssColumnCount(pageWidth: 951, pageHeight: 669, rootFontSize: 32) == 1)
    #expect(Self.cssColumnCount(pageWidth: 951, pageHeight: 669, rootFontSize: 20) == 2)
  }

  /// CSS multi-column arithmetic for the reading-system properties: with no column gap, the used
  /// count is `min(column-count, floor(width / column-width))`, never below one.
  private static func cssColumnCount(
    pageWidth: Double, pageHeight: Double, rootFontSize: Double
  ) -> Int {
    let width = ReaderColumnWidth.self
    let columnWidth = max(
      Double(width.minimumEm) * rootFontSize,
      min(Double(width.heightPercent) / 100 * pageHeight, Double(width.wideEm) * rootFontSize)
    )
    return max(1, min(2, Int((pageWidth / columnWidth).rounded(.down))))
  }

  @Test func everyReaderPreferenceFieldMapsIncludingPublisherDefaults() {
    let mappedSystem = ReadiumEPUBRenderer.epubPreferences(
      for: ReaderPreferences(
        theme: .system,
        fontFamily: .publisherDefault,
        fontSizeStep: 8,
        lineSpacingStep: 4,
        marginsStep: 4,
        readingMode: .paginated
      ),
      systemTheme: .dark
    )

    #expect(mappedSystem.theme == .dark)
    #expect(mappedSystem.fontFamily == nil)
    #expect(mappedSystem.fontSize == 2.0)
    #expect(mappedSystem.lineHeight == 1.4)
    #expect(mappedSystem.pageMargins == 2.0)
    #expect(mappedSystem.scroll == false)
    // `.auto`, never `.one`: Readium writes this to `--USER__colCount`, and ReadiumCSS's responsive
    // default (two columns above a 60em viewport) applies only while it is neither "1" nor "2".
    // `.one` also pins `--RS__colWidth: 100vw`, the cause of one column on a landscape iPad.
    // Scroll mode leaves it unset.
    #expect(mappedSystem.columnCount == .auto)

    let mappedExplicit = ReadiumEPUBRenderer.epubPreferences(
      for: ReaderPreferences(
        theme: .sepia,
        fontFamily: .monospaced,
        fontSizeStep: 3,
        lineSpacingStep: 2,
        marginsStep: 1,
        readingMode: .scroll
      ),
      systemTheme: .light
    )

    #expect(mappedExplicit.theme == .sepia)
    #expect(mappedExplicit.fontFamily == .monospace)
    #expect(mappedExplicit.fontSize == 1.375)
    #expect(mappedExplicit.lineHeight == 1.2)
    #expect(mappedExplicit.pageMargins == 1.25)
    #expect(mappedExplicit.scroll == true)
    #expect(mappedExplicit.columnCount == nil)

    let themes: [(ReaderCore.ReaderTheme, Theme)] = [
      (.light, .light),
      (.sepia, .sepia),
      (.dark, .dark),
    ]
    for (readerTheme, readiumTheme) in themes {
      let preferences = ReadiumEPUBRenderer.epubPreferences(
        for: ReaderPreferences(theme: readerTheme),
        systemTheme: .light
      )
      #expect(preferences.theme == readiumTheme)
    }

    let fonts: [(ReaderCore.ReaderFontFamily, FontFamily?)] = [
      (.publisherDefault, nil),
      (.serif, .serif),
      (.sansSerif, .sansSerif),
      (.monospaced, .monospace),
    ]
    for (readerFont, readiumFont) in fonts {
      let preferences = ReadiumEPUBRenderer.epubPreferences(
        for: ReaderPreferences(fontFamily: readerFont),
        systemTheme: .light
      )
      #expect(preferences.fontFamily == readiumFont)
    }
  }

  @Test("reflowable margins leave the header and footer rows clear of the page")
  func reflowableMarginsLeaveRoomForThePageFurniture() {
    // Portrait phones and iPads: the margins hold the running header and footer. The system bars
    // may overlay the text while the chrome shows.
    let regular = ReadiumEPUBRenderer.contentInsets[.regular]
    #expect((regular?.top ?? 0) >= 112)
    #expect((regular?.bottom ?? 0) >= 72)
    // Landscape phones have no top safe area and a shorter bar.
    let compact = ReadiumEPUBRenderer.contentInsets[.compact]
    #expect((compact?.top ?? 0) >= 56)
    #expect((compact?.bottom ?? 0) >= 68)
  }

  @Test("the page takes its colours from the reader palette, not Readium's own theme")
  func pageColoursComeFromTheReaderPalette() {
    let cases: [(ReaderCore.ReaderTheme, Theme, DesignSystem.ReaderTheme)] = [
      (.light, .light, .light),
      (.sepia, .sepia, .sepia),
      (.dark, .dark, .dark),
      (.system, .dark, .dark),
    ]

    for (readerTheme, systemTheme, designTheme) in cases {
      let mapped = ReadiumEPUBRenderer.epubPreferences(
        for: ReaderPreferences(theme: readerTheme),
        systemTheme: systemTheme
      )
      let palette = designTheme.palette

      #expect(mapped.backgroundColor == ReadiumEPUBRenderer.readiumColor(palette.background))
      #expect(mapped.textColor == ReadiumEPUBRenderer.readiumColor(palette.foreground))
    }

    // Readium's own sepia page is far paler than the palette's. Leaving the theme to supply it puts
    // the palest surface on screen, where the page fills it.
    #expect(ReadiumEPUBRenderer.readiumColor(ReaderThemePalette.sepia.background) != Theme.sepia.backgroundColor)
  }

  @Test func textAlignmentMapsAndPublisherDefaultLeavesReadiumUnset() {
    let alignments: [(ReaderCore.ReaderTextAlignment, ReadiumNavigator.TextAlignment?)] = [
      (.publisherDefault, nil),
      (.left, .start),
      (.justify, .justify),
    ]
    for (readerAlignment, readiumAlignment) in alignments {
      let preferences = ReadiumEPUBRenderer.epubPreferences(
        for: ReaderPreferences(textAlignment: readerAlignment),
        systemTheme: .light
      )
      #expect(preferences.textAlign == readiumAlignment)
    }
  }

  @Test func publisherStylesCarryTheReadersOwnFlagAndNothingElse() {
    // ReadiumCSS gates textAlign and lineHeight on advancedSettings, which is !publisherStyles. The
    // flag is the reader's own switch, forwarded verbatim. The appearance panel disables the gated
    // controls while it is on rather than clearing it behind the reader's back, so no other
    // preference may move it, alignment and line spacing included. Only
    // `ReaderPreferences.init(from:)` still infers it, for payloads written before the key existed.
    let variations: [ReaderPreferences] = [
      ReaderPreferences(),
      ReaderPreferences(theme: .dark),
      ReaderPreferences(fontFamily: .serif),
      ReaderPreferences(fontSizeStep: 8),
      ReaderPreferences(marginsStep: 4),
      ReaderPreferences(readingMode: .scroll),
      ReaderPreferences(textAlignment: .left),
      ReaderPreferences(textAlignment: .justify),
      ReaderPreferences(lineSpacingStep: 1),
      ReaderPreferences(lineSpacingStep: 2, textAlignment: .justify),
    ]
    for preferences in variations {
      let mapped = ReadiumEPUBRenderer.epubPreferences(for: preferences, systemTheme: .light)
      #expect(mapped.publisherStyles == true)
    }

    for var preferences in variations {
      preferences.publisherStyles = false
      let mapped = ReadiumEPUBRenderer.epubPreferences(for: preferences, systemTheme: .light)
      #expect(mapped.publisherStyles == false)
    }
  }

  @Test func tableOfContentsTranslationFlattensChildrenWithDepth() {
    let links = [
      Link(
        href: "Text/part.xhtml",
        title: "Part one",
        children: [
          Link(
            href: "Text/chapter-one.xhtml",
            title: "Chapter one",
            children: [Link(href: "Text/section.xhtml", title: "Section")]
          ),
          Link(href: "Text/chapter-two.xhtml", title: "Chapter two"),
        ]
      ),
      Link(href: "Text/appendix.xhtml"),
    ]

    let entries = ReadiumEPUBRenderer.flattenTOC(links)

    #expect(
      entries.map(\.title) == ["Part one", "Chapter one", "Section", "Chapter two", "Text/appendix.xhtml"]
    )
    #expect(
      entries.map(\.href) == [
        "Text/part.xhtml", "Text/chapter-one.xhtml", "Text/section.xhtml", "Text/chapter-two.xhtml",
        "Text/appendix.xhtml",
      ]
    )
    #expect(entries.map(\.depth) == [0, 1, 2, 1, 0])
  }

  @Test func locatorTranslationRefusesAnOversizedHref() throws {
    let href = String(repeating: "h", count: ReadingPosition.maximumStringBytes + 1)
    let locator = try makeLocator(href: href, progression: 0.1, totalProgression: 0.2)

    #expect(ReadiumEPUBRenderer.readingPosition(from: locator) == nil)
  }

  @Test("a TOC nested past the depth bound is truncated rather than overflowing the stack")
  func deeplyNestedTOCIsTruncatedAtTheDepthBound() {
    // Hostile nesting depth is the sharpest archive-side crash: the flatten recurses once per
    // level, so an unbounded publication decides how deep the app's stack goes.
    var link = Link(href: "Text/leaf.xhtml", title: "Leaf")
    for level in 0..<5_000 {
      link = Link(href: "Text/level-\(level).xhtml", title: "Level \(level)", children: [link])
    }

    let entries = ReadiumEPUBRenderer.flattenTOC([link])

    #expect(entries.isEmpty == false)
    #expect(entries.allSatisfy { $0.depth <= TOCEntry.maximumDepth })
  }

  @Test("a TOC longer than the entry bound is truncated")
  func oversizedTOCIsTruncatedAtTheEntryBound() {
    let links = (0..<(TOCEntry.maximumCount + 100)).map {
      Link(href: "Text/chapter-\($0).xhtml", title: "Chapter \($0)")
    }

    let entries = ReadiumEPUBRenderer.flattenTOC(links)

    #expect(entries.count == TOCEntry.maximumCount)
  }

  @Test("a TOC fragment resolves to the first position of its resource")
  func tocFragmentResolvesToFirstPositionOfResource() {
    let positions = [
      makeReadingPosition(href: "Text/chapter.xhtml"),
      makeReadingPosition(href: "Text/chapter.xhtml"),
    ]
    let resolver = ReadiumEPUBRenderer.pageNumberByResourceHref(positions)

    let entries = ReadiumEPUBRenderer.flattenTOC(
      [Link(href: "./Text/chapter.xhtml#section", title: "Chapter")],
      positionsByResourceHref: resolver
    )

    #expect(entries.map(\.position) == [1])
  }

  @Test("TOC entries in the same resource share its first position")
  func entriesInSameResourceShareFirstPosition() {
    let positions = [
      makeReadingPosition(href: "Text/chapter.xhtml"),
      makeReadingPosition(href: "Text/chapter.xhtml"),
      makeReadingPosition(href: "Text/appendix.xhtml"),
    ]
    let resolver = ReadiumEPUBRenderer.pageNumberByResourceHref(positions)

    let entries = ReadiumEPUBRenderer.flattenTOC(
      [
        Link(href: "Text/chapter.xhtml#one", title: "One"),
        Link(href: "Text/chapter.xhtml#two", title: "Two"),
      ],
      positionsByResourceHref: resolver
    )

    #expect(entries.map(\.position) == [1, 1])
  }

  @Test("an unmatched TOC resource keeps its position absent")
  func unmatchedTOCResourceKeepsPositionNil() {
    let resolver = ReadiumEPUBRenderer.pageNumberByResourceHref([
      makeReadingPosition(href: "Text/chapter.xhtml")
    ])

    let entries = ReadiumEPUBRenderer.flattenTOC(
      [Link(href: "Text/missing.xhtml#section", title: "Missing")],
      positionsByResourceHref: resolver
    )

    #expect(entries.map(\.position) == [nil])
  }

  @Test("nested TOC entries preserve depth and resolve independently")
  func nestedTOCEntriesPreserveDepthAndResolveIndependently() {
    let positions = [
      makeReadingPosition(href: "Text/part.xhtml"),
      makeReadingPosition(href: "Text/chapter.xhtml"),
      makeReadingPosition(href: "Text/section.xhtml"),
    ]
    let resolver = ReadiumEPUBRenderer.pageNumberByResourceHref(positions)

    let entries = ReadiumEPUBRenderer.flattenTOC(
      [
        Link(
          href: "Text/part.xhtml#part",
          title: "Part",
          children: [
            Link(
              href: "Text/chapter.xhtml#chapter",
              title: "Chapter",
              children: [Link(href: "Text/section.xhtml#section", title: "Section")]
            )
          ]
        )
      ],
      positionsByResourceHref: resolver
    )

    #expect(entries.map(\.depth) == [0, 1, 2])
    #expect(entries.map(\.position) == [1, 2, 3])
  }

  // MARK: - Start progressions

  @Test("a TOC fragment takes the first whole-book fraction of its resource")
  func tocFragmentTakesFirstProgressionOfItsResource() {
    let positions = [
      makeReadingPosition(href: "Text/chapter.xhtml", totalProgression: 0.25),
      makeReadingPosition(href: "Text/chapter.xhtml", totalProgression: 0.3),
      makeReadingPosition(href: "Text/appendix.xhtml", totalProgression: 0.9),
    ]
    let resolver = ReadiumEPUBRenderer.startProgressionByResourceHref(positions)

    let entries = ReadiumEPUBRenderer.flattenTOC(
      [
        Link(href: "./Text/chapter.xhtml#section", title: "Chapter"),
        Link(href: "Text/appendix.xhtml", title: "Appendix"),
      ],
      progressionsByResourceHref: resolver
    )

    #expect(entries.map(\.startProgression) == [0.25, 0.9])
  }

  @Test("an unmatched TOC resource keeps its start progression absent")
  func unmatchedTOCResourceKeepsStartProgressionNil() {
    let resolver = ReadiumEPUBRenderer.startProgressionByResourceHref([
      makeReadingPosition(href: "Text/chapter.xhtml", totalProgression: 0.5)
    ])

    let entries = ReadiumEPUBRenderer.flattenTOC(
      [Link(href: "Text/missing.xhtml#section", title: "Missing")],
      progressionsByResourceHref: resolver
    )

    #expect(entries.map(\.startProgression) == [nil])
  }

  /// Page numbers and read marks resolve off the same positions list, so one must not disturb the
  /// other when both are supplied.
  @Test("nested entries resolve page number and start progression together")
  func nestedEntriesResolveBothResolversTogether() {
    let positions = [
      makeReadingPosition(href: "Text/part.xhtml", position: 1, totalProgression: 0),
      makeReadingPosition(href: "Text/chapter.xhtml", position: 2, totalProgression: 0.4),
      makeReadingPosition(href: "Text/section.xhtml", position: 3, totalProgression: 0.8),
    ]

    let entries = ReadiumEPUBRenderer.flattenTOC(
      [
        Link(
          href: "Text/part.xhtml#part",
          title: "Part",
          children: [
            Link(
              href: "Text/chapter.xhtml#chapter",
              title: "Chapter",
              children: [Link(href: "Text/section.xhtml#section", title: "Section")]
            )
          ]
        )
      ],
      positionsByResourceHref: ReadiumEPUBRenderer.pageNumberByResourceHref(positions),
      progressionsByResourceHref: ReadiumEPUBRenderer.startProgressionByResourceHref(positions)
    )

    #expect(entries.map(\.position) == [1, 2, 3])
    #expect(entries.map(\.startProgression) == [0, 0.4, 0.8])
  }

  @Test("a positions resolver is built once and reused across many entries")
  func positionResolverIsBuiltOnceAndReusedForManyPositions() {
    let positions = (0..<3_000).map { index in
      let href = ["Text/one.xhtml", "Text/two.xhtml", "Text/three.xhtml"][index % 3]
      return makeReadingPosition(href: href)
    }

    let resolver = ReadiumEPUBRenderer.pageNumberByResourceHref(positions)

    #expect(
      resolver == [
        "Text/one.xhtml": 1,
        "Text/two.xhtml": 2,
        "Text/three.xhtml": 3,
      ])

    let entries = ReadiumEPUBRenderer.flattenTOC(
      [
        Link(href: "Text/three.xhtml#end", title: "Three"),
        Link(href: "Text/one.xhtml#start", title: "One"),
        Link(href: "Text/two.xhtml#middle", title: "Two"),
      ],
      positionsByResourceHref: resolver
    )

    #expect(entries.map(\.position) == [3, 1, 2])
  }

  @Test func tapZonesArePureAndDoNotImplementNavigationPolicy() {
    #expect(ReadiumEPUBRenderer.tapZone(for: 1, width: 300) == .left)
    #expect(ReadiumEPUBRenderer.tapZone(for: 150, width: 300) == .center)
    #expect(ReadiumEPUBRenderer.tapZone(for: 299, width: 300) == .right)
    #expect(ReadiumEPUBRenderer.tapZone(for: 0, width: 0) == .center)
  }

  /// `EPUBError.serverFailure` is deprecated upstream. The EPUB navigator runs no HTTP server, but
  /// the case still exists and `classifyOpenFailure` still maps it, so the coverage stays.
  /// Deprecating the test itself keeps the warning from the construction below out of the build.
  @available(*, deprecated)
  @Test func openFailureClassificationKeepsTheFourProtocolCasesDistinct() {
    #expect(
      ReadiumEPUBRenderer.classifyOpenFailure(EPUBNavigatorViewController.EPUBError.publicationRestricted)
        == .drmProtected
    )
    #expect(
      ReadiumEPUBRenderer.classifyOpenFailure(EPUBNavigatorViewController.EPUBError.serverFailure(NSError()))
        == .serverFailure
    )
    #expect(
      ReadiumEPUBRenderer.classifyOpenFailure(PublicationOpenError.formatNotSupported) == .unopenable
    )
    #expect(
      ReadiumEPUBRenderer.classifyOpenFailure(
        PublicationOpenError.reading(.decoding("malformed EPUB"))
      ) == .unopenable
    )
    #expect(
      ReadiumEPUBRenderer.localFileFailure(for: URL(fileURLWithPath: "/missing/book.epub")) == .noEbook
    )
    #expect(
      ReadiumEPUBRenderer.localFileFailure(for: URL(string: "https://example.com/book.epub")!) == .noEbook
    )
  }

  @Test func lifecycleAllowsReplacementAndKeepsCurrentPublicationAfterFailedOpen() {
    var lifecycle = ReadiumEPUBRendererLifecycle()

    lifecycle.start()
    lifecycle.openSucceeded()
    #expect(lifecycle.state == .publicationOpen)
    #expect(lifecycle.activePublicationCount == 1)

    lifecycle.openFailed()
    #expect(lifecycle.state == .publicationOpen)
    #expect(lifecycle.activePublicationCount == 1)

    // A second success replaces the current publication without ever exposing two active
    // publication resources to the boundary.
    lifecycle.openSucceeded()
    #expect(lifecycle.state == .publicationOpen)
    #expect(lifecycle.activePublicationCount == 1)

    lifecycle.close()
    #expect(lifecycle.state == .ready)
    #expect(lifecycle.activePublicationCount == 0)
    lifecycle.close()
    #expect(lifecycle.state == .ready)
    lifecycle.openSucceeded()
    #expect(lifecycle.state == .publicationOpen)
    #expect(lifecycle.activePublicationCount == 1)
    lifecycle.close()
    #expect(lifecycle.activePublicationCount == 0)
  }

  @Test func explicitStopCoversBackgroundReturnAndEnvironmentRebuildWithoutStalePublication() {
    var lifecycle = ReadiumEPUBRendererLifecycle()

    lifecycle.start()
    lifecycle.openSucceeded()
    #expect(lifecycle.state == .publicationOpen)

    // Readium 3.11 uses the navigator's internal resource handler, so background and return neither
    // create, retain nor restore an external served URL. The explicit engine stop is the logout and
    // environment-rebuild boundary.
    lifecycle.stop()
    #expect(lifecycle.state == .stopped)
    #expect(lifecycle.activePublicationCount == 0)
    lifecycle.start()
    #expect(lifecycle.state == .ready)
  }

  private func makeLocator(
    href: String,
    progression: Double,
    totalProgression: Double,
    position: Int? = nil,
    cfi: String? = nil,
    text: Locator.Text = .init()
  ) throws -> Locator {
    var otherLocations: [String: JSONValue] = [:]
    if let cfi {
      otherLocations["partialCfi"] = .string(cfi)
    }
    return Locator(
      href: try #require(AnyURL(string: href)),
      mediaType: try #require(MediaType("application/xhtml+xml")),
      locations: Locator.Locations(
        progression: progression,
        totalProgression: totalProgression,
        position: position,
        otherLocations: otherLocations
      ),
      text: text
    )
  }

  @Test("the resolver prefers the renderer's own one-based position over the array offset")
  func resolverPrefersRendererSuppliedPosition() {
    // Readium numbers positions itself (Locator.position >= 1); the offset is only a fallback for a
    // renderer that omits it, and the two must never disagree in the TOC.
    let resolver = ReadiumEPUBRenderer.pageNumberByResourceHref([
      makeReadingPosition(href: "Text/one.xhtml", position: 7),
      makeReadingPosition(href: "Text/two.xhtml"),
    ])

    #expect(resolver == ["Text/one.xhtml": 7, "Text/two.xhtml": 2])
  }

  // MARK: - Link policy (B11)

  @Test func webLinksAreConfirmedBeforeTheyCanLeaveTheApp() throws {
    for href in ["https://example.com/page", "http://example.com/page"] {
      let url = try #require(URL(string: href))
      #expect(ReaderLinkPolicy.decision(for: url) == .promptThenOpen)
    }
  }

  @Test func mailAndTelephoneLinksTakeTheSameConfirmation() throws {
    for href in ["mailto:someone@example.com", "tel:+441234567890"] {
      let url = try #require(URL(string: href))
      #expect(ReaderLinkPolicy.decision(for: url) == .promptThenOpen)
    }
  }

  /// The refusals are the point of the allowlist: `javascript:` and `data:` are code, `file:`
  /// reaches the container, and a custom scheme hands the tap to another installed app. A book's
  /// own content must not trigger any of them, with or without a prompt.
  @Test func scriptDataFileAndCustomSchemesAreRefusedWithoutPrompting() throws {
    let refused = [
      "javascript:alert(1)", "data:text/html,<script>alert(1)</script>",
      "file:///etc/passwd", "whirr://library", "itms-apps://apps.apple.com/app/id1",
    ]
    for href in refused {
      let url = try #require(URL(string: href))
      #expect(ReaderLinkPolicy.decision(for: url) == .refuse, "\(href) must not be openable")
    }
  }

  @Test func schemeMatchingIgnoresCase() throws {
    let url = try #require(URL(string: "HTTPS://example.com"))
    #expect(ReaderLinkPolicy.decision(for: url) == .promptThenOpen)
  }

  @Test func aResourceInsideThePublicationNavigatesInternally() {
    for href in ["Text/chapter2.xhtml", "/Text/chapter2.xhtml", "chapter2.xhtml#section"] {
      #expect(ReaderLinkPolicy.route(forHREF: href) == .navigateInPublication)
    }
  }

  @Test func aLinkCarryingItsOwnSchemeIsTreatedAsExternal() throws {
    let url = try #require(URL(string: "https://example.com/page"))
    #expect(ReaderLinkPolicy.route(forHREF: "https://example.com/page") == .treatAsExternal(url))
  }

  /// A hostile publication must not be able to grow the alert past its buttons, nor reorder the
  /// destination with bidirectional controls so it reads as a site the reader trusts.
  @Test func theDisplayedDestinationIsTruncatedAndStrippedOfInvisibleControls() throws {
    let long = String(repeating: "a", count: 200)
    let longURL = try #require(URL(string: "https://\(long).example.com/page"))
    let displayed = ReaderLinkPolicy.displayedTarget(for: longURL)
    #expect(displayed.count == ReaderLinkPolicy.maximumDisplayedTargetLength + 1)
    #expect(displayed.hasSuffix("…"))

    let spoofed = try #require(URL(string: "https://example.com/\u{202E}gpj.exe"))
    #expect(ReaderLinkPolicy.displayedTarget(for: spoofed) == "example.com")
    #expect(ReaderLinkPolicy.displayedTarget(for: spoofed).contains("\u{202E}") == false)
  }

  private func makeReadingPosition(
    href: String, position: Int? = nil, totalProgression: Double = 0
  ) -> ReadingPosition {
    ReadingPosition(
      href: href, progression: 0, totalProgression: totalProgression, position: position)
  }
}
