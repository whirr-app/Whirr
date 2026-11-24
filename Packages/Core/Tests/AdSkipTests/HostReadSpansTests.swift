import Foundation
import Testing

@testable import AdSkip

/// The frozen host-read rule (the research harness's `hostread.py --anchors`, cut-off 0.9, look-back 90 s, URLs
/// only) on synthetic transcripts. Words are two a second, so a sentence runs on until a full stop.
@Suite struct HostReadSpansTests {
  /// `text` at two words a second from `start`.
  private static func spoken(_ text: String, from start: Double) -> [TranscriptWord] {
    text.split(separator: " ").enumerated().map { i, word in
      TranscriptWord(text: String(word), start: start + Double(i) * 0.5, end: start + Double(i) * 0.5 + 0.4)
    }
  }

  /// Programme either side of whatever a test adds: one-word sentences every 2 s, with a hole
  /// from `from` to `to`.
  private static func programme(until end: Double, except from: Double, _ to: Double) -> [TranscriptWord] {
    stride(from: 0.0, to: end, by: 2).filter { $0 < from || $0 >= to }.map {
      TranscriptWord(text: "Talk.", start: $0, end: $0 + 0.4)
    }
  }

  /// Candidates for `spots` laid into 600 s of programme, with P(ad) `high` on every step
  /// starting in one of `sure` and 0.01 elsewhere.
  private static func candidates(
    _ spots: [[TranscriptWord]], sure: [ClosedRange<Double>], high: Double = 0.95,
    silences: [Silence] = [], showTitle: String? = nil, hole: (Double, Double) = (190, 400)
  ) -> [CandidateRange] {
    let words = (programme(until: 600, except: hole.0, hole.1) + spots.flatMap { $0 }).sorted {
      $0.start < $1.start
    }
    let prepared = Fixture.prepared(words, silences: silences, duration: 600)
    let steps = Arbiter.steps(for: prepared.transcript)
    let probabilities = steps.map { step in sure.contains { $0.contains(step.start) } ? high : 0.01 }
    return HostReadSpans.candidates(
      in: prepared, steps: steps, probabilities: probabilities, showTitle: showTitle)
  }

  /// A read opening at 300 s, naming the sponsor in its first sentence, with its address in the
  /// step from 340 s. "show." ends at 342.9 s.
  private static let read = spoken("Now a thing I use. Fuse Energy keeps my lights on.", from: 300)
  private static let callToAction = spoken("Go to fuseenergy.com slash show.", from: 340.5)

  @Test func aReadRunsFromTheSentenceNamingTheSponsorToTheCallToActionsLastWord() {
    // "Fuse" is the sixth word, at 302.5 s, heading its sentence.
    #expect(
      Self.candidates([Self.read, Self.callToAction], sure: [340...344])
        == [CandidateRange(start: 302.5, end: 342.9)])
  }

  @Test func aSureStretchWithNoAddressGivesNoSpan() {
    let noAddress = Self.spoken("Go and tell them the show sent you.", from: 340.5)
    #expect(Self.candidates([Self.read, noAddress], sure: [300...344]).isEmpty)
  }

  @Test func anAddressTheClassifierIsNotSureOfGivesNoSpan() {
    #expect(Self.candidates([Self.read, Self.callToAction], sure: [340...344], high: 0.89).isEmpty)
    #expect(Self.candidates([Self.read, Self.callToAction], sure: [340...344], high: 0.9).count == 1)
  }

  @Test func anAddressInASureStepsContextButNotItsOwnWordsGivesNoSpan() {
    // The step from 345 s reads the address in its context, as the classifier does.
    #expect(Self.candidates([Self.read, Self.callToAction], sure: [345...349]).isEmpty)
  }

  @Test func aSponsorNamedMoreThanNinetySecondsBackDoesNotStartTheSpan() {
    // Named at 250.4 s and at 250.6 s: the run opens at 340 s, so only the second is in reach.
    for (start, expected) in [(250.4, 250.4), (249.9, 340.5)] {
      let early = Self.spoken("Fuse Energy keeps my lights on.", from: start)
      #expect(
        Self.candidates([early, Self.callToAction], sure: [340...344])
          == [CandidateRange(start: expected, end: 342.9)])
    }
  }

  @Test func aSponsorFirstNamedInsideTheRunStartsAtThatSentence() {
    let run = Self.spoken("That was fun. Fuse Energy is at fuseenergy.com now.", from: 340.5)
    // "Fuse" at 342 s, the address at 344 s, "now." ending at 344.9 s: all in the step from 340 s.
    #expect(
      Self.candidates([run], sure: [340...349]) == [CandidateRange(start: 342, end: 344.9)])
  }

  @Test(arguments: [
    "fuseenergy.com", "Fuseenergy.com/show.", "fuseenergy dot com", "fuseenergy .com", "fuse.ai",
    "fuse.me", "fuse.ca", "fuse.co.uk", "www.fuseenergy.com",
  ])
  func anAddressAnchorsInEachWrittenForm(address: String) {
    let action = Self.spoken("Go to \(address) today", from: 340.5)
    #expect(Self.candidates([Self.read, action], sure: [340...344]).map(\.start) == [302.5])
  }

  @Test(arguments: ["fuse energy com", "fuseenergy", "fuseenergy.company", "go.com"])
  func whatIsNotAnAddressDoesNotAnchor(words: String) {
    #expect(Self.candidates([Self.read, Self.spoken("See \(words) today", from: 340.5)], sure: [340...344]).isEmpty)
  }

  @Test func theStemIsTheLastAddressOfTheRun() {
    #expect(HostReadSpans.addressStems(in: "Go to Acme.com or FuseEnergy.com") == ["acme", "fuseenergy"])
    let action = Self.spoken("Not acme.com but fuseenergy.com", from: 340.5)
    #expect(Self.candidates([Self.read, action], sure: [340...344]).map(\.start) == [302.5])
  }

  @Test func aSponsorPhraseStartsTheSpanWhenTheNameIsSpeltDifferently() {
    let opening = Self.spoken("This episode is brought to you by E Toro.", from: 300)
    let action = Self.spoken("Go to etoro.com", from: 340.5)
    #expect(
      Self.candidates([opening, action], sure: [340...344])
        == [CandidateRange(start: 300, end: 341.9)])
  }

  @Test func theEarlierOfTheNameAndThePhraseWins() {
    let opening = Self.spoken("This episode is brought to you by a sponsor.", from: 280)
    #expect(
      Self.candidates([opening, Self.read, Self.callToAction], sure: [340...344]).map(\.start) == [280])
  }

  @Test func theShowsNameMayOpenThePhrase() {
    let opening = Self.spoken("Money Talk is sponsored by E Toro.", from: 300)
    let action = Self.spoken("Go to etoro.com", from: 340.5)
    #expect(Self.candidates([opening, action], sure: [340...344], showTitle: "Money Talk").map(\.start) == [300])
    #expect(Self.candidates([opening, action], sure: [340...344]).map(\.start) == [340.5])
  }

  @Test func theEdgesMoveToThePausesAroundTheRead() {
    // A silence ending just before the read's first sentence is too far from the named one.
    let silences = [Silence(start: 298, end: 302.3), Silence(start: 345, end: 347)]
    #expect(
      Self.candidates([Array(Self.read.dropFirst(5)), Self.callToAction], sure: [340...344], silences: silences)
        == [CandidateRange(start: 302.3, end: 345)])
    // A pause more than 5 s after the last word leaves the end alone.
    #expect(
      Self.candidates(
        [Self.read, Self.callToAction], sure: [340...344], silences: [Silence(start: 348, end: 350)]
      ) == [CandidateRange(start: 302.5, end: 342.9)])
  }

  @Test func anchorStepsWithinTenSecondsAreOneRun() {
    let again = Self.spoken("That is fuseenergy.com", from: 355)
    // The step from 340 s ends 10 s before the one from 355 s starts, and 15 s before the one
    // from 360 s.
    #expect(
      Self.candidates([Self.read, Self.callToAction, again], sure: [340...359])
        == [CandidateRange(start: 302.5, end: 356.4)])
    let split = TranscriptWord(text: "acme.com", start: 361, end: 361.4)
    #expect(
      Self.candidates([Self.read, Self.callToAction, [split]], sure: [340...364], hole: (190, 366))
        == [CandidateRange(start: 302.5, end: 342.9), CandidateRange(start: 361, end: 361.4)])
  }

  private static func kept(_ start: Double, _ end: Double, p: Double = 0.5, endsItem: Bool = false) -> KeptRange {
    KeptRange(start: start, end: end, meanAdProbability: p, endsItem: endsItem)
  }

  @Test func aSpanClearOfEveryShippedRangeIsServedWhole() {
    let shipped = [TimeSpan(start: 10, end: 40), TimeSpan(start: 400, end: 430)]
    #expect(HostReadSpans.layingOver([Self.kept(100, 160)], shipped: shipped) == [Self.kept(100, 160)])
    #expect(HostReadSpans.layingOver([Self.kept(100, 160)], shipped: []) == [Self.kept(100, 160)])
  }

  @Test func aSpanLosesWhatAShippedRangeCovers() {
    // Overlapped at its start, at its end, and in the middle.
    #expect(
      HostReadSpans.layingOver([Self.kept(100, 160)], shipped: [TimeSpan(start: 90, end: 120)])
        == [Self.kept(120, 160)])
    #expect(
      HostReadSpans.layingOver(
        [Self.kept(100, 160, endsItem: true)], shipped: [TimeSpan(start: 150, end: 170)])
        == [Self.kept(100, 150)])
    #expect(
      HostReadSpans.layingOver(
        [Self.kept(100, 160, endsItem: true)], shipped: [TimeSpan(start: 120, end: 130)])
        == [Self.kept(100, 120), Self.kept(130, 160, endsItem: true)])
  }

  @Test func aPieceUnderFiveSecondsIsDropped() {
    #expect(HostReadSpans.layingOver([Self.kept(100, 160)], shipped: [TimeSpan(start: 90, end: 170)]).isEmpty)
    #expect(
      HostReadSpans.layingOver(
        [Self.kept(100, 160)], shipped: [TimeSpan(start: 104.9, end: 150), TimeSpan(start: 155, end: 200)])
        == [Self.kept(150, 155)])
  }

  @Test func overlappingSpansAreServedAsOne() {
    #expect(
      HostReadSpans.layingOver(
        [Self.kept(100, 160, p: 0.7), Self.kept(130, 190, p: 0.4, endsItem: true), Self.kept(300, 320)],
        shipped: [])
        == [Self.kept(100, 190, p: 0.4, endsItem: true), Self.kept(300, 320)])
  }

  @Test func theSentenceHeadStopsAtAFullStopOrAPause() {
    let words = [
      TranscriptWord(text: "One.", start: 0, end: 0.4), TranscriptWord(text: "two", start: 0.5, end: 0.9),
      TranscriptWord(text: "three", start: 1, end: 1.4), TranscriptWord(text: "four", start: 2.4, end: 2.8),
      TranscriptWord(text: "five", start: 2.9, end: 3.3),
    ]
    #expect(HostReadSpans.sentenceHead(of: 2, in: words) == 1)
    #expect(HostReadSpans.sentenceHead(of: 4, in: words) == 3)
    #expect(HostReadSpans.sentenceHead(of: 0, in: words) == 0)
  }
}
