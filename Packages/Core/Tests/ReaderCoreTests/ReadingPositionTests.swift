import Foundation
import Testing

@testable import ReaderCore

@Suite struct ReadingPositionTests {

  @Test func readingPositionJSONRoundTripsLosslessly() throws {
    let position = ReadingPosition(
      href: "Text/chapter-02.xhtml",
      progression: 0.25,
      totalProgression: 0.42,
      position: 17,
      cfi: "epubcfi(/6/4!/4/2/1:0)"
    )

    let data = try JSONEncoder().encode(position)
    let decoded = try JSONDecoder().decode(ReadingPosition.self, from: data)

    #expect(decoded == position)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["text"] == nil)
  }

  @Test func missingNullAndWrongTypeOptionalsDecodeAsAbsent() throws {
    let missing = Data(
      #"{"href":"Text/chapter.xhtml","progression":0.1,"totalProgression":0.2}"#.utf8
    )
    let nulls = Data(
      #"{"href":"Text/chapter.xhtml","progression":0.1,"totalProgression":0.2,"position":null,"cfi":null}"#.utf8
    )
    let wrongTypes = Data(
      #"{"href":"Text/chapter.xhtml","progression":0.1,"totalProgression":0.2,"position":"17","cfi":42}"#.utf8
    )

    for data in [missing, nulls, wrongTypes] {
      let position = try JSONDecoder().decode(ReadingPosition.self, from: data)
      #expect(position.position == nil)
      #expect(position.cfi == nil)
    }
  }

  @Test func oversizedHrefIsRejected() throws {
    let href = String(repeating: "h", count: ReadingPosition.maximumStringBytes + 1)
    let data = Data(
      "{\"href\":\"\(href)\",\"progression\":0.1,\"totalProgression\":0.2}".utf8
    )

    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(ReadingPosition.self, from: data)
    }
  }

  @Test func oversizedCFIIsRejected() throws {
    let cfi = "epubcfi(/6/4!/4/2/" + String(repeating: "1", count: ReadingPosition.maximumStringBytes) + ")"
    #expect(cfi.utf8.count > ReadingPosition.maximumStringBytes)
    let data = Data(
      "{\"href\":\"Text/chapter.xhtml\",\"progression\":0.1,\"totalProgression\":0.2,\"cfi\":\"\(cfi)\"}".utf8
    )

    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(ReadingPosition.self, from: data)
    }
  }

  @Test func validatedRejectsAnOversizedHrefBeforeItReachesMemory() {
    let href = String(repeating: "h", count: ReadingPosition.maximumStringBytes + 1)

    #expect(
      ReadingPosition.validated(href: href, progression: 0.1, totalProgression: 0.2) == nil)
  }

  @Test func validatedAcceptsAnHrefExactlyAtTheBound() throws {
    let href = String(repeating: "h", count: ReadingPosition.maximumStringBytes)

    let position = try #require(
      ReadingPosition.validated(href: href, progression: 0.1, totalProgression: 0.2))

    #expect(position.href == href)
  }

  @Test func validatedDropsAnOversizedCFIRatherThanTheWholePosition() throws {
    let cfi = "epubcfi(/6/4!/4/2/" + String(repeating: "1", count: ReadingPosition.maximumStringBytes) + ")"

    let position = try #require(
      ReadingPosition.validated(
        href: "Text/chapter.xhtml", progression: 0.1, totalProgression: 0.2, cfi: cfi))

    #expect(position.cfi == nil)
  }

  @Test(
    "progressions clamp into the unit interval",
    arguments: [(-0.25, 0.0, 0.0), (0.25, 0.25, 0.25), (1.25, 1.0, 1.0)]
  )
  func progressionsClampIntoTheUnitInterval(
    input: (Double, Double, Double)
  ) {
    let position = ReadingPosition(
      href: "Text/chapter.xhtml",
      progression: input.0,
      totalProgression: input.1
    )

    #expect(position.progression == input.1)
    #expect(position.totalProgression == input.2)
  }

  @Test func ebookProgressDerivationEqualsTotalProgression() {
    let position = ReadingPosition(
      href: "Text/chapter.xhtml",
      progression: 0.31,
      totalProgression: 0.73
    )

    #expect(ebookProgress(for: position) == position.totalProgression)
    #expect(position.ebookProgress == position.totalProgression)
  }

  @Test func equalityAndOrderingHelpersAreDeterministic() {
    let earlier = ReadingPosition(
      href: "Text/chapter-b.xhtml",
      progression: 0.9,
      totalProgression: 0.2
    )
    let sameProgressionA = ReadingPosition(
      href: "Text/chapter-a.xhtml",
      progression: 0.1,
      totalProgression: 0.5
    )
    let sameProgressionB = ReadingPosition(
      href: "Text/chapter-b.xhtml",
      progression: 0.1,
      totalProgression: 0.5
    )
    let later = ReadingPosition(
      href: "Text/chapter.xhtml",
      progression: 0.1,
      totalProgression: 0.8
    )

    #expect(sameProgressionA == sameProgressionA)
    #expect(sameProgressionA != sameProgressionB)
    #expect(
      [later, sameProgressionB, earlier, sameProgressionA].sorted()
        == [earlier, sameProgressionA, sameProgressionB, later]
    )
  }

  // MARK: - CFI shape gate

  @Test func cfiGateAcceptsAGenuineEPUBCFI() {
    let cfi = "epubcfi(/6/4!/4/2/1:0)"

    #expect(validatedEPUBCFI(cfi) == cfi)
  }

  @Test func cfiGateRejectsReadiumPartialCFIFragment() {
    let partialCFI = "/4/2/1:0"

    #expect(validatedEPUBCFI(partialCFI) == nil)
    #expect(validatedEPUBCFI(partialCFI) != "epubcfi(\(partialCFI))")
  }

  @Test func cfiGateRejectsEmptyCFI() {
    #expect(validatedEPUBCFI("") == nil)
    #expect(validatedEPUBCFI("epubcfi()") == nil)
    #expect(validatedEPUBCFI("  epubcfi(/6/4!/4/2/1:0)  ") == nil)
  }

  @Test func cfiGateRejectsOversizedCFI() {
    let oversized = "epubcfi(/" + String(repeating: "1", count: ReadingPosition.maximumStringBytes) + ")"

    #expect(oversized.utf8.count > ReadingPosition.maximumStringBytes)
    #expect(validatedEPUBCFI(oversized) == nil)
  }

  @Test func cfiGateRejectsNonEPUBCFIStrings() {
    #expect(validatedEPUBCFI("css-selector(body > p:nth-child(1))") == nil)
    #expect(validatedEPUBCFI("locator(/6/4!/4/2/1:0)") == nil)
  }

  @Test func aPositionWithoutCFIIsValidAndHasNoEbookLocation() throws {
    let position = ReadingPosition(
      href: "Text/chapter.xhtml",
      progression: 0.2,
      totalProgression: 0.4
    )

    let data = try JSONEncoder().encode(position)
    let decoded = try JSONDecoder().decode(ReadingPosition.self, from: data)

    #expect(decoded == position)
    #expect(decoded.ebookLocation == nil)
  }
}
