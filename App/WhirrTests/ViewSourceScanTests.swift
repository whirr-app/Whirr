import Foundation
import Testing

/// Proves the source scan fails closed.
///
/// Roughly ninety scan call sites across fourteen App test files depend on `ViewSourceScan`
/// returning a real file list. Its root comes from a compile-time `#filePath`, so a bundle run away
/// from the building checkout sees no directory; returning `[]` there would make every assertion
/// iterate nothing and pass.
@Suite("View source scan")
struct ViewSourceScanTests {

  @Test("an unreachable root throws instead of returning an empty list")
  func anUnreachableRootThrows() {
    #expect(throws: ViewSourceScan.Failure.self) {
      _ = try ViewSourceScan.swiftFiles(
        under: URL(fileURLWithPath: "/nonexistent/checkout/App/Whirr/Views"),
        expectedAtLeast: 1)
    }
  }

  @Test("a real root holding implausibly few sources throws")
  func anImplausiblySmallRootThrows() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "view-source-scan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try "// deliberately the only file\n".write(
      to: directory.appending(path: "Only.swift"), atomically: true, encoding: .utf8)

    #expect(throws: ViewSourceScan.Failure.self) {
      _ = try ViewSourceScan.swiftFiles(under: directory, expectedAtLeast: 80)
    }
  }

  @Test("the real roots resolve and clear their floors")
  func theRealRootsResolve() throws {
    #expect(try ViewSourceScan.sources().count >= ViewSourceScan.minimumViewSources)
    #expect(try ViewSourceScan.appSources().count >= ViewSourceScan.minimumAppSources)
  }

  /// A floor is only useful if it sits below today's count, with room for ordinary deletion, and
  /// above the count a wrong root would produce. If either stops being true, rethink the floor
  /// rather than silently raising it.
  @Test("the floors leave headroom without being trivially satisfiable")
  func theFloorsLeaveHeadroom() throws {
    let views = try ViewSourceScan.sources().count
    let app = try ViewSourceScan.appSources().count
    #expect(ViewSourceScan.minimumViewSources > 0)
    #expect(ViewSourceScan.minimumViewSources <= views)
    #expect(ViewSourceScan.minimumAppSources <= app)
  }

  @Test("a view's combined source reads its extension files and not its presentation")
  func combinedViewSourceReadsItsParts() throws {
    let text = try ViewSourceScan.executableText(ofViewNamed: "PodcastsView")

    // One declaration from each part, and none from `PodcastsViewPresentation*.swift`.
    #expect(text.contains("struct PodcastsView: View"))
    #expect(text.contains("HomeShelfView("))
    #expect(text.contains("var latestEpisodesSection: some View"))
    #expect(text.contains("func showsGridSection("))
    #expect(text.contains("enum PodcastsViewPresentation") == false)
    #expect(text.contains("extension PodcastsViewPresentation") == false)
  }

  @Test("a view that does not exist throws instead of reading nothing")
  func combinedViewSourceFailsClosed() {
    #expect(throws: ViewSourceScan.Failure.viewNotFound(name: "NoSuchView")) {
      _ = try ViewSourceScan.executableText(ofViewNamed: "NoSuchView")
    }
  }

  /// The lookup follows the declaration, so a view that moves to another file keeps its scans
  /// without editing every suite that names it. `RootView` also proves the search covers the app
  /// root, not only `Views`.
  @Test("a symbol lookup finds the file that declares it")
  func symbolLookupFindsTheDeclaringFile() throws {
    let actionRow = try ViewSourceScan.source(declaring: "ItemDetailActionRow")
    #expect(actionRow.lastPathComponent == "ItemDetailActionRow.swift")
    #expect(try ViewSourceScan.executableText(declaring: "ItemDetailActionRow").contains("struct ItemDetailActionRow"))

    let root = try ViewSourceScan.source(declaring: "RootView")
    #expect(root.lastPathComponent == "RootView.swift")
  }

  @Test("a symbol no source declares throws instead of returning a caller's guess")
  func symbolLookupFailsClosed() {
    #expect(throws: ViewSourceScan.Failure.declarationNotFound(symbol: "NoSuchView")) {
      _ = try ViewSourceScan.source(declaring: "NoSuchView")
    }
  }

  // MARK: - Stripper

  @Test("trailing and block comments cannot satisfy a scan; string literals stay")
  func commentsAreBlankedAndStringsKept() {
    let text = ViewSourceScan.executableText(
      ofSource: """
        let url = "https://example.com" // Banned()
        /* Banned()
           /* nested */ still() */
        let quoted = "say \\"/* not a comment */\\"" ; kept()
        let raw = #"a "quote" // b"# ; tail()
        let mixed = "x \\(flag ? "y" : "z") w" // gone
        """)
    #expect(text.contains("Banned()") == false)
    #expect(text.contains("still()") == false)
    #expect(text.contains("gone") == false)
    #expect(text.contains("\"https://example.com\""))
    #expect(text.contains("/* not a comment */"))
    #expect(text.contains("kept()"))
    #expect(text.contains("// b\"#"))
    #expect(text.contains("tail()"))
  }

  @Test("lines holding only a comment are dropped, as before")
  func commentOnlyLinesAreDropped() {
    let text = ViewSourceScan.executableText(ofSource: "first()\n  // note\n\nsecond()")
    #expect(text == "first()\n\nsecond()")
  }

  @Test("the measurement branch is dropped and its #else, which ships, is kept")
  func perfInvestigationElseBranchIsKept() {
    let text = ViewSourceScan.executableText(
      ofSource: """
        before()
        #if PERF_INVESTIGATION
          probe()
          #if DEBUG
            nested()
          #endif
        #else
          production()
        #endif
        after()
        """)
    #expect(text.contains("before()"))
    #expect(text.contains("production()"))
    #expect(text.contains("after()"))
    #expect(text.contains("probe()") == false)
    #expect(text.contains("nested()") == false)
  }
}
