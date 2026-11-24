import Persistence
import Synchronization
import TestSupport
import Testing

@testable import AppModel

/// `EpisodeTranscriptModel` against a fake source: the states, the growing text, following,
/// seeking and search.
@MainActor
@Suite struct EpisodeTranscriptModelTests {

  // MARK: - Fakes

  /// A coordinator stand-in the test drives: it pushes statuses and sets the stored words.
  final class FakeSource: Sendable {
    private struct State {
      var transcript: StoredTranscript?
      var transcriptError = false
      var loads = 0
      var requests = 0
      var cancels = 0
      var retries = 0
    }

    private let state = Mutex(State())
    let statuses: AsyncStream<EpisodeTranscriptStatus>
    private let continuation: AsyncStream<EpisodeTranscriptStatus>.Continuation

    init() {
      (statuses, continuation) = AsyncStream.makeStream()
    }

    func push(_ status: EpisodeTranscriptStatus) { continuation.yield(status) }
    func finish() { continuation.finish() }

    func setWords(_ words: [StoredTranscriptWord], duration: Double = 100) {
      state.withLock {
        $0.transcript = StoredTranscript(words: words, silences: [], duration: duration)
      }
    }

    func failLoads() { state.withLock { $0.transcriptError = true } }

    var loads: Int { state.withLock(\.loads) }
    var requests: Int { state.withLock(\.requests) }
    var cancels: Int { state.withLock(\.cancels) }
    var retries: Int { state.withLock(\.retries) }

    var source: EpisodeTranscriptModel.Source {
      EpisodeTranscriptModel.Source(
        statusChanges: { self.statuses },
        transcript: {
          try self.state.withLock {
            $0.loads += 1
            if $0.transcriptError { throw FakeError() }
            return $0.transcript
          }
        },
        request: { self.state.withLock { $0.requests += 1 } },
        cancel: { self.state.withLock { $0.cancels += 1 } },
        retry: { self.state.withLock { $0.retries += 1 } })
    }
  }

  struct FakeError: Error {}

  private struct Fixture {
    let source = FakeSource()
    let model: EpisodeTranscriptModel
    let seeks: SeekLog
    let task: Task<Void, Never>

    @MainActor init() {
      let seeks = SeekLog()
      self.seeks = seeks
      model = EpisodeTranscriptModel(source: source.source, seek: { seeks.times.append($0) })
      let model = model
      task = Task { await model.run() }
    }
  }

  @MainActor final class SeekLog {
    var times: [Double] = []
  }

  private func words(_ text: String, from start: Double = 0) -> [StoredTranscriptWord] {
    text.split(separator: " ").enumerated().map { offset, word in
      let wordStart = start + Double(offset)
      return StoredTranscriptWord(text: String(word), start: wordStart, end: wordStart + 0.5)
    }
  }

  private func eventually(
    _ label: String, sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
  ) async {
    let outcome = await awaitCondition(label, sourceLocation: sourceLocation) { condition() }
    #expect(outcome.isObserved, "\(outcome)", sourceLocation: sourceLocation)
  }

  // MARK: - States

  @Test func eachCoordinatorStatusMapsToAState() async {
    let cases: [(EpisodeTranscriptStatus, EpisodeTranscriptModel.State)] = [
      (.unavailable, .unavailable),
      (.notStarted, .offer(fraction: 0)),
      (.stopped(covered: 0.4), .offer(fraction: 0.4)),
      (.waiting(.deferred, covered: 0.1), .needsAsset(fraction: 0.1)),
      (.waiting(.queued, covered: 0.2), .held(.queued, fraction: 0.2)),
      (.waiting(.held, covered: 0.3), .held(.paused, fraction: 0.3)),
      (.generating(covered: 0.5), .generating(fraction: 0.5)),
      (.complete, .ready),
      (.failed, .failed),
    ]
    for (status, expected) in cases {
      let fixture = Fixture()
      fixture.source.push(status)
      await eventually("\(status) maps to \(expected)") { fixture.model.state == expected }
      fixture.task.cancel()
    }
  }

  @Test func beforeTheFirstStatusTheModelIsLoading() {
    let fixture = Fixture()
    defer { fixture.task.cancel() }

    #expect(fixture.model.state == .loading)
  }

  // MARK: - Text

  @Test func aStoppedTranscriptShowsTheWordsSoFar() async {
    let fixture = Fixture()
    defer { fixture.task.cancel() }
    fixture.source.setWords(words("One. Two."))
    fixture.source.push(.stopped(covered: 0.2))

    await eventually("the stored words load") { fixture.model.transcript.sentences.count == 2 }
  }

  @Test func theTextGrowsAsCoverageGrows() async {
    let fixture = Fixture()
    defer { fixture.task.cancel() }
    fixture.source.setWords(words("One."))
    fixture.source.push(.generating(covered: 0.1))
    await eventually("the first sentence") { fixture.model.transcript.sentences.count == 1 }

    fixture.source.setWords(words("One. Two. Three."))
    fixture.source.push(.generating(covered: 0.3))

    await eventually("all three sentences") { fixture.model.transcript.sentences.count == 3 }
  }

  @Test func aTranscriptThatWillNotLoadKeepsTheTextAlreadyShown() async {
    let fixture = Fixture()
    defer { fixture.task.cancel() }
    fixture.source.setWords(words("One. Two."))
    fixture.source.push(.generating(covered: 0.1))
    await eventually("the first load") { fixture.model.transcript.sentences.count == 2 }

    fixture.source.failLoads()
    fixture.source.push(.generating(covered: 0.2))
    await eventually("the second load is tried") { fixture.source.loads == 2 }

    #expect(fixture.model.transcript.sentences.count == 2)
  }

  @Test func anUnavailableEpisodeLoadsNothing() async {
    let fixture = Fixture()
    defer { fixture.task.cancel() }
    fixture.source.setWords(words("One."))
    fixture.source.push(.unavailable)
    await eventually("unavailable") { fixture.model.state == .unavailable }

    #expect(fixture.source.loads == 0)
    #expect(fixture.model.transcript.sentences.isEmpty)
  }

  // MARK: - Actions

  @Test func transcribeCancelAndRetryReachTheSource() async {
    let fixture = Fixture()
    defer { fixture.task.cancel() }

    fixture.model.transcribe()
    fixture.model.cancel()
    fixture.model.retryAsset()

    await eventually("all three reach the source") {
      fixture.source.requests == 1 && fixture.source.cancels == 1 && fixture.source.retries == 1
    }
  }

  // MARK: - Following

  @Test func followingTracksTheSentenceBeingSpoken() async {
    let fixture = Fixture()
    defer { fixture.task.cancel() }
    fixture.source.setWords(words("One two. Three four. Five"))
    fixture.source.push(.complete)
    await eventually("loaded") { fixture.model.transcript.sentences.count == 3 }

    fixture.model.playheadMoved(to: 2.5)
    #expect(fixture.model.currentSentenceIndex == 1)

    fixture.model.playheadMoved(to: 4)
    #expect(fixture.model.currentSentenceIndex == 2)
  }

  @Test func thePlayheadIsKeptUntilTheTextArrives() async {
    let fixture = Fixture()
    defer { fixture.task.cancel() }
    fixture.model.playheadMoved(to: 2.5)
    #expect(fixture.model.currentSentenceIndex == nil)

    fixture.source.setWords(words("One two. Three four."))
    fixture.source.push(.complete)

    await eventually("the sentence is found once loaded") {
      fixture.model.currentSentenceIndex == 1
    }
  }

  @Test func scrollingByHandStopsTheFollowAndNowResumesIt() {
    let fixture = Fixture()
    defer { fixture.task.cancel() }
    #expect(fixture.model.isFollowing)

    fixture.model.stopFollowing()
    #expect(fixture.model.isFollowing == false)

    fixture.model.resumeFollowing()
    #expect(fixture.model.isFollowing)
  }

  // MARK: - Seeking

  @Test func tappingASentenceSeeksToItsStartAndFollowsAgain() async {
    let fixture = Fixture()
    defer { fixture.task.cancel() }
    fixture.source.setWords(words("One two. Three four.", from: 10))
    fixture.source.push(.complete)
    await eventually("loaded") { fixture.model.transcript.sentences.count == 2 }
    fixture.model.stopFollowing()

    fixture.model.play(fromSentence: 1)

    #expect(fixture.seeks.times == [12])
    #expect(fixture.model.isFollowing)
  }

  @Test func aSentenceThatIsNotThereDoesNotSeek() {
    let fixture = Fixture()
    defer { fixture.task.cancel() }

    fixture.model.play(fromSentence: 3)

    #expect(fixture.seeks.times.isEmpty)
  }

  // MARK: - Search

  private func loadedForSearch() async -> Fixture {
    let fixture = Fixture()
    fixture.source.setWords(words("The cat sat. A dog ran. The CAT left. Caf\u{E9} time."))
    fixture.source.push(.complete)
    await eventually("loaded") { fixture.model.transcript.sentences.count == 4 }
    return fixture
  }

  @Test func searchMatchesSentencesIgnoringCaseAndAccents() async {
    let fixture = await loadedForSearch()
    defer { fixture.task.cancel() }

    fixture.model.searchQuery = "cat"
    #expect(fixture.model.matches == [0, 2])
    #expect(fixture.model.currentMatch == 0)

    fixture.model.searchQuery = "cafe"
    #expect(fixture.model.matches == [3])
  }

  @Test func aBlankQueryMatchesNothing() async {
    let fixture = await loadedForSearch()
    defer { fixture.task.cancel() }

    fixture.model.searchQuery = "  "

    #expect(fixture.model.matches.isEmpty)
    #expect(fixture.model.currentMatch == nil)
  }

  @Test func nextAndPreviousStepThroughMatchesAndWrap() async {
    let fixture = await loadedForSearch()
    defer { fixture.task.cancel() }
    fixture.model.searchQuery = "cat"

    fixture.model.nextMatch()
    #expect(fixture.model.currentMatch == 1)
    fixture.model.nextMatch()
    #expect(fixture.model.currentMatch == 0)
    fixture.model.previousMatch()
    #expect(fixture.model.currentMatch == 1)
  }

  @Test func searchingStopsTheFollow() async {
    let fixture = await loadedForSearch()
    defer { fixture.task.cancel() }

    fixture.model.searchQuery = "dog"

    #expect(fixture.model.isFollowing == false)
  }

  @Test func matchesFollowTheTextAsItGrows() async {
    let fixture = Fixture()
    defer { fixture.task.cancel() }
    fixture.source.setWords(words("A cat."))
    fixture.source.push(.generating(covered: 0.1))
    await eventually("loaded") { fixture.model.transcript.sentences.count == 1 }
    fixture.model.searchQuery = "cat"
    #expect(fixture.model.matches == [0])

    fixture.source.setWords(words("A cat. Another cat."))
    fixture.source.push(.generating(covered: 0.2))

    await eventually("the new sentence matches") { fixture.model.matches == [0, 1] }
    #expect(fixture.model.currentMatch == 0)
  }
}

// MARK: - Ad ranges

extension EpisodeTranscriptModelTests {

  /// A source that serves ranges the test sets and records undos.
  final class AdSource: Sendable {
    let ranges = Mutex<[TranscriptAdRange]>([])
    let undone = Mutex<[TranscriptAdRange]>([])
    let marked = Mutex<[[Double]]>([])
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() { (stream, continuation) = AsyncStream.makeStream() }

    func set(_ ranges: [TranscriptAdRange]) {
      self.ranges.withLock { $0 = ranges }
      continuation.yield()
    }

    func attach(to fake: FakeSource) -> EpisodeTranscriptModel.Source {
      var source = fake.source
      source.adRanges = { self.ranges.withLock { $0 } }
      source.adRangeChanges = { self.stream }
      source.undoAd = { range in
        self.undone.withLock { $0.append(range) }
        self.ranges.withLock { $0.removeAll { $0 == range } }
      }
      source.markAd = { start, end in
        self.marked.withLock { $0.append([start, end]) }
        self.set(self.ranges.withLock { $0 } + [TranscriptAdRange(start: start, end: end, origin: .listener)])
      }
      return source
    }
  }

  /// Sentences of two words, one per two seconds, in a single paragraph's worth of gap-free speech.
  private func sentences(_ count: Int) -> [StoredTranscriptWord] {
    (0..<count).flatMap { index -> [StoredTranscriptWord] in
      let start = Double(index) * 2
      return [
        StoredTranscriptWord(text: "Word\(index)", start: start, end: start + 0.5),
        StoredTranscriptWord(text: "end\(index).", start: start + 1, end: start + 1.5),
      ]
    }
  }

  @Test func theModelSplitsTheTranscriptAtAdRangesAndFollowsTheirChanges() async {
    let fake = FakeSource()
    let ads = AdSource()
    let ad = TranscriptAdRange(start: 6, end: 12, origin: .detected)
    ads.set([ad])
    fake.setWords(sentences(9))
    let model = EpisodeTranscriptModel(source: ads.attach(to: fake), seek: { _ in })
    let task = Task { await model.run() }
    defer { task.cancel() }
    fake.push(.complete)

    await eventually("the ad splits the paragraphs") {
      model.transcript.paragraphs.map(\.firstSentenceIndex) == [0, 3, 6]
    }
    #expect(model.adRanges == [ad])

    ads.set([])
    await eventually("the ad's block is gone") { model.transcript.paragraphs.count == 2 }
  }

  @Test func theCurrentSentenceSurvivesAReSplit() async {
    let fake = FakeSource()
    let ads = AdSource()
    fake.setWords(sentences(9))
    let model = EpisodeTranscriptModel(source: ads.attach(to: fake), seek: { _ in })
    let task = Task { await model.run() }
    defer { task.cancel() }
    fake.push(.complete)
    await eventually("the text loads") { model.transcript.sentences.count == 9 }
    model.playheadMoved(to: 8.5)
    #expect(model.currentSentenceIndex == 4)

    ads.set([TranscriptAdRange(start: 6, end: 12, origin: .hostRead)])
    await eventually("the ad arrives") { model.transcript.paragraphs.count == 3 }
    #expect(model.currentSentenceIndex == 4)
  }

  @Test func undoingAnAdRemovesItAtOnceAndAsksTheSource() async {
    let fake = FakeSource()
    let ads = AdSource()
    let ad = TranscriptAdRange(start: 6, end: 12, origin: .detected)
    ads.set([ad])
    fake.setWords(sentences(9))
    let model = EpisodeTranscriptModel(source: ads.attach(to: fake), seek: { _ in })
    let task = Task { await model.run() }
    defer { task.cancel() }
    fake.push(.complete)
    await eventually("the ad splits the paragraphs") { model.transcript.paragraphs.count == 3 }

    model.undoAd(ad)

    #expect(model.adRanges.isEmpty)
    #expect(model.transcript.paragraphs.count == 2)
    await eventually("the source is asked") { ads.undone.withLock { $0 } == [ad] }
  }

  @Test func aSourceWithNoAdsLeavesTheTranscriptAsItWas() async {
    let fake = FakeSource()
    fake.setWords(sentences(9))
    let model = EpisodeTranscriptModel(source: fake.source, seek: { _ in })
    let task = Task { await model.run() }
    defer { task.cancel() }
    fake.push(.complete)
    await eventually("the text loads") { model.transcript.sentences.count == 9 }
    #expect(model.adRanges.isEmpty)
    #expect(model.transcript.paragraphs.allSatisfy { $0.ad == nil })
  }

  @Test func markingAnAdAsksTheSourceAndShowsTheRangeItAnswersWith() async {
    let fake = FakeSource()
    let ads = AdSource()
    fake.setWords(sentences(9))
    let model = EpisodeTranscriptModel(source: ads.attach(to: fake), seek: { _ in })
    let task = Task { await model.run() }
    defer { task.cancel() }
    fake.push(.complete)
    await eventually("the text loads") { model.transcript.sentences.count == 9 }

    model.markAd(start: 6, end: 12)

    await eventually("the source is asked") { ads.marked.withLock { $0 } == [[6, 12]] }
    await eventually("the mark splits the paragraphs") {
      model.adRanges == [TranscriptAdRange(start: 6, end: 12, origin: .listener)]
        && model.transcript.paragraphs.count == 3
    }
  }

  @Test func aSourceThatCannotMarkIgnoresTheMark() async {
    let fake = FakeSource()
    fake.setWords(sentences(9))
    let model = EpisodeTranscriptModel(source: fake.source, seek: { _ in })
    let task = Task { await model.run() }
    defer { task.cancel() }
    fake.push(.complete)
    await eventually("the text loads") { model.transcript.sentences.count == 9 }
    model.markAd(start: 6, end: 12)
    #expect(model.adRanges.isEmpty)
  }
}

// MARK: - Marking

extension EpisodeTranscriptModelTests {

  private final class AvailabilityBox: Sendable {
    private let value = Mutex<TranscriptAdMarking.Availability>(.available)
    var current: TranscriptAdMarking.Availability {
      get { value.withLock { $0 } }
      set { value.withLock { $0 = newValue } }
    }
  }

  /// The spans `markTeaches` was asked about, and the answer it gives.
  private final class TeachingBox: Sendable {
    private let state = Mutex((asks: [[Double]](), teaches: true))
    var asks: [[Double]] { state.withLock { $0.asks } }
    var teaches: Bool {
      get { state.withLock { $0.teaches } }
      set { state.withLock { $0.teaches = newValue } }
    }
    func answer(_ start: Double, _ end: Double) -> Bool {
      state.withLock {
        $0.asks.append([start, end])
        return $0.teaches
      }
    }
  }

  private final class Marking: Sendable {
    let fake = FakeSource()
    let ads = AdSource()
    let availability = AvailabilityBox()
    let teaching = TeachingBox()
    let seeks = SeekLog()
    let model: EpisodeTranscriptModel
    let task: Task<Void, Never>

    @MainActor init(sentenceCount: Int = 9, perSentence: Double = 2) {
      fake.setWords(Self.words(sentenceCount, perSentence: perSentence))
      var source = ads.attach(to: fake)
      let availability = availability
      source.markingAvailability = { availability.current }
      let teaching = teaching
      source.markTeaches = { start, end in teaching.answer(start, end) }
      let seeks = seeks
      model = EpisodeTranscriptModel(source: source, seek: { seeks.times.append($0) })
      let model = model
      task = Task { await model.run() }
      fake.push(.complete)
    }

    /// Two-word sentences, each `perSentence` seconds apart, lasting 1.5 s.
    static func words(_ count: Int, perSentence: Double) -> [StoredTranscriptWord] {
      (0..<count).flatMap { index -> [StoredTranscriptWord] in
        let start = Double(index) * perSentence
        return [
          StoredTranscriptWord(text: "Word\(index)", start: start, end: start + 0.5),
          StoredTranscriptWord(text: "end\(index).", start: start + 1, end: start + 1.5),
        ]
      }
    }

    @MainActor func ready(_ count: Int = 9) async {
      let expected = availability.current
      _ = await awaitCondition("the text and availability load") {
        model.transcript.sentences.count == count && model.markingAvailability == expected
      }
    }
  }

  @Test func theModeStartsOnlyWhenMarkingIsAvailable() async {
    let marking = Marking()
    defer { marking.task.cancel() }
    await marking.ready()
    marking.model.beginMarking()
    #expect(marking.model.isMarking)
    marking.model.cancelMarking()
    #expect(marking.model.isMarking == false)

    let hidden = Marking()
    defer { hidden.task.cancel() }
    hidden.availability.current = .hidden
    await hidden.ready()
    hidden.model.beginMarking()
    #expect(hidden.model.isMarking == false)
  }

  @Test func enteringTheModeStopsFollowing() async {
    let marking = Marking()
    defer { marking.task.cancel() }
    await marking.ready()
    #expect(marking.model.isFollowing)
    marking.model.beginMarking()
    #expect(marking.model.isFollowing == false)
  }

  // The nine test sentences display as two paragraphs: 0...5 and 6...8.
  @Test func theFirstTapSelectsTheWholeDisplayedParagraph() async {
    let marking = Marking()
    defer { marking.task.cancel() }
    await marking.ready()
    let model = marking.model
    model.beginMarking()
    #expect(model.markingSelection == nil)
    #expect(model.markingSpan == nil)

    model.selectForMarking(sentence: 4)
    #expect(model.markingSelection == 0...5)
    #expect(model.markingSpan == 0...11.5)
    #expect(model.markingSeconds == 11.5)
  }

  @Test func laterTapsTrimTheEdgeParagraphsByTheSentence() async {
    let marking = Marking()
    defer { marking.task.cancel() }
    await marking.ready()
    let model = marking.model
    model.beginMarking()
    model.selectForMarking(sentence: 1)
    #expect(model.markingSelection == 0...5)
    model.selectForMarking(sentence: 7)
    #expect(model.markingSelection == 0...8, "another paragraph is added whole")
    model.selectForMarking(sentence: 7)
    #expect(model.markingSelection == 0...7, "the last paragraph trims to the sentence")
    model.selectForMarking(sentence: 2)
    #expect(model.markingSelection == 2...7, "the first paragraph trims to the sentence")
    model.selectForMarking(sentence: 0)
    #expect(model.markingSelection == 0...7, "a trimmed start moves back out")
  }

  @Test func aRowTapDoesNothingOutsideMarkingAndSelectsTheParagraphWhileMarking() async {
    let marking = Marking()
    defer { marking.task.cancel() }
    await marking.ready()
    let model = marking.model
    model.paragraphTapped(firstSentence: 6)
    #expect(model.markingSelection == nil)
    model.beginMarking()
    model.paragraphTapped(firstSentence: 6)
    #expect(model.markingSelection == 6...8)
    model.paragraphTapped(firstSentence: 0)
    #expect(model.markingSelection == 0...8)
  }

  @Test func theSelectionSurvivesTheParagraphsBeingSplit() async {
    let marking = Marking()
    defer { marking.task.cancel() }
    await marking.ready()
    let model = marking.model
    model.beginMarking()
    model.selectForMarking(sentence: 1)
    #expect(model.markingSelection == 0...5)

    // An ad over sentences 3...5 splits the first paragraph into 0...2 and 3...5.
    marking.ads.set([TranscriptAdRange(start: 6, end: 12, origin: .listener)])
    _ = await awaitCondition("the paragraphs are split") {
      model.transcript.paragraphs.count == 3
    }
    #expect(model.markingSelection == 0...5)

    model.selectForMarking(sentence: 4)
    #expect(model.markingSelection == 0...4, "the tap resolves the new last paragraph")
  }

  @Test func aMarkMustBeAtLeastTheMinimumToSave() async {
    let marking = Marking()
    defer { marking.task.cancel() }
    await marking.ready()
    let model = marking.model
    model.beginMarking()
    #expect(model.isMarkingLongEnoughToSave == false)
    model.setMarkingStart(sentence: 0)
    #expect(model.isMarkingLongEnoughToSave == false)
    // Sentences 0...2 run 0 to 5.5 s.
    model.setMarkingEnd(sentence: 1)
    #expect(model.markingSeconds == 3.5)
    #expect(model.isMarkingLongEnoughToSave == false)
    model.setMarkingEnd(sentence: 2)
    #expect(model.markingSeconds == 5.5)
    #expect(model.isMarkingLongEnoughToSave)
    model.confirmMarking()
    #expect(model.isMarking == false)
  }

  @Test func aShortMarkBesideAShownAdMayBeSavedAndOneAwayFromItMayNot() async {
    let marking = Marking()
    defer { marking.task.cancel() }
    await marking.ready()
    let model = marking.model
    marking.ads.set([TranscriptAdRange(start: 12, end: 30, origin: .detected)])
    _ = await awaitCondition(
      "the ad is shown", observing: { "\(model.adRanges.count) ad ranges" },
      until: { model.adRanges.count == 1 })
    model.beginMarking()
    model.setMarkingStart(sentence: 3)
    model.setMarkingEnd(sentence: 3)
    // Sentence 3 runs 6 to 7.5 s, under the minimum on its own.
    #expect(model.markingSpan == 6...7.5)
    #expect(model.isMarkingLongEnoughToSave, "within the join gap of the ad")

    marking.ads.set([TranscriptAdRange(start: 17, end: 30, origin: .detected)])
    _ = await awaitCondition("the ad has moved") { model.adRanges.first?.start == 17 }
    #expect(model.isMarkingLongEnoughToSave == false, "9.5 s from the ad")
  }

  @Test func theModelAsksWhetherTheSelectionTeachesAndKeepsOnlyTheCurrentAnswer() async {
    let marking = Marking()
    defer { marking.task.cancel() }
    await marking.ready()
    let model = marking.model
    marking.teaching.teaches = false
    model.beginMarking()
    #expect(model.markTeaches, "no selection, nothing to qualify")
    model.setMarkingStart(sentence: 3)
    model.setMarkingEnd(sentence: 4)
    _ = await awaitCondition("the source answers for 6 to 9.5 s") {
      model.markTeaches == false
    }
    #expect(marking.teaching.asks.last == [6, 9.5])

    marking.teaching.teaches = true
    model.setMarkingEnd(sentence: 6)
    _ = await awaitCondition("the source is asked about the new span") {
      marking.teaching.asks.last == [6, 13.5]
    }
    #expect(model.markTeaches)

    marking.teaching.teaches = false
    model.setMarkingEnd(sentence: 4)
    _ = await awaitCondition("false again") { model.markTeaches == false }
    model.cancelMarking()
    #expect(model.markTeaches, "leaving the mode clears the answer")
  }

  @Test func aMarkOverFiveMinutesNeedsConfirmation() async {
    let marking = Marking(sentenceCount: 200, perSentence: 2)
    defer { marking.task.cancel() }
    await marking.ready(200)
    let model = marking.model
    model.beginMarking()
    model.setMarkingStart(sentence: 0)
    // Sentence 150 ends at 301.5 s.
    model.setMarkingEnd(sentence: 150)
    #expect(model.markingSeconds == 301.5)
    #expect(model.needsLongMarkConfirmation)
    model.setMarkingEnd(sentence: 149)
    #expect(model.markingSeconds == 299.5)
    #expect(model.needsLongMarkConfirmation == false)
  }

  @Test func confirmingMarksExactlyTheSentenceEdgesAndLeavesTheMode() async {
    let marking = Marking()
    defer { marking.task.cancel() }
    await marking.ready()
    let model = marking.model
    model.beginMarking()
    model.setMarkingStart(sentence: 3)
    model.setMarkingEnd(sentence: 6)

    model.confirmMarking()

    #expect(model.isMarking == false)
    #expect(model.markingSelection == nil)
    _ = await awaitCondition("the source is asked for the sentence edges") {
      marking.ads.marked.withLock { $0 } == [[6, 13.5]]
    }
  }

  @Test func aTooShortSelectionIsNotSaved() async {
    let marking = Marking()
    defer { marking.task.cancel() }
    await marking.ready()
    let model = marking.model
    model.beginMarking()
    model.setMarkingStart(sentence: 3)
    model.setMarkingEnd(sentence: 3)
    #expect(model.markingSpan == 6...7.5)
    #expect(model.isMarkingLongEnoughToSave == false)
    model.confirmMarking()
    #expect(model.isMarking)
    #expect(marking.ads.marked.withLock { $0 }.isEmpty)
  }

  @Test func aSentenceTapNeverSeeksWhileMarkingAndSeeksOtherwise() async {
    let marking = Marking()
    defer { marking.task.cancel() }
    await marking.ready()
    let model = marking.model
    // One closure, made once, as the view holds it.
    let tap: (Int) -> Void = { model.sentenceTapped($0) }

    tap(2)
    #expect(marking.seeks.times == [4])

    model.beginMarking()
    tap(3)
    tap(5)
    #expect(marking.seeks.times == [4])
    #expect(model.markingSelection == 0...5)
    #expect(model.isFollowing == false)

    model.cancelMarking()
    tap(1)
    #expect(marking.seeks.times == [4, 2])
  }

  @Test func startAndEndSetTheEdgesDirectly() async {
    let marking = Marking()
    defer { marking.task.cancel() }
    await marking.ready()
    let model = marking.model
    model.beginMarking()
    model.setMarkingStart(sentence: 2)
    #expect(model.markingSelection == 2...2)
    model.setMarkingEnd(sentence: 5)
    #expect(model.markingSelection == 2...5)
    #expect(model.markingSpan == 4...11.5)
    model.setMarkingStart(sentence: 3)
    #expect(model.markingSelection == 3...5)
    model.setMarkingEnd(sentence: 8)
    #expect(model.markingSelection == 3...8)
    // A start after the end begins again; an end before the start does too.
    model.setMarkingStart(sentence: 8)
    #expect(model.markingSelection == 8...8)
    model.setMarkingStart(sentence: 8)
    model.setMarkingEnd(sentence: 4)
    #expect(model.markingSelection == 4...4)
  }

  @Test func theSelectionIsClearedWhenTheModeEnds() async {
    let marking = Marking()
    defer { marking.task.cancel() }
    await marking.ready()
    let model = marking.model
    model.beginMarking()
    model.selectForMarking(sentence: 1)
    model.cancelMarking()
    #expect(model.markingSelection == nil)
    model.selectForMarking(sentence: 4)
    #expect(model.markingSelection == nil, "selecting outside the mode does nothing")
  }

  @Test func availabilityFollowsTheSourceOnEveryRangeSignal() async {
    let marking = Marking()
    defer { marking.task.cancel() }
    await marking.ready()
    #expect(marking.model.markingAvailability == .available)

    marking.availability.current = .unavailable(.notAnalysed)
    marking.ads.set([])
    _ = await awaitCondition("it becomes unavailable") {
      marking.model.markingAvailability == .unavailable(.notAnalysed)
    }
  }

  @Test func theModeEndsWhenMarkingStopsBeingAvailable() async {
    let marking = Marking()
    defer { marking.task.cancel() }
    await marking.ready()
    marking.model.beginMarking()
    marking.availability.current = .hidden
    marking.ads.set([])
    _ = await awaitCondition("the mode ends") { marking.model.isMarking == false }
  }

  @Test func aSourceWithNoCoordinatorHidesMarking() async {
    let fake = FakeSource()
    let model = EpisodeTranscriptModel(source: fake.source, seek: { _ in })
    let task = Task { await model.run() }
    defer { task.cancel() }
    fake.push(.complete)
    _ = await awaitCondition("the text is ready") { model.state == .ready }
    #expect(model.markingAvailability == .hidden)
  }
}

/// The tap rules on their own, over paragraphs of four sentences: 0...3, 4...7, 8...11, 12...15.
@Suite struct TranscriptAdMarkingSelectionTests {
  private static func paragraph(_ sentence: Int) -> ClosedRange<Int> {
    let first = sentence / 4 * 4
    return first...(first + 3)
  }

  private func selection(_ range: ClosedRange<Int>) -> TranscriptAdMarking.Selection {
    var selection = TranscriptAdMarking.Selection()
    selection.setStart(range.lowerBound)
    selection.setEnd(range.upperBound)
    return selection
  }

  private func tapped(
    _ range: ClosedRange<Int>?, _ sentence: Int
  ) -> ClosedRange<Int>? {
    var selection = range.map(selection) ?? TranscriptAdMarking.Selection()
    selection.tap(sentence: sentence, paragraph: Self.paragraph)
    return selection.range
  }

  /// Paragraphs of uneven length: 0...5, 6...6, 7...12.
  private static func uneven(_ sentence: Int) -> ClosedRange<Int> {
    switch sentence {
    case ...5: 0...5
    case 6: 6...6
    default: 7...12
    }
  }

  private func rowTapped(_ range: ClosedRange<Int>?, _ sentence: Int) -> ClosedRange<Int>? {
    var selection = range.map(selection) ?? TranscriptAdMarking.Selection()
    selection.tap(paragraph: Self.uneven(sentence), paragraphOf: Self.uneven)
    return selection.range
  }

  @Test func aRowTapWithNoSelectionSelectsTheParagraph() {
    #expect(rowTapped(nil, 6) == 6...6)
  }

  @Test func aRowTapOnAWhollyOutsideParagraphGrowsTheSelection() {
    #expect(rowTapped(0...5, 6) == 0...6)
    #expect(rowTapped(7...12, 6) == 6...12)
  }

  @Test func aRowTapOnAnEdgeParagraphRestoresThatEndWhole() {
    #expect(rowTapped(0...7, 7) == 0...12)
    #expect(rowTapped(2...12, 0) == 0...12, "the first paragraph holds the start")
    #expect(rowTapped(2...9, 3) == 0...9)
    #expect(rowTapped(2...5, 1) == 0...5, "a single-paragraph selection becomes the whole paragraph")
  }

  @Test func aRowTapOnAnInteriorParagraphMovesTheNearerEnd() {
    #expect(rowTapped(0...7, 6) == 0...6)
    #expect(rowTapped(5...12, 6) == 6...12)
    #expect(rowTapped(0...12, 6) == 0...6, "a tie moves the end")
  }

  @Test func withNoSelectionTheTappedParagraphIsSelected() {
    #expect(tapped(nil, 5) == 4...7)
  }

  @Test func aParagraphWhollyBeforeOrAfterIsAddedWhole() {
    #expect(tapped(5...10, 1) == 0...10)
    #expect(tapped(5...10, 14) == 5...15)
  }

  @Test func theFirstParagraphOfAMultiParagraphSelectionMovesItsStartToTheSentence() {
    #expect(tapped(5...10, 6) == 6...10)
    #expect(tapped(5...10, 4) == 4...10, "a trimmed start moves back out")
  }

  @Test func theLastParagraphOfAMultiParagraphSelectionMovesItsEndToTheSentence() {
    #expect(tapped(5...10, 9) == 5...9)
    #expect(tapped(5...10, 11) == 5...11)
  }

  @Test func withinOneParagraphTheNearerEndMoves() {
    #expect(tapped(5...6, 4) == 4...6)
    #expect(tapped(5...6, 7) == 5...7)
    #expect(tapped(4...7, 5) == 5...7)
    #expect(tapped(4...7, 6) == 4...6)
    #expect(tapped(4...6, 5) == 4...5, "a tie moves the end")
  }

  @Test func anInteriorParagraphBecomesTheWholeEdgeParagraphOfTheNearerEnd() {
    // Selection 3...16 spans 0...3 to 16...19 over interior 4...7, 8...11 and 12...15.
    #expect(tapped(3...16, 5) == 4...16, "nearer the start")
    #expect(tapped(3...16, 14) == 3...15, "nearer the end")
    #expect(tapped(3...16, 9) == 3...11, "a tie moves the end")
  }

  @Test func startAndEndSetTheEdgesAndRestartWhenCrossed() {
    var selection = TranscriptAdMarking.Selection()
    selection.setEnd(6)
    #expect(selection.range == 6...6)
    selection.setStart(2)
    #expect(selection.range == 2...6)
    selection.setStart(9)
    #expect(selection.range == 9...9)
    selection.setEnd(4)
    #expect(selection.range == 4...4)
  }
}
