import AdSkip
import Foundation
import Observation
import Persistence

/// The Look Back sheet's state: the stretch before the playhead
/// is transcribed newest chunk first as soon as the sheet opens, Show Earlier reaches
/// further back a chunk at a time, and a tapped sentence plays from there. Held in memory only, for
/// the loaded book, while the playhead stays near `t`.
///
/// The text is user content: never log it.
@MainActor
@Observable
public final class LookBackModel {
  public enum Unavailable: Sendable, Equatable {
    /// The book streams: Look Back reads downloaded files only.
    case notDownloaded
    /// The device has no English recogniser to download.
    case noRecogniser
  }

  public enum Failure: Sendable, Equatable {
    /// The audio could not be read or recognised.
    case unreadable
    /// Stopped at critical thermal state.
    case tooHot
  }

  public enum State: Sendable, Equatable {
    /// Before the first `appear()`.
    case loading
    case unavailable(Unavailable)
    case needsAsset
    case installingAsset
    /// Queued behind another analysis at the shared recogniser.
    case waiting
    case transcribing
    /// Everything asked for so far is transcribed.
    case ready
    case failed(Failure)
  }

  /// Whether the speech asset is there, can be fetched, or cannot exist on this device.
  public enum AssetState: Sendable, Equatable {
    case installed
    case downloadable
    case unsupported
  }

  public struct Dependencies {
    public var coordinator: LookBackCoordinator
    public var assetState: @Sendable () async -> AssetState
    public var installAsset: @Sendable () async throws -> Void

    public init(
      coordinator: LookBackCoordinator, assetState: @escaping @Sendable () async -> AssetState,
      installAsset: @escaping @Sendable () async throws -> Void
    ) {
      self.coordinator = coordinator
      self.assetState = assetState
      self.installAsset = installAsset
    }
  }

  /// How far the playhead may move from `t` before the text is stale and a new Look Back starts.
  public static let reuseDistance: Double = 60

  /// The book's playhead when Look Back opened, in seconds of book time.
  public let playhead: Double
  public let source: LookBackSource?

  public private(set) var state: State = .loading
  /// How far back before the playhead is asked for, in seconds: `LookBackPlan.initialReach` on
  /// open, a chunk more each time the listener asks for earlier text, up to `maximumReach`.
  public private(set) var reach: Double = LookBackPlan.initialReach
  public private(set) var paragraphs = TranscriptParagraphs.empty
  /// Chapter titles keyed by the paragraph each heads.
  public private(set) var chapterHeadings: [Int: String] = [:]
  /// Where the last tapped sentence started playing from, in book time; nil before a tap.
  public private(set) var playingFrom: Double?
  /// The sentence drawn highlighted: the newest until a sentence is tapped, then the one playing,
  /// or none once playback has gone past the text. Assigned only when it changes, so the
  /// position tick does not redraw the sheet.
  public private(set) var highlightedSentenceIndex: Int?
  /// Whether the text keeps the highlighted sentence in view, as the podcast transcript does. The
  /// sheet opens at the newest sentence, so it starts out following; scrolling stops it.
  public private(set) var isFollowing = true

  private let dependencies: Dependencies
  private let play: (Double) -> Void
  private var words: [TranscriptWord] = []
  /// The playback position since the last tap, in book time.
  private var playbackTime: Double?
  /// Seconds before the playhead already transcribed, contiguous from the playhead.
  private var coveredSeconds: Double = 0
  private var run: Task<Void, Never>?
  /// Tells a cancelled run's late events from the current run's.
  private var runID = 0
  private var isVisible = false

  public init(
    source: LookBackSource?, playhead: Double, dependencies: Dependencies,
    play: @escaping (Double) -> Void
  ) {
    self.source = source
    self.playhead = playhead
    self.dependencies = dependencies
    self.play = play
  }

  /// Whether this model's text still serves a Look Back opened on `source` at `playhead`.
  public func canBeReused(for source: LookBackSource?, playhead: Double) -> Bool {
    guard let source, source == self.source else { return false }
    return abs(playhead - self.playhead) <= Self.reuseDistance
  }

  /// The sheet is showing: decide what it can offer, then transcribe whatever is asked for and not
  /// yet done, which on first open is the newest `initialReach`.
  public func appear() async {
    isVisible = true
    guard source != nil else {
      state = .unavailable(.notDownloaded)
      return
    }
    switch await dependencies.assetState() {
    case .unsupported:
      state = .unavailable(.noRecogniser)
      return
    case .downloadable:
      state = .needsAsset
      return
    case .installed:
      break
    }
    guard isVisible else { return }
    startRun()
  }

  /// The sheet closed or the app left the foreground: cancel the chunk in flight, which releases
  /// the recogniser. What has landed is kept.
  public func disappear() {
    isVisible = false
    run?.cancel()
    run = nil
  }

  /// Whether there is anything further back to ask for: neither the start of the book nor the
  /// limit.
  public var canLoadEarlier: Bool { reachesStartOfBook == false && reachesLimit == false }

  /// Whether the text reaches the start of the book.
  public var reachesStartOfBook: Bool { playhead - coveredSeconds <= 0 }

  /// Whether `LookBackPlan.maximumReach` is asked for: scrolling up reaches no further.
  public var reachesLimit: Bool { reach >= LookBackPlan.maximumReach }

  /// The listener asked for earlier text: transcribe one chunk further back. Ignored while a chunk
  /// is still running, so each ask is one chunk.
  public func loadEarlier() {
    guard state == .ready, canLoadEarlier else { return }
    reach = min(LookBackPlan.maximumReach, reach + LookBackPlan.chunkSeconds)
    startRun()
  }

  /// Runs the chunks a failure left undone, keeping what landed before it.
  public func retry() {
    guard case .failed = state else { return }
    startRun()
  }

  /// Fetches the speech asset after the listener agreed, then starts.
  public func installAsset() async {
    guard state == .needsAsset else { return }
    state = .installingAsset
    do {
      try await dependencies.installAsset()
    } catch {
      state = .needsAsset
      return
    }
    state = .loading
    await appear()
  }

  /// Plays from the sentence at `index`, which is then drawn as the one playing and followed.
  public func playSentence(at index: Int) {
    guard paragraphs.sentences.indices.contains(index) else { return }
    let start = paragraphs.sentences[index].start
    playingFrom = start
    playbackTime = start
    isFollowing = true
    updateHighlight()
    play(start)
  }

  /// The player's position moved. Followed only after a tap: before one, the book is paused at
  /// the playhead and the newest sentence stays highlighted.
  public func playbackMoved(to time: Double) {
    guard playingFrom != nil else { return }
    playbackTime = time
    updateHighlight()
  }

  /// The listener scrolled: leave the text where they put it.
  public func stopFollowing() {
    isFollowing = false
  }

  /// "Now": back to the highlighted sentence, and keep it in view.
  public func resumeFollowing() {
    isFollowing = true
  }

  /// Where the highlighted sentence starts: its identity, which older text landing above leaves
  /// alone while shifting its index. Following scrolls on this, so the text the sheet opened on
  /// stays put as earlier text fills in above it.
  public var highlightedSentenceStart: Double? {
    highlightedSentenceIndex.map { paragraphs.sentences[$0].start }
  }

  /// The sentence nearest the playhead: the newest.
  public var newestSentenceIndex: Int? {
    paragraphs.sentences.isEmpty ? nil : paragraphs.sentences.count - 1
  }

  // MARK: - Running

  private func startRun() {
    guard run == nil, isVisible, let source else { return }
    let chunks = LookBackPlan.chunks(
      playhead: playhead, length: reach, alreadyCovered: coveredSeconds, tracks: source.tracks)
    guard chunks.isEmpty == false else {
      state = .ready
      return
    }
    state = .waiting
    runID += 1
    let id = runID
    let coordinator = dependencies.coordinator
    let existing = words
    run = Task { [weak self] in
      let result: (any Error)?
      do {
        _ = try await coordinator.run(chunks, before: existing) { [weak self] event in
          await self?.handle(event, run: id)
        }
        result = nil
      } catch {
        result = error
      }
      self?.runEnded(result, run: id)
    }
  }

  private func handle(_ event: LookBackEvent, run id: Int) {
    guard id == runID else { return }
    switch event {
    case .waiting:
      state = .waiting
    case .started:
      state = .transcribing
    case .chunk(let segment, let joined):
      coveredSeconds = max(coveredSeconds, playhead - segment.bookWindow.start)
      setWords(joined)
    }
  }

  private func runEnded(_ error: (any Error)?, run id: Int) {
    guard id == runID else { return }
    run = nil
    switch error {
    case nil:
      state = .ready
    case is CancellationError:
      // Closed or backgrounded: what landed stays; the rest runs again on the next appear.
      state = words.isEmpty ? .loading : .ready
    case is AdSkipAnalysisDeferred:
      state = .needsAsset
    case is LookBackTooHot:
      state = .failed(.tooHot)
    default:
      state = .failed(.unreadable)
    }
  }

  private func setWords(_ joined: [TranscriptWord]) {
    words = joined
    paragraphs = TranscriptParagraphs(
      words: joined.map { StoredTranscriptWord(text: $0.text, start: $0.start, end: $0.end) })
    chapterHeadings = paragraphs.chapterHeadings(
      (source?.chapters ?? []).map { (start: $0.start, title: $0.title) })
    updateHighlight()
  }

  private func updateHighlight() {
    let index: Int?
    if let playbackTime {
      let sentences = paragraphs.sentences
      // After the last sentence by more than a pause, playback has gone past the text.
      let isPast = sentences.last.map { playbackTime > $0.end + TranscriptParagraphs.paragraphGap } ?? true
      index = isPast ? nil : paragraphs.sentenceIndex(at: playbackTime)
    } else {
      index = newestSentenceIndex
    }
    if index != highlightedSentenceIndex { highlightedSentenceIndex = index }
  }
}
