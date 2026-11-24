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
  // MARK: - Scrub, seek-back, and jump offers

  @Test("a scrub previews the page, percentage, and chapter under the finger")
  func scrubPreviewNamesThePageUnderTheFinger() async {
    let (model, _) = await openScrubbableBook(at: 2)

    let preview = model.scrubPreview(forTotalProgression: 0.55)

    #expect(preview.page == 5)
    #expect(preview.pageCount == 10)
    #expect(preview.percentText == "50%")
    #expect(preview.chapterTitle == "Chapter 2")
  }

  @Test("a scrub before the first page's progression previews the first page")
  func scrubPreviewClampsToTheFirstPage() async {
    let (model, _) = await openScrubbableBook(at: 2)

    #expect(model.scrubPreview(forTotalProgression: 0).page == 1)
    #expect(model.scrubPreview(forTotalProgression: 1).page == 10)
  }

  @Test("without a positions list a scrub previews the percentage alone")
  func scrubPreviewWithoutPositionsIsPercentOnly() async {
    let current = position(total: 0.2, href: "chapter-1")
    let renderer = FakeEPUBRendering(publication: OpenedEPUBPublication(positions: nil))
    let stateReading = TestReaderStateReading()
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)
    renderer.emit(current)
    await waitUntil { model.currentPosition == current }

    let preview = model.scrubPreview(forTotalProgression: 0.734)

    #expect(preview.page == nil)
    #expect(preview.percentText == "73%")
  }

  @Test("a seek lands on the previewed page and offers a way back to where reading was")
  func seekLandsOnThePreviewedPageAndOffersReturn() async {
    let (model, renderer) = await openScrubbableBook(at: 2)
    let origin = model.currentPosition

    await model.seek(toTotalProgression: 0.55)

    #expect(renderer.goToPositions.last?.position == 5)
    #expect(model.returnPoint?.position == origin)
    #expect(model.returnPoint?.label == "Back to page 2")
  }

  @Test("going back returns to the recorded position and withdraws the offer")
  func goBackReturnsToTheRecordedPosition() async {
    let (model, renderer) = await openScrubbableBook(at: 2)
    let origin = model.currentPosition
    await model.seek(toTotalProgression: 0.55)

    await model.goBack()

    #expect(renderer.goToPositions.last == origin)
    #expect(model.returnPoint == nil)
  }

  @Test("a second scrub while the offer is up still leads back to the original place")
  func repeatedSeeksKeepTheOriginalReturnPoint() async {
    let (model, renderer) = await openScrubbableBook(at: 2)
    let origin = model.currentPosition
    await model.seek(toTotalProgression: 0.55)
    let first = model.returnPoint
    renderer.emit(position(total: 0.5, href: "position-5", position: 5))
    await waitUntil { model.currentPosition?.position == 5 }

    await model.seek(toTotalProgression: 0.85)

    #expect(model.returnPoint?.position == origin)
    // A fresh seek restarts the offer's timeout, so it must not compare equal to the first.
    #expect(model.returnPoint != first)
  }

  @Test("dismissing the offer withdraws it without moving")
  func dismissReturnPointDoesNotNavigate() async {
    let (model, renderer) = await openScrubbableBook(at: 2)
    await model.seek(toTotalProgression: 0.55)
    let navigations = renderer.goToPositions.count

    model.dismissReturnPoint()

    #expect(model.returnPoint == nil)
    #expect(renderer.goToPositions.count == navigations)
  }

  @Test("a seek that lands back on the current page offers no way back")
  func seekToTheCurrentPageOffersNoReturn() async {
    let (model, _) = await openScrubbableBook(at: 2)

    await model.seek(toTotalProgression: 0.25)

    #expect(model.returnPoint == nil)
  }

  @Test("without a positions list a seek goes by progression and offers a return by percentage")
  func seekWithoutPositionsUsesProgression() async {
    let current = position(total: 0.2, href: "chapter-1")
    let renderer = FakeEPUBRendering(publication: OpenedEPUBPublication(positions: nil))
    let stateReading = TestReaderStateReading()
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)
    renderer.emit(current)
    await waitUntil { model.currentPosition == current }

    await model.seek(toTotalProgression: 0.6)

    #expect(renderer.goToTotalProgressions.last == 0.6)
    #expect(model.returnPoint?.label == "Back to 20%")
  }

  @Test("a contents jump offers a way back to where reading was")
  func tocJumpOffersReturn() async {
    let (model, renderer) = await openScrubbableBook(at: 2)
    let origin = model.currentPosition

    await model.selectTOC(TOCEntry(title: "Chapter 2", position: 4, depth: 0))

    #expect(renderer.goToPositions.last?.position == 4)
    #expect(model.returnPoint?.position == origin)
    #expect(model.returnPoint?.label == "Back to page 2")
  }

  @Test("a contents jump to the page being read offers no way back")
  func tocJumpToTheCurrentPageOffersNoReturn() async {
    let (model, _) = await openScrubbableBook(at: 4)

    await model.selectTOC(TOCEntry(title: "Chapter 2", position: 4, depth: 0))

    #expect(model.returnPoint == nil)
  }

  @Test("a search jump offers a way back and highlights the hit")
  func searchJumpOffersReturn() async throws {
    let (model, renderer) = await openScrubbableBook(at: 2)
    let origin = model.currentPosition
    renderer.isSearchable = true
    renderer.searchHits = [
      ReaderSearchHit(
        id: "hit-1", chapterTitle: nil, before: "", highlight: "wind", after: "",
        totalProgression: 0.7)
    ]
    for try await _ in renderer.search(query: "wind") {}

    await model.goToSearchHit(id: "hit-1")

    #expect(renderer.goToSearchHitIDs == ["hit-1"])
    #expect(renderer.highlightedSearchHitID == "hit-1")
    #expect(model.returnPoint?.position == origin)
  }

  @Test("a jump that fails to move leaves no offer behind")
  func failedJumpWithdrawsTheOffer() async {
    let (model, renderer) = await openScrubbableBook(at: 2)
    renderer.alwaysFailNavigation = true

    await model.seek(toTotalProgression: 0.55)
    await model.goToSearchHit(id: "missing")

    #expect(model.returnPoint == nil)
  }

  @Test("a failed jump while an offer is up keeps that offer")
  func failedJumpKeepsTheEarlierOffer() async {
    let (model, renderer) = await openScrubbableBook(at: 2)
    await model.seek(toTotalProgression: 0.55)
    let offer = model.returnPoint
    renderer.alwaysFailNavigation = true

    await model.seek(toTotalProgression: 0.85)

    #expect(model.returnPoint == offer)
  }
}
