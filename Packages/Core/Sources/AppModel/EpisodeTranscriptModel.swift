import AdSkip
import Foundation
import Observation
import Persistence

/// What the transcript sheet shows for one episode: its state, the text so far, the sentence
/// being spoken, and search.
///
/// The sheet feeds the playhead in through `playheadMoved(to:)`; the model publishes a new
/// `currentSentenceIndex` only when the sentence changes. Transcript times and the player's
/// positions are both file time, with or without Trim Silences, so no mapping is needed.
@MainActor
@Observable
public final class EpisodeTranscriptModel {

  /// The coordinator's side, as closures so the model can be driven by a fake.
  public struct Source: Sendable {
    public var statusChanges: @Sendable () async -> AsyncStream<EpisodeTranscriptStatus>
    public var transcript: @Sendable () async throws -> StoredTranscript?
    public var request: @Sendable () async -> Void
    public var cancel: @Sendable () async -> Void
    /// Retries a request deferred for the speech asset.
    public var retry: @Sendable () async -> Void
    /// The episode's ranges as ad skip will skip them; none while ad skip has nothing to say.
    public var adRanges: @Sendable () async -> [TranscriptAdRange]
    /// Yields whenever `adRanges` may have changed.
    public var adRangeChanges: @Sendable () -> AsyncStream<Void>
    /// Undoes a range `adRanges` returned.
    public var undoAd: @Sendable (TranscriptAdRange) async -> Void
    /// Marks `start..<end`, in file seconds, as an ad ad skip missed.
    public var markAd: @Sendable (Double, Double) async -> Void
    /// Whether the transcript can offer to mark an ad.
    public var markingAvailability: @Sendable () async -> TranscriptAdMarking.Availability
    /// Whether a mark of `start..<end`, in file seconds, would teach the store and so skip the
    /// same audio in other episodes; false when it would skip only in this one.
    public var markTeaches: @Sendable (Double, Double) async -> Bool

    public init(
      statusChanges: @escaping @Sendable () async -> AsyncStream<EpisodeTranscriptStatus>,
      transcript: @escaping @Sendable () async throws -> StoredTranscript?,
      request: @escaping @Sendable () async -> Void,
      cancel: @escaping @Sendable () async -> Void,
      retry: @escaping @Sendable () async -> Void,
      adRanges: @escaping @Sendable () async -> [TranscriptAdRange] = { [] },
      adRangeChanges: @escaping @Sendable () -> AsyncStream<Void> = {
        AsyncStream { $0.finish() }
      },
      undoAd: @escaping @Sendable (TranscriptAdRange) async -> Void = { _ in },
      markAd: @escaping @Sendable (Double, Double) async -> Void = { _, _ in },
      markingAvailability: @escaping @Sendable () async -> TranscriptAdMarking.Availability = {
        .hidden
      },
      markTeaches: @escaping @Sendable (Double, Double) async -> Bool = { _, _ in true }
    ) {
      self.statusChanges = statusChanges
      self.transcript = transcript
      self.request = request
      self.cancel = cancel
      self.retry = retry
      self.adRanges = adRanges
      self.adRangeChanges = adRangeChanges
      self.undoAd = undoAd
      self.markAd = markAd
      self.markingAvailability = markingAvailability
      self.markTeaches = markTeaches
    }

    /// With `adSkip`, the transcript also shows, undoes and marks its ranges. An undo reaches the player
    /// through `playback` first, while the player still holds the range, and then the store.
    public static func coordinator(
      _ coordinator: EpisodeTranscriptCoordinator, identity: AdSkipEpisodeIdentity,
      adSkip: AdSkipCoordinator? = nil, playback: PlaybackModel? = nil
    ) -> Source {
      guard let adSkip else {
        return Source(
          statusChanges: { await coordinator.statusChanges(of: identity) },
          transcript: { try await coordinator.transcript(for: identity) },
          request: { await coordinator.request(identity) },
          cancel: { await coordinator.cancel(identity) },
          retry: { await coordinator.retry() })
      }
      return Source(
        statusChanges: { await coordinator.statusChanges(of: identity) },
        transcript: { try await coordinator.transcript(for: identity) },
        request: { await coordinator.request(identity) },
        cancel: { await coordinator.cancel(identity) },
        retry: { await coordinator.retry() },
        adRanges: { await adSkip.transcriptAdRanges(for: identity) },
        adRangeChanges: { adSkip.skipRangeChanges() },
        undoAd: { range in
          await playback?.undoSkippedRange(range, itemID: identity.itemID, episodeID: identity.episodeID)
          await adSkip.undoRange(
            identity: identity, start: range.start, end: range.end, origin: range.origin)
        },
        markAd: { start, end in
          await adSkip.markAd(identity: identity, start: start, end: end)
        },
        markingAvailability: { await adSkip.markingAvailability(for: identity) },
        markTeaches: { start, end in
          await adSkip.markTeaches(identity: identity, start: start, end: end)
        })
    }
  }

  public enum HeldReason: Sendable, Equatable {
    /// Waiting its turn: ad skip holds the transcriber, or the app is not in the foreground.
    case queued
    /// Paused by Low Power Mode or heat.
    case paused
  }

  /// `fraction` is how much of the file has been transcribed, from 0 to 1.
  public enum State: Sendable, Equatable {
    /// No status has arrived yet.
    case loading
    /// Not an episode that can be transcribed.
    case unavailable
    /// Not running: never started, or stopped part-way.
    case offer(fraction: Double)
    /// Waiting for the speech recogniser's asset.
    case needsAsset(fraction: Double)
    case held(HeldReason, fraction: Double)
    case generating(fraction: Double)
    case ready
    case failed
  }

  public private(set) var state: State = .loading
  public private(set) var transcript: TranscriptParagraphs = .empty
  public private(set) var currentSentenceIndex: Int?
  /// Whether the sheet keeps the current sentence in view. Scrolling by hand or searching stops
  /// it; the "Now" button and tapping a sentence resume it.
  public private(set) var isFollowing = true
  /// The ranges ad skip serves for the episode, which split `transcript` into ad blocks.
  public private(set) var adRanges: [TranscriptAdRange] = []
  /// Whether the sheet may offer "Mark an ad".
  public private(set) var markingAvailability: TranscriptAdMarking.Availability = .hidden
  /// Whether taps select the stretch to mark instead of seeking.
  public private(set) var isMarking = false
  /// The sentences selected so far, as indices into `transcript.sentences`.
  public var markingSelection: ClosedRange<Int>? { selection.range }
  /// Whether the selection, saved, would also skip its audio in other episodes. True until the
  /// source has answered for the current selection.
  public private(set) var markTeaches = true
  /// Indices into `transcript.sentences` of the sentences matching `searchQuery`.
  public private(set) var matches: [Int] = []
  /// An index into `matches`.
  public private(set) var currentMatch: Int?
  /// The ad breaks the transcribed text reaches, in time order (`TranscriptAdBreaks`).
  public private(set) var adBreaks: [TranscriptAdBreak] = []
  /// An index into `adBreaks`: the break the last step went to, while it still exists.
  public private(set) var currentAdBreak: Int?
  /// The last step's scroll, new on every step so a step back to the same break scrolls again.
  public private(set) var adBreakJump: AdBreakJump?

  /// Where a step through the ad breaks scrolls the text to.
  public struct AdBreakJump: Sendable, Equatable {
    /// Counts steps, so two steps to one break are different values.
    public let serial: Int
    /// The paragraph to bring to the top: the one before the break, so what leads into it shows.
    public let paragraphID: Int
  }

  public var searchQuery: String {
    get { query }
    set {
      query = newValue
      if isBlank(newValue) == false { isFollowing = false }
      refreshMatches(resetSelection: true)
    }
  }

  @ObservationIgnored private let source: Source
  @ObservationIgnored private let seek: @MainActor (Double) -> Void
  private var query = ""
  @ObservationIgnored private var playhead: Double?
  private var selection = TranscriptAdMarking.Selection() {
    didSet { if selection.range != oldValue.range { refreshMarkTeaches() } }
  }
  @ObservationIgnored private var markTeachesTask: Task<Void, Never>?
  @ObservationIgnored private var words: [StoredTranscriptWord] = []
  /// A time inside the break the last step went to, kept across range changes so the break in
  /// view stays the current one as a mark widens it.
  @ObservationIgnored private var adBreakAnchor: Double?

  public init(source: Source, seek: @escaping @MainActor (Double) -> Void) {
    self.source = source
    self.seek = seek
  }

  /// Follows the coordinator's status and ad ranges until cancelled, reloading the text as it
  /// grows.
  public func run() async {
    let adTask = Task { await followAdRanges() }
    await withTaskCancellationHandler {
      await followStatus()
    } onCancel: {
      adTask.cancel()
    }
    adTask.cancel()
  }

  private func followStatus() async {
    for await status in await source.statusChanges() {
      state = Self.state(for: status)
      guard Self.hasText(status) else { continue }
      guard let stored = try? await source.transcript() else { continue }
      words = stored.words
      rebuildTranscript()
    }
  }

  private func followAdRanges() async {
    let changes = source.adRangeChanges()
    adRanges = await source.adRanges()
    markingAvailability = await source.markingAvailability()
    rebuildTranscript()
    for await _ in changes {
      let available = await source.markingAvailability()
      if available != markingAvailability { markingAvailability = available }
      if available != .available { cancelMarking() }
      let ranges = await source.adRanges()
      guard ranges != adRanges else { continue }
      adRanges = ranges
      rebuildTranscript()
    }
  }

  private func rebuildTranscript() {
    let paragraphs = TranscriptParagraphs(words: words, adRanges: adRanges)
    refreshAdBreaks(textEnd: paragraphs.sentences.last?.end)
    guard paragraphs != transcript else { return }
    transcript = paragraphs
    refreshCurrentSentence()
    refreshMatches(resetSelection: false)
  }

  // MARK: - Actions

  public func transcribe() {
    let source = source
    Task { await source.request() }
  }

  public func cancel() {
    let source = source
    Task { await source.cancel() }
  }

  /// Undoes an ad the transcript shows. The range leaves the transcript at once; the source's
  /// change signal confirms it, or brings it back if it could not be removed.
  public func undoAd(_ range: TranscriptAdRange) {
    adRanges.removeAll { $0 == range }
    rebuildTranscript()
    let source = source
    Task { [weak self] in
      await source.undoAd(range)
      guard let self else { return }
      let ranges = await source.adRanges()
      if ranges != self.adRanges {
        self.adRanges = ranges
        self.rebuildTranscript()
      }
    }
  }

  /// Marks a stretch as an ad. The source applies it in the background, so the ranges are read
  /// again once it has; the change signal brings the result in whenever that is later.
  public func markAd(start: Double, end: Double) {
    let source = source
    Task { [weak self] in
      await source.markAd(start, end)
      guard let self else { return }
      let ranges = await source.adRanges()
      if ranges != self.adRanges {
        self.adRanges = ranges
        self.rebuildTranscript()
      }
    }
  }

  // MARK: - Marking

  /// Starts choosing an ad's edges. Following stops: the transcript must stay where the listener
  /// is reading.
  public func beginMarking() {
    guard markingAvailability == .available else { return }
    isMarking = true
    isFollowing = false
    selection = TranscriptAdMarking.Selection()
  }

  public func cancelMarking() {
    isMarking = false
    selection = TranscriptAdMarking.Selection()
  }

  /// A tap on a sentence: selects it while marking, plays from it otherwise. The one entry the
  /// view calls, so the mode is read when the tap lands, not when the view was built.
  public func sentenceTapped(_ index: Int) {
    if isMarking {
      selectForMarking(sentence: index)
    } else {
      play(fromSentence: index)
    }
  }

  /// A tap selects the sentence's displayed paragraph as the ad, or adjusts the selection by
  /// paragraph with sentence precision at its edges (see `Selection.tap`). Paragraphs are read
  /// from the current transcript, which ad changes can re-split, so the selection is kept as
  /// sentence indices.
  public func selectForMarking(sentence index: Int) {
    guard isMarking, transcript.sentences.indices.contains(index) else { return }
    let transcript = transcript
    selection.tap(sentence: index) { sentence in
      guard let at = transcript.paragraphIndex(containingSentence: sentence) else {
        return sentence...sentence
      }
      let paragraph = transcript.paragraphs[at]
      return paragraph.firstSentenceIndex...(paragraph.firstSentenceIndex + paragraph.sentences.count - 1)
    }
  }

  /// A tap on a paragraph's row while marking, given its first sentence: it acts on the whole
  /// paragraph. Outside marking it does nothing, since only sentence links play.
  public func paragraphTapped(firstSentence index: Int) {
    guard isMarking, transcript.sentences.indices.contains(index) else { return }
    let transcript = transcript
    func bounds(_ sentence: Int) -> ClosedRange<Int> {
      guard let at = transcript.paragraphIndex(containingSentence: sentence) else {
        return sentence...sentence
      }
      let paragraph = transcript.paragraphs[at]
      return paragraph.firstSentenceIndex...(paragraph.firstSentenceIndex + paragraph.sentences.count - 1)
    }
    selection.tap(paragraph: bounds(index), paragraphOf: bounds)
  }

  /// "Start ad here" for VoiceOver: the sentence becomes the ad's first.
  public func setMarkingStart(sentence index: Int) {
    guard isMarking, transcript.sentences.indices.contains(index) else { return }
    selection.setStart(index)
  }

  /// "End ad here" for VoiceOver: the sentence becomes the ad's last.
  public func setMarkingEnd(sentence index: Int) {
    guard isMarking, transcript.sentences.indices.contains(index) else { return }
    selection.setEnd(index)
  }

  /// The selection's span in file seconds, from the first selected sentence's start to the last's
  /// end, once a selection exists.
  public var markingSpan: ClosedRange<Double>? {
    guard let range = selection.range,
      transcript.sentences.indices.contains(range.lowerBound),
      transcript.sentences.indices.contains(range.upperBound)
    else { return nil }
    return transcript.sentences[range.lowerBound].start...transcript.sentences[range.upperBound].end
  }

  public var markingSeconds: Double? {
    markingSpan.map { $0.upperBound - $0.lowerBound }
  }

  /// Whether the selection may be saved: `ListenerMarks.isLongEnough` against the ads shown, so a
  /// short stretch beside one can be.
  public var isMarkingLongEnoughToSave: Bool {
    guard let span = markingSpan else { return false }
    return ListenerMarks.isLongEnough(
      start: span.lowerBound, end: span.upperBound,
      beside: adRanges.map { TimeSpan(start: $0.start, end: $0.end) })
  }

  /// Whether saving should first ask: the selection is longer than an ad usually is.
  public var needsLongMarkConfirmation: Bool {
    (markingSeconds ?? 0) > TranscriptAdMarking.confirmationSeconds
  }

  /// Asks the source about the current selection; an answer for an earlier one is dropped.
  private func refreshMarkTeaches() {
    markTeachesTask?.cancel()
    markTeaches = true
    guard let span = markingSpan else { return }
    let source = source
    markTeachesTask = Task { [weak self] in
      let teaches = await source.markTeaches(span.lowerBound, span.upperBound)
      guard Task.isCancelled == false, let self, self.markingSpan == span else { return }
      self.markTeaches = teaches
    }
  }

  /// Marks the selection as an ad, with exactly the selected sentences' edges, and leaves the mode.
  public func confirmMarking() {
    guard isMarking, isMarkingLongEnoughToSave, let span = markingSpan else { return }
    cancelMarking()
    markAd(start: span.lowerBound, end: span.upperBound)
  }

  public func retryAsset() {
    let source = source
    Task { await source.retry() }
  }

  // MARK: - Following

  public func playheadMoved(to time: Double) {
    playhead = time
    refreshCurrentSentence()
  }

  public func stopFollowing() {
    isFollowing = false
  }

  public func resumeFollowing() {
    isFollowing = true
  }

  /// Plays from a sentence's start. A seek into a range ad skip would have skipped plays it: the
  /// skip rule fires only when playback enters a range from before its start.
  public func play(fromSentence index: Int) {
    guard transcript.sentences.indices.contains(index) else { return }
    isFollowing = true
    seek(transcript.sentences[index].start)
  }

  // MARK: - Search

  public func nextMatch() {
    guard let currentMatch, matches.isEmpty == false else { return }
    self.currentMatch = (currentMatch + 1) % matches.count
  }

  public func previousMatch() {
    guard let currentMatch, matches.isEmpty == false else { return }
    self.currentMatch = (currentMatch - 1 + matches.count) % matches.count
  }

  // MARK: - Ad breaks

  /// The next break: after the one in view, or after the playhead before any step.
  public func nextAdBreak() {
    guard adBreaks.isEmpty == false else { return }
    let index: Int
    if let currentAdBreak {
      index = (currentAdBreak + 1) % adBreaks.count
    } else {
      let from = adBreakAnchor ?? playhead ?? -.infinity
      index = adBreaks.firstIndex { $0.start > from } ?? 0
    }
    goToAdBreak(index)
  }

  /// The previous break: before the one in view, or before the playhead before any step.
  public func previousAdBreak() {
    guard adBreaks.isEmpty == false else { return }
    let index: Int
    if let currentAdBreak {
      index = (currentAdBreak - 1 + adBreaks.count) % adBreaks.count
    } else {
      let from = adBreakAnchor ?? playhead ?? .infinity
      index = adBreaks.lastIndex { $0.end < from } ?? adBreaks.count - 1
    }
    goToAdBreak(index)
  }

  private func goToAdBreak(_ index: Int) {
    let adBreak = adBreaks[index]
    adBreakAnchor = adBreak.start
    currentAdBreak = index
    isFollowing = false
    let paragraphs = transcript.paragraphs
    guard
      let first = paragraphs.firstIndex(where: { ($0.sentences.last?.end ?? 0) > adBreak.start })
    else { return }
    adBreakJump = AdBreakJump(
      serial: (adBreakJump?.serial ?? 0) + 1, paragraphID: paragraphs[max(0, first - 1)].id)
  }

  private func refreshAdBreaks(textEnd: Double?) {
    let breaks = textEnd.map { TranscriptAdBreaks.breaks(adRanges, before: $0) } ?? []
    if breaks != adBreaks { adBreaks = breaks }
    let current = adBreakAnchor.flatMap { anchor in breaks.firstIndex { $0.contains(anchor) } }
    if current != currentAdBreak { currentAdBreak = current }
  }

  // MARK: - Private

  private func refreshCurrentSentence() {
    let index = playhead.flatMap { transcript.sentenceIndex(at: $0) }
    if index != currentSentenceIndex { currentSentenceIndex = index }
  }

  private func refreshMatches(resetSelection: Bool) {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let found: [Int] =
      needle.isEmpty
      ? []
      : transcript.sentences.indices.filter {
        transcript.sentences[$0].text.range(
          of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
      }
    if found != matches { matches = found }
    let selection: Int? =
      if found.isEmpty {
        nil
      } else if resetSelection {
        0
      } else {
        min(currentMatch ?? 0, found.count - 1)
      }
    if selection != currentMatch { currentMatch = selection }
  }

  private func isBlank(_ text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private static func state(for status: EpisodeTranscriptStatus) -> State {
    switch status {
    case .unavailable: .unavailable
    case .notStarted: .offer(fraction: 0)
    case .stopped(let covered): .offer(fraction: covered)
    case .waiting(.deferred, let covered): .needsAsset(fraction: covered)
    case .waiting(.queued, let covered): .held(.queued, fraction: covered)
    case .waiting(.held, let covered): .held(.paused, fraction: covered)
    case .generating(let covered): .generating(fraction: covered)
    case .complete: .ready
    case .failed: .failed
    }
  }

  /// Whether the status can have words behind it.
  private static func hasText(_ status: EpisodeTranscriptStatus) -> Bool {
    switch status {
    case .unavailable, .notStarted, .failed: false
    case .stopped, .waiting, .generating, .complete: true
    }
  }
}
