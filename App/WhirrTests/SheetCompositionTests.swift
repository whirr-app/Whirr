import Foundation
import Testing

@testable import Whirr

/// Source-level, because SwiftUI exposes no stable semantic tree for presentation modifiers. Finds
/// every executable `.sheet(` call in the App source and requires either a shared adaptive host
/// marker or the explicit Reader panels.
@Suite("Sheet composition")
struct SheetCompositionTests {
  private static let allowlistedSources: Set<String> = ["ReaderView.swift"]

  @Test("every known sheet is adaptive or explicitly allowlisted")
  func everyKnownSheetIsAdaptiveOrExplicitlyAllowlisted() throws {
    var sheetSources = Set<String>()
    var allowlistedSheetCount = 0

    for source in try ViewSourceScan.appSources() {
      let text = try ViewSourceScan.executableText(of: source)
      let hosts = Self.sheetHostWindows(in: text)
      guard hosts.isEmpty == false else { continue }

      let name = source.lastPathComponent
      sheetSources.insert(name)
      if Self.allowlistedSources.contains(name) {
        allowlistedSheetCount += hosts.count
        #expect(name == "ReaderView.swift")
        #expect(hosts.count == 3)
        // Contents and search are full-height panels. Appearance opens as a half-sheet over the
        // page, as Books does, and grows to `.large` when Customise is pushed.
        let largeOnly = hosts.filter { $0.contains(".presentationDetents([.large])") }
        let halfSheet = hosts.filter {
          $0.contains(".presentationDetents([.medium, .large], selection: $appearanceDetent)")
        }
        #expect(largeOnly.count == 2)
        #expect(halfSheet.count == 1)
        #expect(halfSheet.first?.contains("$isShowingAppearance") == true)
        // The half-sheet leaves the page undimmed, which is the point of it.
        #expect(
          halfSheet.first?.contains(".presentationBackgroundInteraction(.enabled(upThrough: .medium))")
            == true)
        continue
      }

      for host in hosts {
        let hasSharedAdaptiveHost =
          host.contains(".adaptiveSheetPresentation(")
          || host.contains(".themedSheet(")
          || host.contains(".queueDetents(")
          // The card wrappers own their presentation. The shell and the player host them by name,
          // rather than adding a second modifier at the call site.
          || host.contains("EpisodeCardSheet(")
          || host.contains("ItemDetailCardSheet {")

        #expect(hasSharedAdaptiveHost, Comment(rawValue: name))
        // Fixed detents are allowed only in the explicit Reader exemption, never on an adaptive
        // host. Compact detent values are centralised in the shared modifier and player wrapper.
        #expect(
          host.contains(".presentationDetents(") == false,
          Comment(rawValue: "fixed detent in \(name)"))
      }
    }

    #expect(sheetSources.contains("ReaderView.swift"))
    #expect(allowlistedSheetCount == 3)
    #expect(Self.allowlistedSources == Set(["ReaderView.swift"]))
  }

  /// A sheet is its own presentation, so the reader cover's scheme does not reach the sheet's
  /// glass. Without its own preference, the glass took the device's appearance over a dark-themed
  /// page. Every reader panel is built by `panelSheet`, so the preference lives there.
  @Test("reader panels take the reading theme's appearance, not the device's")
  func readerPanelsTakeTheReadingThemesAppearance() throws {
    let text = try ViewSourceScan.executableText(ofFileNamed: "ReaderView+Panels.swift")
    let helper = try #require(text.range(of: "func panelSheet<"))
    let body = text[helper.lowerBound...].prefix(1_200)

    #expect(body.contains(".preferredColorScheme(ReaderPresentation.windowScheme(for: theme))"))
  }

  /// The reading theme's accent is for the panel content only. Tinting the whole stack also tints
  /// the sheet's close button, which should stay app chrome like the reader's own.
  @Test("reader panel chrome keeps the app tint, not the reading theme's accent")
  func readerPanelChromeKeepsTheAppTint() throws {
    let text = try ViewSourceScan.executableText(ofFileNamed: "ReaderView+Panels.swift")
    let helper = try #require(text.range(of: "func panelSheet<"))
    let body = text[helper.lowerBound...].prefix(1_200)
    let toolbar = try #require(body.range(of: ".toolbar"))
    let stackEnd = try #require(body.range(of: ".environment(\\.colorScheme"))

    #expect(body[..<toolbar.lowerBound].contains(".tint(palette.accentColor)"))
    #expect(body[toolbar.lowerBound..<stackEnd.lowerBound].contains(".tint(AppChrome.tint)"))
    #expect(!body[toolbar.lowerBound...].contains(".tint(palette.accentColor)"))
  }

  /// Scroll-first content interaction is the exception. `.scrolls` gives every vertical drag to the
  /// content's scroll view, so a multi-detent sheet loses the swipe that reaches `.large` and keeps
  /// only its grabber. The transcript takes that trade: it is read by scrolling for minutes at a
  /// time, and under `.automatic` a downward scroll kept collapsing it to `.medium`. Look Back's
  /// text is read the same way and takes the same trade. Only the shared modifier applies the
  /// interaction, and only those two sheets ask for `.scrolls`.
  @Test("only the transcript and Look Back sheets prioritise content scrolling over detent resizing")
  func onlyTheTranscriptPrioritisesContentScrollingOverResizing() throws {
    var applying: Set<String> = []
    var requestingScrolls: Set<String> = []

    for source in try ViewSourceScan.appSources() {
      let text = try ViewSourceScan.executableText(of: source)
      if text.contains(".presentationContentInteraction(") {
        applying.insert(source.lastPathComponent)
      }
      if text.contains("contentInteraction: .scrolls") {
        requestingScrolls.insert(source.lastPathComponent)
      }
    }

    #expect(applying == ["SheetViewPresentationModifiers.swift"])
    #expect(requestingScrolls == ["PlayerTranscriptSheet.swift", "PlayerLookBackSheet.swift"])
  }

  private static func sheetHostWindows(in text: String) -> [Substring] {
    var starts: [String.Index] = []
    var searchStart = text.startIndex
    while let range = text.range(of: ".sheet(", range: searchStart..<text.endIndex) {
      starts.append(range.lowerBound)
      searchStart = range.upperBound
    }

    return starts.enumerated().map { index, start in
      let end = index + 1 < starts.count ? starts[index + 1] : text.endIndex
      return text[start..<end]
    }
  }
}
