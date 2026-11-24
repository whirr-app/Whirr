import Persistence
import TestSupport
import Testing

@testable import AppModel

/// Stepping the transcript between ad breaks: where a step starts, what it scrolls to, and how the
/// break in view survives the ranges changing under it.
@MainActor
@Suite struct EpisodeTranscriptAdBreakTests {
  private typealias FakeSource = EpisodeTranscriptModelTests.FakeSource
  private typealias AdSource = EpisodeTranscriptModelTests.AdSource

  private struct Fixture {
    let fake = FakeSource()
    let ads = AdSource()
    let model: EpisodeTranscriptModel
    let task: Task<Void, Never>

    /// `count` two-word sentences, one every two seconds, so sentence `n` starts at `2n`.
    @MainActor init(sentences count: Int, ads ranges: [TranscriptAdRange]) {
      ads.set(ranges)
      fake.setWords(
        (0..<count).flatMap { index -> [StoredTranscriptWord] in
          let start = Double(index) * 2
          return [
            StoredTranscriptWord(text: "Word\(index)", start: start, end: start + 0.5),
            StoredTranscriptWord(text: "end\(index).", start: start + 1, end: start + 1.5),
          ]
        })
      model = EpisodeTranscriptModel(source: ads.attach(to: fake), seek: { _ in })
      let model = model
      task = Task { await model.run() }
      fake.push(.complete)
    }
  }

  private func eventually(
    _ label: String, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
  ) async {
    let outcome = await awaitCondition(label, sourceLocation: sourceLocation) { condition() }
    #expect(outcome.isObserved, "\(outcome)", sourceLocation: sourceLocation)
  }

  /// Two breaks in 200 seconds of text: a detected ad with a listener's mark beside it, then one
  /// more detected ad well after.
  private let twoBreaks = [
    TranscriptAdRange(start: 20, end: 30, origin: .detected),
    TranscriptAdRange(start: 34, end: 40, origin: .listener),
    TranscriptAdRange(start: 150, end: 160, origin: .detected),
  ]

  @Test func breaksFollowTheRanges() async {
    let fixture = Fixture(sentences: 100, ads: twoBreaks)
    defer { fixture.task.cancel() }
    await eventually("both breaks arrive") { fixture.model.adBreaks.count == 2 }
    #expect(fixture.model.adBreaks.first == TranscriptAdBreak(start: 20, end: 40))
    #expect(fixture.model.currentAdBreak == nil)

    fixture.ads.set([])
    await eventually("the breaks go with their ads") { fixture.model.adBreaks.isEmpty }
  }

  @Test func theFirstStepGoesFromThePlayheadAndLaterOnesFromTheBreakInView() async {
    let fixture = Fixture(sentences: 100, ads: twoBreaks)
    defer { fixture.task.cancel() }
    let model = fixture.model
    await eventually("both breaks arrive") { model.adBreaks.count == 2 }
    model.playheadMoved(to: 100)

    model.nextAdBreak()
    #expect(model.currentAdBreak == 1)
    // Stepping is reading: following stops, as it does for a hand scroll.
    #expect(model.isFollowing == false)
    model.previousAdBreak()
    #expect(model.currentAdBreak == 0)
    // Round from the first to the last, as search's matches do.
    model.previousAdBreak()
    #expect(model.currentAdBreak == 1)
    model.nextAdBreak()
    #expect(model.currentAdBreak == 0)
  }

  @Test func aStepBackFromThePlayheadLandsOnTheBreakBeforeIt() async {
    let fixture = Fixture(sentences: 100, ads: twoBreaks)
    defer { fixture.task.cancel() }
    let model = fixture.model
    await eventually("both breaks arrive") { model.adBreaks.count == 2 }
    model.playheadMoved(to: 100)
    model.previousAdBreak()
    #expect(model.currentAdBreak == 0)
  }

  @Test func eachStepScrollsToTheParagraphBeforeTheBreakEvenOnTheSameBreak() async throws {
    let fixture = Fixture(sentences: 100, ads: [TranscriptAdRange(start: 150, end: 160, origin: .detected)])
    defer { fixture.task.cancel() }
    let model = fixture.model
    await eventually("the break arrives") { model.adBreaks.count == 1 }

    model.nextAdBreak()
    let first = try #require(model.adBreakJump)
    let paragraphs = model.transcript.paragraphs
    let adParagraph = try #require(paragraphs.firstIndex { $0.ad != nil })
    // A paragraph of what came before, so a missed ad leading into the break is on screen too.
    #expect(first.paragraphID == paragraphs[adParagraph - 1].id)

    // One break: the next step is the same break, and still scrolls back to it.
    model.nextAdBreak()
    #expect(model.adBreakJump?.paragraphID == first.paragraphID)
    #expect(model.adBreakJump != first)
  }

  @Test func theBreakInViewHoldsWhenAMarkWidensIt() async {
    let fixture = Fixture(sentences: 100, ads: twoBreaks)
    defer { fixture.task.cancel() }
    let model = fixture.model
    await eventually("both breaks arrive") { model.adBreaks.count == 2 }
    model.playheadMoved(to: 100)
    model.nextAdBreak()
    #expect(model.currentAdBreak == 1)

    // The listener marks the ad that detection missed just before the second break.
    model.markAd(start: 130, end: 148)
    await eventually("the mark joins the break") { model.adBreaks.last?.start == 130 }
    #expect(model.currentAdBreak == 1)
  }

  @Test func breaksBeyondTheTranscribedTextAreNotOffered() async {
    // 40 seconds of text so far: the ad at 150 has nothing to show yet.
    let fixture = Fixture(sentences: 20, ads: twoBreaks)
    defer { fixture.task.cancel() }
    await eventually("the text loads") { fixture.model.transcript.sentences.count == 20 }
    await eventually("one break is offered") { fixture.model.adBreaks.count == 1 }
  }
}
