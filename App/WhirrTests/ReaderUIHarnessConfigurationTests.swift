import AppModel
import Foundation
import ReaderCore
import Testing

@testable import Whirr

/// Mirrors `SearchUIHarnessConfigurationTests`. The harness scenarios are proven here, at the test
/// level, not by booting a simulator.
@Suite("Reader UI harness configuration")
struct ReaderUIHarnessConfigurationTests {

  @Test("every reader scenario is reachable by its environment value")
  func everyScenarioIsReachable() {
    let rawValues = [
      "loading", "downloading-first", "reading-with-chrome", "appearance", "toc", "protected-file",
      "corrupt-file", "fixed-layout-with-disabled-controls", "finish-offer",
    ]
    for rawValue in rawValues {
      #expect(UIHarnessReaderScenario(rawValue: rawValue) != nil)
    }
    #expect(UIHarnessReaderScenario(rawValue: "not-a-scenario") == nil)
  }

  @Test("only the panel scenarios land on a panel")
  func onlyPanelScenariosOpenAPanel() {
    #expect(UIHarnessReaderScenario.appearance.initialPanel == .appearance)
    #expect(UIHarnessReaderScenario.toc.initialPanel == .toc)
    #expect(UIHarnessReaderScenario.readingWithChrome.initialPanel == nil)
    #expect(UIHarnessReaderScenario.finishOffer.initialPanel == nil)
  }

  @Test("the harness publication is long enough for the rail to read page 42 of 336")
  func publicationCarriesAMidBookPosition() {
    #expect(UIHarnessReaderScenario.positions.count == 336)
    #expect(UIHarnessReaderScenario.positions.first?.position == 1)
    #expect(UIHarnessReaderScenario.positions.last?.position == 336)

    let mid = UIHarnessReaderScenario.position(atPage: UIHarnessReaderScenario.midBookPage)
    #expect(mid.position == 42)
    #expect(
      ReaderCopy.progressPageText(page: mid.position, pageCount: UIHarnessReaderScenario.pageCount)
        == "Page 42 of 336")
  }

  @Test("page lookup clamps rather than trapping at the ends")
  func pageLookupClamps() {
    #expect(UIHarnessReaderScenario.position(atPage: 0).position == 1)
    #expect(UIHarnessReaderScenario.position(atPage: 9_999).position == 336)
  }

  @Test("the chapter list has page labels and exactly one current row at the mid-book position")
  func chapterListHasPageLabelsAndOneCurrentRow() {
    let entries = UIHarnessReaderScenario.tocEntries
    #expect(entries.count >= 3)
    #expect(entries.allSatisfy { $0.position != nil && $0.href != nil })
    #expect(entries.contains { $0.depth > 0 })

    let current = UIHarnessReaderScenario.position(atPage: UIHarnessReaderScenario.midBookPage)
    let matches = entries.filter { $0.href == current.href || $0.position == current.position }
    #expect(matches.count == 1)
  }

  @Test("the appearance scenario seeds every control off its default value")
  func appearanceScenarioSeedsEveryControl() {
    let seeded = UIHarnessReaderScenario.appearance.seededPreferences
    #expect(seeded.theme == .sepia)
    #expect(seeded.fontFamily == .serif)
    #expect(seeded.fontSizeStep > ReaderPreferences.defaultFontSizeStep)
    #expect(seeded.lineSpacingStep > ReaderPreferences.defaultLineSpacingStep)
    #expect(seeded.marginsStep > ReaderPreferences.defaultMarginsStep)
    #expect(seeded.textAlignment == .justify)

    // No scenario may start on `.system`: the harness must not change appearance with the host.
    #expect(UIHarnessReaderScenario.readingWithChrome.seededPreferences.theme != .system)
  }

  @Test("only fixed-layout opens a non-reflowable publication")
  @MainActor
  func onlyFixedLayoutIsNonReflowable() async throws {
    let fixed = UIHarnessFakeEPUBRendering(scenario: .fixedLayout)
    let reflowable = UIHarnessFakeEPUBRendering(scenario: .readingWithChrome)
    let url = URL(fileURLWithPath: "/tmp/harness-reader.epub")

    #expect(
      try await fixed.open(
        EPUBOpenRequest(localFileURL: url, preferences: ReaderPreferences(), initialLocation: nil)
      ).reflowable == false
    )
    #expect(
      try await reflowable.open(
        EPUBOpenRequest(localFileURL: url, preferences: ReaderPreferences(), initialLocation: nil)
      ).reflowable
    )
  }

  @Test("protected and corrupt files stay distinct open failures")
  @MainActor
  func protectedAndCorruptStayDistinct() async {
    let url = URL(fileURLWithPath: "/tmp/harness-reader.epub")
    await #expect(throws: EPUBRenderingOpenFailure.drmProtected) {
      _ = try await UIHarnessFakeEPUBRendering(scenario: .protectedFile).open(
        EPUBOpenRequest(localFileURL: url, preferences: ReaderPreferences(), initialLocation: nil)
      )
    }
    await #expect(throws: EPUBRenderingOpenFailure.unopenable) {
      _ = try await UIHarnessFakeEPUBRendering(scenario: .corruptFile).open(
        EPUBOpenRequest(localFileURL: url, preferences: ReaderPreferences(), initialLocation: nil)
      )
    }
  }

  @Test("the fake renderer records commands and walks one page at a time")
  @MainActor
  func fakeRendererRecordsCommands() async throws {
    let renderer = UIHarnessFakeEPUBRendering(scenario: .readingWithChrome)
    _ = try await renderer.open(
      EPUBOpenRequest(
        localFileURL: URL(fileURLWithPath: "/tmp/harness-reader.epub"),
        preferences: ReaderPreferences(),
        initialLocation: nil
      )
    )

    #expect(await renderer.turnPage(.right))
    #expect(renderer.currentPage == 43)
    #expect(await renderer.turnPage(.left))
    #expect(renderer.currentPage == 42)
    #expect(renderer.turns == [.right, .left])

    try await renderer.submit(preferences: ReaderPreferences(theme: .dark))
    #expect(renderer.submittedPreferences.last?.theme == .dark)
  }

  @Test("a page turn at the first page fails rather than wrapping")
  @MainActor
  func firstPageTurnFails() async throws {
    let renderer = UIHarnessFakeEPUBRendering(scenario: .readingWithChrome)
    _ = try await renderer.open(
      EPUBOpenRequest(
        localFileURL: URL(fileURLWithPath: "/tmp/harness-reader.epub"),
        preferences: ReaderPreferences(),
        initialLocation: nil
      )
    )
    try await renderer.go(to: UIHarnessReaderScenario.position(atPage: 1))

    #expect(await renderer.turnPage(.left) == false)
    #expect(renderer.currentPage == 1)
  }
}
