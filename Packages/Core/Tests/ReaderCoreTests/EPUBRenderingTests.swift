import Foundation
import TestSupport
import Testing

@testable import ReaderCore

@MainActor
@Suite struct EPUBRenderingTests {

  @Test("page directions are screen sides rather than reading-order commands")
  func pageDirectionsAreDirectional() async throws {
    let renderer = FakeEPUBRendering()
    try await renderer.start()
    _ = try await renderer.open(
      EPUBOpenRequest(
        localFileURL: URL(fileURLWithPath: "/tmp/book.epub"),
        preferences: ReaderPreferences(), initialLocation: nil))

    #expect(ReaderPageDirection.left != .right)
    #expect(await renderer.turnPage(.left))
    #expect(await renderer.turnPage(.right))
    #expect(renderer.turnPageDirections == [.left, .right])
  }

  @Test func fakeConformsAndOpensAFileWithReaderMetadata() async throws {
    let position = ReadingPosition(
      href: "Text/chapter.xhtml",
      progression: 0.25,
      totalProgression: 0.4,
      position: 7
    )
    let publication = OpenedEPUBPublication(
      toc: [TOCEntry(title: "Chapter one", href: "Text/chapter.xhtml", depth: 0)],
      positions: [position],
      reflowable: false
    )
    let renderer = FakeEPUBRendering(publication: publication)
    let boundary: any EPUBRendering = renderer

    try await boundary.start()
    let opened = try await boundary.open(
      EPUBOpenRequest(
        localFileURL: URL(fileURLWithPath: "/tmp/book.epub"),
        preferences: ReaderPreferences(), initialLocation: nil))

    #expect(renderer.openedLocalFileURLs == [URL(fileURLWithPath: "/tmp/book.epub")])
    #expect(opened.toc == publication.toc)
    #expect(opened.positions == [position])
    #expect(opened.reflowable == false)
    #expect(opened.fixedLayout)
  }

}
