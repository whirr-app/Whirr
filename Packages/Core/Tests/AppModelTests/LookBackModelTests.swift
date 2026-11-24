import AdSkip
import Foundation
import Synchronization
import TestSupport
import Testing

@testable import AppModel

/// `LookBackModel`: the newest minutes on open, reaching further back from the top, following
/// playback after a tap, and the states around the recogniser.
@MainActor
@Suite struct LookBackModelTests {
  /// Answers every window with one sentence at its start, recording the windows asked for.
  final class Transcriber: EpisodeTranscribing {
    private let calls = Mutex<[TimeSpan]>([])
    private let failure = Mutex<(any Error)?>(nil)

    var windows: [TimeSpan] { calls.withLock { $0 } }
    func fail(with error: any Error) { failure.withLock { $0 = error } }
    func succeed() { failure.withLock { $0 = nil } }

    func transcript(ofFileAt url: URL, windows: [TimeSpan]) async throws -> Transcript {
      let window = try #require(windows.first)
      calls.withLock { $0.append(window) }
      if let error = failure.withLock({ $0 }) { throw error }
      let at = window.start
      return Transcript(words: [TranscriptWord(text: "At \(Int(at)).", start: at, end: at + 1)], duration: 100_000)
    }
  }

  private final class Played {
    var offsets: [Double] = []
  }

  private let url = URL(fileURLWithPath: "/book/a.mp3")

  private func source(duration: Double = 10_000) -> LookBackSource {
    LookBackSource(
      itemID: "book",
      tracks: [LookBackTrack(fileURL: url, startOffset: 0, duration: duration)],
      chapters: [.init(start: 0, title: "One"), .init(start: 3_500, title: "Two")])
  }

  private func model(
    source: LookBackSource?, playhead: Double = 4_000, transcriber: Transcriber,
    played: Played = Played(),
    asset: @escaping @Sendable () -> LookBackModel.AssetState = { .installed },
    install: @escaping @Sendable () async throws -> Void = {}
  ) -> LookBackModel {
    LookBackModel(
      source: source, playhead: playhead,
      dependencies: .init(
        coordinator: LookBackCoordinator(
          dependencies: .init(gate: TranscriberGate(), transcriber: transcriber)),
        assetState: { asset() }, installAsset: install),
      play: { played.offsets.append($0) })
  }

  private func awaitState(
    _ expected: LookBackModel.State, of lookBack: LookBackModel,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    _ = await awaitCondition(
      "Look Back to reach \(expected)", sourceLocation: sourceLocation,
      observing: { "state \(lookBack.state), reach \(lookBack.reach)" },
      until: { lookBack.state == expected })
  }

  /// Opens and waits for the first five minutes.
  private func opened(_ lookBack: LookBackModel) async {
    await lookBack.appear()
    await awaitState(.ready, of: lookBack)
  }

  /// Reaches the top once and waits for the chunk.
  private func loadEarlier(_ lookBack: LookBackModel) async {
    lookBack.loadEarlier()
    await awaitState(.ready, of: lookBack)
  }

  @Test func opensTranscribingTheNewestFiveMinutesNewestFirst() async {
    let transcriber = Transcriber()
    let lookBack = model(source: source(), transcriber: transcriber)
    await opened(lookBack)

    #expect(transcriber.windows == [TimeSpan(start: 3_850, end: 4_000), TimeSpan(start: 3_700, end: 3_850)])
    #expect(lookBack.paragraphs.sentences.map(\.text) == ["At 3700.", "At 3850."])
    #expect(lookBack.newestSentenceIndex == 1)
    #expect(lookBack.highlightedSentenceIndex == 1)
    #expect(lookBack.reach == 300)
    #expect(lookBack.canLoadEarlier)
  }

  @Test func reachingTheTopAddsOneOlderChunkAtATime() async {
    let transcriber = Transcriber()
    let lookBack = model(source: source(), transcriber: transcriber)
    await opened(lookBack)

    lookBack.loadEarlier()
    // Still running: a second reach is ignored.
    lookBack.loadEarlier()
    await awaitState(.ready, of: lookBack)
    #expect(transcriber.windows.dropFirst(2) == [TimeSpan(start: 3_550, end: 3_700)])
    #expect(lookBack.paragraphs.sentences.first?.text == "At 3550.")
    #expect(lookBack.reach == 450)
  }

  @Test func reachesThirtyMinutesAndNoFurther() async {
    let transcriber = Transcriber()
    let lookBack = model(source: source(), transcriber: transcriber)
    await opened(lookBack)
    while lookBack.canLoadEarlier { await loadEarlier(lookBack) }

    #expect(transcriber.windows.count == 12)
    #expect(transcriber.windows.last == TimeSpan(start: 2_200, end: 2_350))
    #expect(lookBack.reachesLimit)
    #expect(lookBack.reachesStartOfBook == false)
    lookBack.loadEarlier()
    #expect(lookBack.state == .ready)
    #expect(transcriber.windows.count == 12)
  }

  @Test func chaptersInsideTheTextHeadTheirParagraphs() async {
    let lookBack = model(source: source(), transcriber: Transcriber())
    await opened(lookBack)
    #expect(lookBack.chapterHeadings[0] == "Two")
    await loadEarlier(lookBack)
    await loadEarlier(lookBack)
    #expect(lookBack.chapterHeadings[0] == "One")
    #expect(lookBack.chapterHeadings.values.contains("Two"))
  }

  @Test func aPlayheadNearTheStartReachesTheBeginningOfTheBook() async {
    let transcriber = Transcriber()
    let lookBack = model(source: source(), playhead: 200, transcriber: transcriber)
    await opened(lookBack)
    #expect(transcriber.windows == [TimeSpan(start: 50, end: 200), TimeSpan(start: 0, end: 50)])
    #expect(lookBack.reachesStartOfBook)
    #expect(lookBack.canLoadEarlier == false)
  }

  @Test func tappingASentencePlaysFromItsStartAndFollowsIt() async {
    let played = Played()
    let lookBack = model(source: source(), transcriber: Transcriber(), played: played)
    await opened(lookBack)
    lookBack.stopFollowing()
    lookBack.playSentence(at: 0)
    #expect(played.offsets == [3_700])
    #expect(lookBack.playingFrom == 3_700)
    #expect(lookBack.isFollowing)
  }

  @Test func scrollingStopsFollowingAndNowResumesIt() async {
    let lookBack = model(source: source(), transcriber: Transcriber())
    await opened(lookBack)
    #expect(lookBack.isFollowing)
    lookBack.stopFollowing()
    #expect(lookBack.isFollowing == false)
    lookBack.resumeFollowing()
    #expect(lookBack.isFollowing)
  }

  @Test func theNewestSentenceIsHighlightedUntilATapThenTheOnePlaying() async {
    let lookBack = model(source: source(), transcriber: Transcriber())
    await opened(lookBack)
    await loadEarlier(lookBack)
    await loadEarlier(lookBack)
    #expect(lookBack.highlightedSentenceIndex == 3)
    #expect(lookBack.playingFrom == nil)

    // Paused at the playhead: the position is not followed before a tap.
    lookBack.playbackMoved(to: 3_420)
    #expect(lookBack.highlightedSentenceIndex == 3)

    lookBack.playSentence(at: 1)
    #expect(lookBack.highlightedSentenceIndex == 1)
    lookBack.playbackMoved(to: 3_560)
    #expect(lookBack.highlightedSentenceIndex == 1)
    lookBack.playbackMoved(to: 3_701)
    #expect(lookBack.highlightedSentenceIndex == 2)

    // Past the last sentence there is nothing to highlight.
    lookBack.playbackMoved(to: 3_900)
    #expect(lookBack.highlightedSentenceIndex == nil)
  }

  @Test func theHighlightFollowsTheTimeWhenOlderTextArrivesAbove() async {
    let lookBack = model(source: source(), transcriber: Transcriber())
    await opened(lookBack)
    lookBack.playSentence(at: 0)
    #expect(lookBack.highlightedSentenceIndex == 0)

    await loadEarlier(lookBack)
    #expect(lookBack.paragraphs.sentences.count == 3)
    #expect(lookBack.highlightedSentenceIndex == 1)
  }

  /// Older text landing above moves the newest sentence's index but not the sentence: the sheet
  /// scrolls on this identity, so the text it opened on stays put while earlier text fills in.
  @Test func theHighlightedSentenceKeepsItsIdentityWhenOlderTextArrivesAbove() async {
    let lookBack = model(source: source(), transcriber: Transcriber())
    await opened(lookBack)
    #expect(lookBack.highlightedSentenceStart == 3_850)

    await loadEarlier(lookBack)
    await loadEarlier(lookBack)
    #expect(lookBack.highlightedSentenceIndex == 3)
    #expect(lookBack.highlightedSentenceStart == 3_850)

    lookBack.playSentence(at: 1)
    #expect(lookBack.highlightedSentenceStart == 3_550)
    lookBack.playbackMoved(to: 3_900)
    #expect(lookBack.highlightedSentenceStart == nil)
  }

  @Test func aStreamedBookIsNotOffered() async {
    let transcriber = Transcriber()
    let lookBack = model(source: nil, transcriber: transcriber)
    await lookBack.appear()
    #expect(lookBack.state == .unavailable(.notDownloaded))
    lookBack.loadEarlier()
    #expect(transcriber.windows.isEmpty)
  }

  @Test func aMissingAssetIsOfferedBeforeQueuingAndInstallingItStarts() async {
    let transcriber = Transcriber()
    let installed = Mutex(false)
    let lookBack = model(
      source: source(), transcriber: transcriber,
      asset: { installed.withLock { $0 } ? .installed : .downloadable },
      install: { installed.withLock { $0 = true } })
    await lookBack.appear()
    #expect(lookBack.state == .needsAsset)
    #expect(transcriber.windows.isEmpty)

    await lookBack.installAsset()
    await awaitState(.ready, of: lookBack)
    #expect(transcriber.windows.count == 2)
  }

  @Test func aDeviceWithoutARecogniserIsTold() async {
    let lookBack = model(source: source(), transcriber: Transcriber(), asset: { .unsupported })
    await lookBack.appear()
    #expect(lookBack.state == .unavailable(.noRecogniser))
  }

  @Test func aRecogniserThatDefersAsksForTheAsset() async {
    let transcriber = Transcriber()
    transcriber.fail(with: AdSkipAnalysisDeferred())
    let lookBack = model(source: source(), transcriber: transcriber)
    await lookBack.appear()
    await awaitState(.needsAsset, of: lookBack)
  }

  @Test func unreadableAudioFails() async {
    struct Unreadable: Error {}
    let transcriber = Transcriber()
    transcriber.fail(with: Unreadable())
    let lookBack = model(source: source(), transcriber: transcriber)
    await lookBack.appear()
    await awaitState(.failed(.unreadable), of: lookBack)
  }

  @Test func retryAfterAFailureRunsWhatIsLeftAndKeepsWhatLanded() async {
    struct Unreadable: Error {}
    let transcriber = Transcriber()
    let lookBack = model(source: source(), transcriber: transcriber)
    await opened(lookBack)
    transcriber.fail(with: Unreadable())
    lookBack.loadEarlier()
    await awaitState(.failed(.unreadable), of: lookBack)
    #expect(lookBack.paragraphs.sentences.count == 2)
    // Failed: the top asks for nothing more until Try Again.
    lookBack.loadEarlier()
    #expect(lookBack.reach == 450)

    transcriber.succeed()
    lookBack.retry()
    await awaitState(.ready, of: lookBack)
    #expect(lookBack.paragraphs.sentences.count == 3)
    #expect(transcriber.windows.map(\.start) == [3_850, 3_700, 3_550, 3_550])
  }

  @Test func retryDoesNothingUnlessFailed() async {
    let transcriber = Transcriber()
    let lookBack = model(source: source(), transcriber: transcriber)
    await opened(lookBack)
    lookBack.retry()
    #expect(lookBack.state == .ready)
    #expect(transcriber.windows.count == 2)
  }

  @Test func theTextIsReusedNearTheSamePlayheadOnTheSameBookOnly() {
    let lookBack = model(source: source(), transcriber: Transcriber())
    #expect(lookBack.canBeReused(for: source(), playhead: 4_050))
    #expect(lookBack.canBeReused(for: source(), playhead: 3_940))
    #expect(lookBack.canBeReused(for: source(), playhead: 4_061) == false)
    #expect(lookBack.canBeReused(for: source(duration: 9_000), playhead: 4_000) == false)
    #expect(lookBack.canBeReused(for: nil, playhead: 4_000) == false)
  }
}
