import Foundation
import Persistence
import PlayerCore
import ReaderCore
import SyncEngine
import Synchronization
import TestSupport
import Testing

@testable import AppModel

extension ReaderModelTests {
  // MARK: - Page lifecycle and restore

  /// Avoids a circular wait: Readium completes a navigation only when the navigator's web view
  /// reports it finished, and a view never in a window never lays out. A page mounted only on
  /// `.reading`, which is reached after the restore, would leave the restore waiting on itself.
  /// The page must be mountable while opening.
  @Test("the page is mounted while still opening, not only once the reader is reading")
  func pageIsMountedBeforeTheRestore() async {
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess(restoreTarget: .totalProgression(0.4))
    let renderer = FakeEPUBRendering()
    renderer.hangsOnRestore = true
    let model = makeModel(
      stateReading: stateReading, progress: progress, renderer: renderer,
      restoreBudget: .seconds(30))

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))
    await waitUntil { model.isPageMounted }

    #expect(model.state == .opening)

    openTask.cancel()
    await openTask.value
  }

  /// Laid out but not shown. The page must be in the hierarchy from `.opening` for Readium to lay
  /// it out and finish the restore, and must stay hidden until the restore lands, or the reader
  /// shows page 1 and then jumps.
  @Test("an opening page is laid out but stays covered until the restore lands")
  func openingPageIsMountedButObscured() async {
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess(restoreTarget: .totalProgression(0.4))
    let renderer = FakeEPUBRendering()
    renderer.hangsOnRestore = true
    let model = makeModel(
      stateReading: stateReading, progress: progress, renderer: renderer,
      restoreBudget: .seconds(30))

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))
    await waitUntil { model.isPageMounted }

    #expect(model.isPageObscured)

    openTask.cancel()
    await openTask.value
  }

  @Test("an open that completes before the indicator threshold never shows the indicator")
  func fastOpenNeverShowsOpeningIndicator() async {
    let stateReading = TestReaderStateReading()
    let model = makeModel(
      stateReading: stateReading, openingIndicatorThreshold: .seconds(1))

    await open(model, stateReading: stateReading)

    #expect(model.state == .reading)
    #expect(model.isOpeningIndicatorVisible == false)
  }

  @Test("a slow open shows the indicator until reading begins, without delaying completion")
  func slowOpenShowsIndicatorThenClearsOnReading() async {
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering()
    renderer.waitsForOpenRelease = true
    let model = makeModel(
      stateReading: stateReading, renderer: renderer, openingIndicatorThreshold: .milliseconds(10))

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))
    await waitUntil { renderer.openRequests.count == 1 }
    #expect(await waitUntil { model.isOpeningIndicatorVisible })

    await renderer.releaseOpen()
    await openTask.value

    #expect(model.state == .reading)
    #expect(model.isOpeningIndicatorVisible == false)
  }

  @Test("a slow open failure clears the opening indicator")
  func slowOpenFailureClearsOpeningIndicator() async {
    let stateReading = TestReaderStateReading()
    let preferences = TestReaderPreferencesStore(gateFetch: true)
    let renderer = FakeEPUBRendering()
    renderer.nextOpenFailure = .unopenable
    let model = makeModel(
      stateReading: stateReading, preferences: preferences, renderer: renderer,
      openingIndicatorThreshold: .milliseconds(10))

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))
    #expect(await waitUntil { await preferences.fetchWasRequested })
    #expect(await waitUntil { model.isOpeningIndicatorVisible })

    await preferences.releaseFetch()
    await openTask.value

    #expect(model.state == .unopenable)
    #expect(model.isOpeningIndicatorVisible == false)
  }

  @Test("closing during a slow open clears the opening indicator")
  func closeDuringSlowOpenClearsOpeningIndicator() async {
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering()
    renderer.waitsForOpenRelease = true
    let model = makeModel(
      stateReading: stateReading, renderer: renderer, openingIndicatorThreshold: .milliseconds(10))

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))
    await waitUntil { renderer.openRequests.count == 1 }
    #expect(await waitUntil { model.isOpeningIndicatorVisible })

    await model.close()
    #expect(model.isOpeningIndicatorVisible == false)
    await awaitQuiescence("the cancelled reveal task to stay silent") {
      "\(model.isOpeningIndicatorVisible)"
    }
    #expect(model.isOpeningIndicatorVisible == false)

    await renderer.releaseOpen()
    await openTask.value
  }

  @Test("the opening indicator never appears for a download state")
  func downloadingNeverShowsOpeningIndicator() async {
    let stateReading = TestReaderStateReading()
    let model = makeModel(
      stateReading: stateReading, openingIndicatorThreshold: .milliseconds(10))

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloading(progress: 0.4))
    await waitUntil { model.state == .downloading(progress: 0.4) }
    await awaitQuiescence("the indicator to stay hidden while downloading") {
      "\(model.isOpeningIndicatorVisible)"
    }

    #expect(model.isOpeningIndicatorVisible == false)

    openTask.cancel()
    stateReading.finish()
    await openTask.value
  }

  @Test("the page is uncovered once the reader is reading")
  func readingPageIsNotObscured() async {
    let stateReading = TestReaderStateReading()
    let model = makeModel(stateReading: stateReading)
    await open(model, stateReading: stateReading)

    #expect(model.isPageMounted)
    #expect(model.isPageObscured == false)
  }

  @Test("closing unmounts the page")
  func closingUnmountsThePage() async {
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering()
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)
    #expect(model.isPageMounted)

    await model.close()

    #expect(model.isPageMounted == false)
  }

  /// Readium can report `ready` while the restore that follows never returns, leaving the reader
  /// on "Opening book…". Restoring is best-effort (the call site discards a restore that throws),
  /// so a hang must not hold the book hostage either.
  @Test("a restore that never returns cannot keep an opened book from being read")
  func hangingRestoreDoesNotBlockReading() async {
    let stateReading = TestReaderStateReading()
    let restored = position(total: 0.25, href: "chapter-1", position: 2)
    let progress = TestReaderProgressAccess(restoreTarget: .position(restored))
    let renderer = FakeEPUBRendering()
    renderer.hangsOnRestore = true
    let model = makeModel(
      stateReading: stateReading, progress: progress, renderer: renderer,
      restoreBudget: .milliseconds(50))

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))
    await openTask.value

    #expect(model.state == .reading)
    #expect(renderer.goToPositions == [restored])
  }

  /// Opening from a contents entry lands on the caller's target, not the saved position. The saved
  /// position still seeds the tracker, so arriving elsewhere counts as a real move and is written
  /// back.
  @Test("an explicit open target outranks the saved reading position")
  func anExplicitOpenTargetOutranksTheSavedPosition() async {
    let stateReading = TestReaderStateReading()
    let saved = position(total: 0.1, href: "chapter-1")
    let requested = position(total: 0.6, href: "chapter-5")
    let progress = TestReaderProgressAccess(restoreTarget: .position(saved))
    let renderer = FakeEPUBRendering()
    let model = makeModel(stateReading: stateReading, progress: progress, renderer: renderer)

    let openTask = Task { await model.open(initialTarget: .position(requested)) }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))
    await openTask.value

    #expect(model.state == .reading)
    #expect(renderer.goToPositions == [requested])

    renderer.emit(requested)
    await waitUntil { model.currentPosition == requested }
    await model.close()
    #expect(await progress.writtenPositions == [requested])
  }

  @Test("no open target keeps the saved reading position")
  func noOpenTargetKeepsTheSavedPosition() async {
    let stateReading = TestReaderStateReading()
    let saved = position(total: 0.1, href: "chapter-1")
    let progress = TestReaderProgressAccess(restoreTarget: .position(saved))
    let renderer = FakeEPUBRendering()
    let model = makeModel(stateReading: stateReading, progress: progress, renderer: renderer)

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))
    await openTask.value

    #expect(renderer.goToPositions == [saved])
  }

  /// A book that has never been opened has no saved position to fall back to, so the requested
  /// entry is the only thing to aim at.
  @Test("an open target lands even with no saved position at all")
  func anOpenTargetLandsWithNoSavedPosition() async {
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess(restoreTarget: nil)
    let renderer = FakeEPUBRendering()
    let model = makeModel(stateReading: stateReading, progress: progress, renderer: renderer)

    let openTask = Task { await model.open(initialTarget: .totalProgression(0.75)) }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))
    await openTask.value

    #expect(renderer.goToTotalProgressions == [0.75])
  }

  @Test("a total-progression restore that never returns is abandoned the same way")
  func hangingProgressionRestoreDoesNotBlockReading() async {
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess(restoreTarget: .totalProgression(0.4))
    let renderer = FakeEPUBRendering()
    renderer.hangsOnRestore = true
    let model = makeModel(
      stateReading: stateReading, progress: progress, renderer: renderer,
      restoreBudget: .milliseconds(50))

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))
    await openTask.value

    #expect(model.state == .reading)
    #expect(renderer.goToTotalProgressions == [0.4])
  }

  @Test("restore is applied before the first position reaches the tracker or UI")
  func restoreBeforePositionReport() async {
    let restored = position(total: 0.25, href: "chapter-1", position: 2)
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess(restoreTarget: .position(restored))
    let renderer = FakeEPUBRendering()
    let model = makeModel(
      stateReading: stateReading, progress: progress, renderer: renderer)

    let openTask = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))
    await openTask.value

    #expect(renderer.goToPositions == [restored])
    #expect(model.currentPosition == nil)

    let firstReported = position(total: 0.30, href: "chapter-1", position: 3)
    renderer.emit(firstReported)
    await waitUntil { model.currentPosition == firstReported }
    #expect(model.currentPosition == firstReported)
  }

  // MARK: - Page turns

  @Test("page turns delegate left and right directions in order")
  func pageTurnsDelegateDirectionsInOrder() async {
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering()
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)

    await model.turnPage(.left)
    await model.turnPage(.right)

    #expect(renderer.turnPageDirections == [.left, .right])
  }

  @Test("a page turn at the book edge leaves position, display, and progress writes untouched")
  func pageTurnAtBookEdgeLeavesReaderStateUntouched() async {
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess()
    let renderer = FakeEPUBRendering()
    renderer.turnPageResult = false
    let model = makeModel(
      stateReading: stateReading, progress: progress, renderer: renderer)
    await open(model, stateReading: stateReading)
    let positionBefore = model.currentPosition
    let displayBefore = model.progressDisplay

    await model.turnPage(.right)

    #expect(model.currentPosition == positionBefore)
    #expect(model.progressDisplay == displayBefore)
    #expect(await progress.writtenPositions.isEmpty)
  }

  @Test("a successful page turn waits for a position update before changing the display")
  func successfulPageTurnWaitsForPositionUpdate() async {
    let current = position(total: 0.42, href: "chapter-2", position: 2)
    let publication = OpenedEPUBPublication(
      toc: [TOCEntry(title: "Chapter 2", href: "chapter-2", depth: 0)],
      positions: [position(total: 0, href: "chapter-1", position: 1), current],
      reflowable: true)
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering(publication: publication)
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)
    let displayBefore = model.progressDisplay

    await model.turnPage(.right)

    #expect(model.currentPosition == nil)
    #expect(model.progressDisplay == displayBefore)
    #expect(model.progressDisplay.chapterTimeRemainingText == nil)
    #expect(model.progressDisplay.bookTimeRemainingText == nil)

    renderer.emit(current)
    await waitUntil { model.currentPosition == current }

    #expect(
      model.progressDisplay
        == ReaderProgressDisplay(
          text: "42% · Chapter 2 · Page 2 of 2",
          pageText: "Page 2 of 2",
          percentText: "42%",
          percentage: 0.42,
          chapterTitle: "Chapter 2",
          page: 2,
          pageCount: 2))
  }

  @Test("page turns never use total progression arithmetic")
  func pageTurnDoesNotUseTotalProgression() async {
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering()
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)

    await model.turnPage(.left)

    #expect(renderer.goToTotalProgressions.isEmpty)
  }

  // MARK: - Chrome

  @Test("chrome visibility toggles deterministically")
  func chromeToggleState() {
    let model = makeModel()

    #expect(model.isChromeVisible)
    model.toggleChrome()
    #expect(model.isChromeVisible == false)
    model.toggleChrome()
    #expect(model.isChromeVisible)
  }

  @Test("a page tap while the chrome is up only dismisses it, then the next tap turns the page")
  func pageTapWithChromeUpOnlyDismissesIt() async {
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering()
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)

    #expect(model.isChromeVisible)
    await model.turnPage(fromTap: .right)

    #expect(model.isChromeVisible == false)
    #expect(renderer.turnPageDirections.isEmpty)

    await model.turnPage(fromTap: .right)

    #expect(model.isChromeVisible == false)
    #expect(renderer.turnPageDirections == [.right])
  }

  @Test("a swipe on the page recedes the chrome without turning the page itself")
  func pageSwipeRecedesTheChrome() async {
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering()
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)

    #expect(model.isChromeVisible)
    model.pageSwiped()

    #expect(model.isChromeVisible == false)
    #expect(renderer.turnPageDirections.isEmpty)

    model.pageSwiped()

    #expect(model.isChromeVisible == false)
  }

  @Test("a page turn from the progress rail leaves the chrome where it is")
  func railPageTurnKeepsTheChromeVisible() async {
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering()
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)

    await model.turnPage(.right)

    // The rail is only reachable while the chrome is up, and it is not the tap that would prove
    // the reader can bring the chrome back.
    #expect(model.isChromeVisible)
    #expect(renderer.turnPageDirections == [.right])
  }

  // MARK: - Preferences

  @Test("a discarded model never closes the renderer that is showing the book")
  func discardedModelLeavesTheOpenRendererAlone() async {
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering()
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)
    #expect(renderer.lifecycleState == .publicationOpen)

    // `ReaderView` builds a `ReaderModel` on every re-evaluation of the presenting view and
    // `State(initialValue:)` throws all but the first away. The renderer is shared, so a discarded
    // model must not take the open publication down with it.
    var discardedModels: [ReaderModel?] = []
    var lifecycles: [FakeAppLifecycle] = []
    for _ in 0..<3 {
      let lifecycle = FakeAppLifecycle()
      let discarded = makeModel(
        stateReading: TestReaderStateReading(), renderer: renderer, lifecycle: lifecycle)
      await waitUntil { lifecycle.lifecycleSubscriberCount == 1 }
      discardedModels.append(discarded)
      lifecycles.append(lifecycle)
    }
    for index in discardedModels.indices {
      discardedModels[index] = nil
      await waitUntil { lifecycles[index].lifecycleSubscriberCount == 0 }
    }

    #expect(renderer.lifecycleState == .publicationOpen)
    #expect(model.state == .reading)
  }

  @Test("preference changes persist and reach the renderer once")
  func preferencesPersistAndSubmitOncePerChange() async {
    let stateReading = TestReaderStateReading()
    let preferences = TestReaderPreferencesStore()
    let renderer = FakeEPUBRendering()
    let model = makeModel(
      stateReading: stateReading, preferences: preferences, renderer: renderer)
    await open(model, stateReading: stateReading)

    let changed = ReaderPreferences(theme: .sepia, fontFamily: .serif, fontSizeStep: 2)
    await model.updatePreferences(changed)

    #expect(await preferences.writes == [changed])
    #expect(renderer.submittedPreferences.count == 1)
    #expect(renderer.submittedPreferences.last == changed)
  }

  @Test("choosing a footer readout persists it without resubmitting the page's layout")
  func footerReadoutPersistsWithoutReachingTheRenderer() async {
    let stateReading = TestReaderStateReading()
    let store = TestReaderPreferencesStore()
    let renderer = FakeEPUBRendering()
    let model = makeModel(stateReading: stateReading, preferences: store, renderer: renderer)
    await open(model, stateReading: stateReading)

    await model.selectFooterReadout(.percent)

    #expect(model.preferences.footerReadout == .percent)
    #expect(await store.writes.last?.footerReadout == .percent)
    #expect(renderer.submittedPreferences.isEmpty)

    // An appearance change submitted as a whole value must not undo the readout.
    var themeOnly = model.preferences
    themeOnly.theme = .dark
    await model.updatePreferences(themeOnly)
    #expect(model.preferences.footerReadout == .percent)
  }

  @Test("choosing the footer readout already shown writes nothing")
  func unchangedFooterReadoutWritesNothing() async {
    let stateReading = TestReaderStateReading()
    let store = TestReaderPreferencesStore()
    let model = makeModel(stateReading: stateReading, preferences: store)
    await open(model, stateReading: stateReading)

    await model.selectFooterReadout(.page)

    #expect(await store.writes.isEmpty)
  }

  @Test("a one-field preference change leaves alignment, margins, and reading mode intact")
  func oneFieldPreferenceChangeKeepsEveryOtherField() async {
    let stateReading = TestReaderStateReading()
    let store = TestReaderPreferencesStore()
    let renderer = FakeEPUBRendering()
    let model = makeModel(stateReading: stateReading, preferences: store, renderer: renderer)
    await open(model, stateReading: stateReading)

    let configured = ReaderPreferences(
      theme: .light, fontFamily: .serif, fontSizeStep: 3, lineSpacingStep: 2, marginsStep: 3,
      readingMode: .scroll, textAlignment: .justify)
    await model.updatePreferences(configured)

    // Only the theme differs; the view submits whole values, so every other field is resubmitted.
    var themeOnly = configured
    themeOnly.theme = .dark
    await model.updatePreferences(themeOnly)

    #expect(model.preferences.theme == .dark)
    #expect(model.preferences.textAlignment == .justify)
    #expect(model.preferences.marginsStep == 3)
    #expect(model.preferences.lineSpacingStep == 2)
    #expect(model.preferences.readingMode == .scroll)
    #expect(model.preferences.fontFamily == .serif)
    #expect(model.preferences.fontSizeStep == 3)
    #expect(await store.writes.last == model.preferences)
  }

  // MARK: - TOC and progress copy

  @Test("TOC selection navigates to the target and records the resulting position")
  func tocSelectionNavigatesAndRecordsPosition() async {
    let target = position(total: 0.5, href: "chapter-2", position: 5)
    let publication = OpenedEPUBPublication(
      toc: [TOCEntry(title: "Chapter 2", position: 5, depth: 0)],
      positions: [target], reflowable: true)
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering(publication: publication)
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)

    await model.selectTOC(publication.toc[0])
    #expect(renderer.goToPositions == [target])
    renderer.emit(target)
    await waitUntil { model.currentPosition == target }
    #expect(model.currentPosition == target)
  }

  @Test("progress display includes percent, chapter, and page count when positions are known")
  func progressDisplayIsDeterministicWithPositions() async {
    let current = position(total: 0.42, href: "chapter-2", position: 2)
    let publication = OpenedEPUBPublication(
      toc: [TOCEntry(title: "Chapter 2", href: "chapter-2", depth: 0)],
      positions: [position(total: 0, href: "chapter-1", position: 1), current], reflowable: true)
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering(publication: publication)
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)
    renderer.emit(current)
    await waitUntil { model.currentPosition == current }

    #expect(model.progressDisplay.text == "42% · Chapter 2 · Page 2 of 2")
  }

  @Test("a page past a chapter's first still names that chapter")
  func progressDisplayNamesTheChapterMidway() async {
    // A navigation document's hrefs carry fragments that a position's href never does, so only
    // the entry's start position can place a later page in its chapter.
    let current = position(total: 0.5, href: "Text/chapter-2.xhtml", position: 5)
    let publication = OpenedEPUBPublication(
      toc: [
        TOCEntry(title: "Chapter 1", href: "Text/chapter-1.xhtml#c1", position: 1, depth: 0),
        TOCEntry(title: "Chapter 2", href: "Text/chapter-2.xhtml#c2", position: 4, depth: 0),
        TOCEntry(title: "Chapter 3", href: "Text/chapter-3.xhtml#c3", position: 8, depth: 0),
      ],
      positions: (1...10).map { position(total: Double($0) / 10, href: "position-\($0)", position: $0) },
      reflowable: true)
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering(publication: publication)
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)
    renderer.emit(current)
    await waitUntil { model.currentPosition == current }

    #expect(model.progressDisplay.chapterTitle == "Chapter 2")
    #expect(model.progressDisplay.isChapterOpening == false)
  }

  @Test("a chapter's first page is marked as its opening")
  func progressDisplayMarksTheChapterOpening() async {
    let current = position(total: 0.4, href: "Text/chapter-2.xhtml", position: 4)
    let publication = OpenedEPUBPublication(
      toc: [
        TOCEntry(title: "Chapter 1", href: "Text/chapter-1.xhtml#c1", position: 1, depth: 0),
        TOCEntry(title: "Chapter 2", href: "Text/chapter-2.xhtml#c2", position: 4, depth: 0),
      ],
      positions: (1...10).map { position(total: Double($0) / 10, href: "position-\($0)", position: $0) },
      reflowable: true)
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering(publication: publication)
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)
    renderer.emit(current)
    await waitUntil { model.currentPosition == current }

    #expect(model.progressDisplay.chapterTitle == "Chapter 2")
    #expect(model.progressDisplay.isChapterOpening)
  }

  @Test("a page before the first chapter names no chapter")
  func progressDisplayBeforeTheFirstChapterHasNoChapter() async {
    let current = position(total: 0.1, href: "Text/cover.xhtml", position: 1)
    let publication = OpenedEPUBPublication(
      toc: [TOCEntry(title: "Chapter 1", href: "Text/chapter-1.xhtml#c1", position: 3, depth: 0)],
      positions: (1...10).map { position(total: Double($0) / 10, href: "position-\($0)", position: $0) },
      reflowable: true)
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering(publication: publication)
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)
    renderer.emit(current)
    await waitUntil { model.currentPosition == current }

    #expect(model.progressDisplay.chapterTitle == nil)
    #expect(model.progressDisplay.isChapterOpening == false)
  }

  @Test("progress display includes chapter and book reading time")
  func progressDisplayIncludesChapterAndBookReadingTime() async {
    let current = position(total: 0.42, href: "chapter-2", position: 5)
    let publication = OpenedEPUBPublication(
      toc: [
        TOCEntry(title: "Chapter 1", href: "chapter-1", depth: 0, startProgression: 0.1),
        TOCEntry(title: "Chapter 2", href: "chapter-2", depth: 0, startProgression: 0.2),
        TOCEntry(title: "Chapter 3", href: "chapter-3", depth: 0, startProgression: 0.7),
      ],
      positions: (1...10).map { position(total: Double($0) / 10, href: "position-\($0)", position: $0) },
      reflowable: true)
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering(publication: publication)
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)
    renderer.emit(current)
    await waitUntil { model.currentPosition == current }

    #expect(model.progressDisplay.chapterTimeRemainingText == "2 min left in chapter")
    #expect(model.progressDisplay.bookTimeRemainingText == "About 5 min left in book")
    #expect(
      model.progressDisplay.text
        == "42% · Chapter 2 · Page 5 of 10 · About 5 min left in book"
    )
  }

  @Test("progress display is percent-only when the positions list is unknown")
  func progressDisplayWithoutPositionsIsPercentOnly() async {
    let current = position(total: 0.42, href: "chapter-2", position: nil)
    let publication = OpenedEPUBPublication(
      toc: [TOCEntry(title: "Chapter 2", href: "chapter-2", depth: 0)], positions: nil)
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering(publication: publication)
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)
    renderer.emit(current)
    await waitUntil { model.currentPosition == current }

    #expect(model.progressDisplay.text == "42%")
    #expect(model.progressDisplay.chapterTimeRemainingText == nil)
    #expect(model.progressDisplay.bookTimeRemainingText == nil)
  }

  @Test("progress display separates page and percent copy when positions are known")
  func progressDisplaySeparatesPageAndPercentWithPositions() async {
    let current = position(total: 0.42, href: "chapter-2", position: 2)
    let publication = OpenedEPUBPublication(
      toc: [TOCEntry(title: "Chapter 2", href: "chapter-2", depth: 0)],
      positions: [position(total: 0, href: "chapter-1", position: 1), current], reflowable: true)
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering(publication: publication)
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)
    renderer.emit(current)
    await waitUntil { model.currentPosition == current }

    #expect(model.progressDisplay.pageText == "Page 2 of 2")
    #expect(model.progressDisplay.percentText == "42%")
  }

  @Test("progress display keeps percent copy when positions are unknown")
  func progressDisplayKeepsPercentWithoutPageCopy() async {
    let current = position(total: 0.42, href: "chapter-2", position: nil)
    let publication = OpenedEPUBPublication(
      toc: [TOCEntry(title: "Chapter 2", href: "chapter-2", depth: 0)], positions: nil)
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering(publication: publication)
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)
    renderer.emit(current)
    await waitUntil { model.currentPosition == current }

    #expect(model.progressDisplay.pageText == nil)
    #expect(model.progressDisplay.percentText == "42%")
  }

  @Test("progress display omits a zero page and zero page count")
  func progressDisplayOmitsZeroPageAndCount() async {
    let current = position(total: 0.12, href: "chapter", position: 0)
    let publication = OpenedEPUBPublication(
      toc: [TOCEntry(title: "Chapter", href: "chapter", depth: 0)],
      positions: [],
      reflowable: true)
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering(publication: publication)
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)
    renderer.emit(current)
    await waitUntil { model.currentPosition == current }

    #expect(model.progressDisplay.pageText == nil)
    #expect(model.progressDisplay.percentText == "12%")
    #expect(model.progressDisplay.text == "12% · Chapter")
    #expect(model.progressDisplay.text.contains("Page 0 of 0") == false)
  }

  @Test("a TOC entry with a position exposes a one-based page label")
  func tocEntryWithPositionExposesOneBasedPageLabel() async {
    let positions = (0..<42).map { index in
      position(total: Double(index) / 41, href: "chapter-\(index)", position: index + 1)
    }
    let entry = TOCEntry(title: "Chapter 42", position: 42, depth: 0)
    let publication = OpenedEPUBPublication(toc: [entry], positions: positions)
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering(publication: publication)
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)

    #expect(model.pageLabel(for: entry) == "42")
  }

  @Test("a TOC entry without a position exposes no page label")
  func tocEntryWithoutPositionExposesNoPageLabel() async {
    let entry = TOCEntry(title: "Chapter", href: "chapter", depth: 0)
    let publication = OpenedEPUBPublication(
      toc: [entry], positions: [position(total: 0, href: "chapter", position: 1)])
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering(publication: publication)
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)

    #expect(model.pageLabel(for: entry) == nil)
  }

  @Test("a publication without positions exposes no TOC page labels")
  func publicationWithoutPositionsExposesNoTOCPageLabels() async {
    let entry = TOCEntry(title: "Chapter", position: 42, depth: 0)
    let publication = OpenedEPUBPublication(toc: [entry], positions: nil)
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering(publication: publication)
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)

    #expect(model.pageLabel(for: entry) == nil)
  }

  @Test("current chapter matching still works when the href matches")
  func currentChapterMatchingStillWorksWhenHrefMatches() async {
    let current = position(total: 0.42, href: "chapter-2", position: 1)
    let entry = TOCEntry(title: "Chapter 2", href: "chapter-2", depth: 0)
    let publication = OpenedEPUBPublication(toc: [entry], positions: [current])
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering(publication: publication)
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)
    renderer.emit(current)
    await waitUntil { model.currentPosition == current }

    #expect(model.progressDisplay.chapterTitle == "Chapter 2")
  }

  @Test("current chapter matching also works when only the position matches")
  func currentChapterMatchingAlsoWorksWhenOnlyPositionMatches() async {
    let current = position(total: 0.42, href: "resource.xhtml", position: 2)
    let entry = TOCEntry(title: "Chapter 2", href: "toc.xhtml", position: 2, depth: 0)
    let publication = OpenedEPUBPublication(
      toc: [entry],
      positions: [
        position(total: 0, href: "chapter-1.xhtml", position: 1), current,
      ])
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering(publication: publication)
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)
    renderer.emit(current)
    await waitUntil { model.currentPosition == current }

    #expect(model.progressDisplay.chapterTitle == "Chapter 2")
  }
}
