import Testing
import WatchProtocol

@testable import WatchPlayback

private typealias Machine = WatchPlaybackMachine
private let book = WatchSelection.audiobookshelf(itemID: "book", episodeID: nil)
private let other = WatchSelection.audiobookshelf(itemID: "other", episodeID: nil)
private let feed = WatchSelection.nativeFeed(feedID: "feed", episodeID: "episode")

/// The machine in each phase, reached through its own events.
private enum Start: CaseIterable {
  case idle, starting, playing, paused, resuming, renewing, seekingPlaying, seekingPaused, handingOff

  func machine() -> Machine {
    var machine = Machine()
    func attempt() -> Machine.Attempt { machine.phase.attempt! }
    if self == .idle { return machine }
    _ = machine.handle(.play(book, .ready))
    if self == .starting { return machine }
    let start = attempt()
    _ = machine.handle(.peerAnswered(start, position: nil))
    _ = machine.handle(.prepared(start))
    _ = machine.handle(.audioStarted(start))
    switch self {
    case .playing: break
    case .paused: _ = machine.handle(.pause(.listener))
    case .resuming:
      _ = machine.handle(.pause(.listener))
      _ = machine.handle(.resume(.ready, bookmark: nil))
    case .renewing: _ = machine.handle(.audioFailed(unauthorized: true, streaming: true))
    case .seekingPlaying: _ = machine.handle(.seek(to: 40))
    case .seekingPaused:
      _ = machine.handle(.pause(.listener))
      _ = machine.handle(.seek(to: 40))
    case .handingOff: _ = machine.handle(.continueOnPhone)
    case .idle, .starting: break
    }
    return machine
  }
}

/// The phase without its attempt, so table rows need not predict attempt numbers.
private enum Shape: Equatable {
  case idle
  case starting(WatchSelection)
  case playing(WatchSelection)
  case paused(WatchSelection)
  case resuming(WatchSelection, Machine.Resumption)
  case seeking(target: Double, resumeAfter: Bool)
  case handingOff

  init(_ phase: Machine.Phase) {
    switch phase {
    case .idle: self = .idle
    case .starting(let selection, _): self = .starting(selection)
    case .playing(let selection): self = .playing(selection)
    case .paused(let selection): self = .paused(selection)
    case .resuming(let selection, _, let resumption): self = .resuming(selection, resumption)
    case .seeking(_, let target, let resumeAfter, _): self = .seeking(target: target, resumeAfter: resumeAfter)
    case .handingOff: self = .handingOff
    }
  }
}

/// Effects with their attempts erased, for the same reason.
private func erased(_ effects: [Machine.Effect]) -> [String] {
  effects.map { "\($0)".replacingOccurrences(of: #"Attempt\(id: \d+\)"#, with: "A", options: .regularExpression) }
}

private let pausing: [Machine.Effect] = [
  .pauseAudio, .closeRow(ending: false, finished: false, uploadAfter: true), .stopTicker, .publishPlaying(false),
]
private let release: [Machine.Effect] = [
  .pauseAudio, .closeRow(ending: true, finished: false, uploadAfter: false), .stopTicker, .stopAudio,
  .publishPlaying(false),
]
private func teardown(finished: Bool) -> [Machine.Effect] {
  [
    .pauseAudio, .saveBookmark(atStart: finished), .closeRow(ending: true, finished: finished, uploadAfter: false),
    .stopTicker, .stopAudio, .publishPlaying(false),
  ]
}
private let anyAttempt = Machine.Attempt(id: 0)

private struct Row: CustomTestStringConvertible, Sendable {
  let start: Start
  let event: Machine.Event
  let shape: Shape
  let effects: [Machine.Effect]
  var testDescription: String { "\(start) + \(event)" }
}

// Every request in every phase. `anyAttempt` in an expected effect stands for whatever attempt the
// machine assigned.
private let requests: [Row] = [
  // play: a newer start supersedes whatever is there, releasing an unfinished start.
  Row(start: .idle, event: .play(other, .ready), shape: .starting(other), effects: [.askPeer(other, anyAttempt)]),
  Row(
    start: .starting, event: .play(other, .ready), shape: .starting(other),
    effects: release + [.askPeer(other, anyAttempt)]),
  Row(
    start: .playing, event: .play(other, .ready), shape: .starting(other),
    effects: teardown(finished: false) + [.askPeer(other, anyAttempt)]),
  Row(
    start: .paused, event: .play(other, .ready), shape: .starting(other),
    effects: teardown(finished: false) + [.askPeer(other, anyAttempt)]),
  Row(
    start: .resuming, event: .play(other, .ready), shape: .starting(other),
    effects: teardown(finished: false) + [.askPeer(other, anyAttempt)]),
  Row(
    start: .renewing, event: .play(other, .ready), shape: .starting(other),
    effects: teardown(finished: false) + [.askPeer(other, anyAttempt)]),
  Row(
    start: .seekingPlaying, event: .play(other, .ready), shape: .starting(other),
    effects: teardown(finished: false) + [.askPeer(other, anyAttempt)]),
  Row(
    start: .seekingPaused, event: .play(other, .ready), shape: .starting(other),
    effects: teardown(finished: false) + [.askPeer(other, anyAttempt)]),
  Row(
    start: .handingOff, event: .play(other, .ready), shape: .starting(other),
    effects: teardown(finished: false) + [.askPeer(other, anyAttempt)]),
  // A refusal changes nothing and says why.
  Row(start: .playing, event: .play(feed, .ready), shape: .playing(book), effects: [.show(.nativeFeed)]),
  Row(start: .idle, event: .play(other, .launching), shape: .idle, effects: [.show(.launching)]),
  Row(start: .idle, event: .play(other, .signedOut), shape: .idle, effects: [.show(.signedOut)]),
  Row(
    start: .playing, event: .play(other, .busy(.downloading)), shape: .playing(book),
    effects: [.show(.busy(.downloading))]),

  // resume
  Row(start: .idle, event: .resume(.ready, bookmark: nil), shape: .idle, effects: [.show(.nothingToResume)]),
  Row(start: .idle, event: .resume(.launching, bookmark: nil), shape: .idle, effects: [.show(.launching)]),
  // With nothing loaded, the bookmarked title starts.
  Row(
    start: .idle, event: .resume(.ready, bookmark: other), shape: .starting(other),
    effects: [.askPeer(other, anyAttempt)]),
  Row(start: .idle, event: .resume(.signedOut, bookmark: other), shape: .idle, effects: [.show(.signedOut)]),
  Row(start: .starting, event: .resume(.ready, bookmark: nil), shape: .starting(book), effects: []),
  Row(start: .playing, event: .resume(.ready, bookmark: nil), shape: .playing(book), effects: []),
  Row(
    start: .paused, event: .resume(.ready, bookmark: nil), shape: .resuming(book, .catchUp),
    effects: [.tellPeer(book), .catchUp(book, anyAttempt)]),
  // A second tap while catching up does not start a second catch-up.
  Row(start: .resuming, event: .resume(.ready, bookmark: nil), shape: .resuming(book, .catchUp), effects: []),
  Row(start: .renewing, event: .resume(.ready, bookmark: nil), shape: .resuming(book, .renewal), effects: []),
  Row(
    start: .seekingPlaying, event: .resume(.ready, bookmark: nil), shape: .seeking(target: 40, resumeAfter: true),
    effects: []),
  Row(
    start: .seekingPaused, event: .resume(.ready, bookmark: nil), shape: .seeking(target: 40, resumeAfter: false),
    effects: []),
  Row(start: .handingOff, event: .resume(.ready, bookmark: nil), shape: .handingOff, effects: []),

  // pause. A pause during a start cancels it.
  Row(start: .idle, event: .pause(.listener), shape: .idle, effects: []),
  Row(start: .starting, event: .pause(.listener), shape: .idle, effects: release),
  Row(start: .playing, event: .pause(.listener), shape: .paused(book), effects: pausing),
  Row(start: .paused, event: .pause(.listener), shape: .paused(book), effects: []),
  Row(start: .resuming, event: .pause(.listener), shape: .paused(book), effects: pausing),
  Row(start: .renewing, event: .pause(.listener), shape: .paused(book), effects: pausing),
  // A pause during a seek lets it finish, then stays paused at the target.
  Row(
    start: .seekingPlaying, event: .pause(.listener), shape: .seeking(target: 40, resumeAfter: false), effects: pausing),
  Row(
    start: .seekingPaused, event: .pause(.listener), shape: .seeking(target: 40, resumeAfter: false), effects: pausing),
  Row(start: .handingOff, event: .pause(.listener), shape: .handingOff, effects: []),
  // The phone's pause also keeps the bookmark.
  Row(
    start: .playing, event: .pause(.peer), shape: .paused(book),
    effects: [.pauseAudio, .saveBookmark(atStart: false)] + pausing.dropFirst()),
  Row(start: .paused, event: .pause(.peer), shape: .paused(book), effects: [.saveBookmark(atStart: false)]),
  Row(start: .starting, event: .pause(.peer), shape: .idle, effects: release),

  // stop. One teardown, audio first.
  Row(start: .idle, event: .stop(finished: false), shape: .idle, effects: []),
  Row(start: .starting, event: .stop(finished: false), shape: .idle, effects: release),
  Row(
    start: .playing, event: .stop(finished: false), shape: .idle, effects: teardown(finished: false) + [.requestUpload]),
  Row(start: .paused, event: .stop(finished: true), shape: .idle, effects: teardown(finished: true) + [.requestUpload]),
  Row(
    start: .resuming, event: .stop(finished: false), shape: .idle, effects: teardown(finished: false) + [.requestUpload]
  ),
  Row(
    start: .renewing, event: .stop(finished: false), shape: .idle, effects: teardown(finished: false) + [.requestUpload]
  ),
  Row(
    start: .seekingPlaying, event: .stop(finished: false), shape: .idle,
    effects: teardown(finished: false) + [.requestUpload]),
  Row(
    start: .seekingPaused, event: .stop(finished: false), shape: .idle,
    effects: teardown(finished: false) + [.requestUpload]),
  Row(
    start: .handingOff, event: .stop(finished: false), shape: .idle,
    effects: teardown(finished: false) + [.requestUpload]),

  // seek
  Row(start: .idle, event: .seek(to: 10), shape: .idle, effects: []),
  Row(start: .starting, event: .seek(to: 10), shape: .starting(book), effects: []),
  Row(
    start: .playing, event: .seek(to: 10), shape: .seeking(target: 10, resumeAfter: true),
    effects: [.recordTick, .seekAudio(to: 10, anyAttempt)]),
  Row(
    start: .paused, event: .seek(to: 10), shape: .seeking(target: 10, resumeAfter: false),
    effects: [.recordTick, .seekAudio(to: 10, anyAttempt)]),
  Row(
    start: .paused, event: .seek(to: -5), shape: .seeking(target: 0, resumeAfter: false),
    effects: [.recordTick, .seekAudio(to: 0, anyAttempt)]),
  Row(start: .playing, event: .seek(to: .nan), shape: .playing(book), effects: []),
  Row(start: .resuming, event: .seek(to: 10), shape: .resuming(book, .catchUp), effects: []),
  Row(start: .renewing, event: .seek(to: 10), shape: .resuming(book, .renewal), effects: []),
  Row(
    start: .seekingPlaying, event: .seek(to: 10), shape: .seeking(target: 10, resumeAfter: true),
    effects: [.seekAudio(to: 10, anyAttempt)]),
  Row(
    start: .seekingPaused, event: .seek(to: 10), shape: .seeking(target: 10, resumeAfter: false),
    effects: [.seekAudio(to: 10, anyAttempt)]),
  Row(start: .handingOff, event: .seek(to: 10), shape: .handingOff, effects: []),

  // skip
  Row(start: .idle, event: .skip(by: 30, position: 5, duration: 100), shape: .idle, effects: []),
  Row(start: .starting, event: .skip(by: 30, position: 5, duration: 100), shape: .starting(book), effects: []),
  Row(
    start: .playing, event: .skip(by: 30, position: 5, duration: 100), shape: .seeking(target: 35, resumeAfter: true),
    effects: [.recordTick, .seekAudio(to: 35, anyAttempt)]),
  Row(
    start: .paused, event: .skip(by: -30, position: 5, duration: 100), shape: .seeking(target: 0, resumeAfter: false),
    effects: [.recordTick, .seekAudio(to: 0, anyAttempt)]),
  // A skip during a seek adds to its target, not to the sampled position.
  Row(
    start: .seekingPlaying, event: .skip(by: 30, position: 5, duration: 100),
    shape: .seeking(target: 70, resumeAfter: true), effects: [.seekAudio(to: 70, anyAttempt)]),
  // A skip onto the end finishes the title.
  Row(
    start: .playing, event: .skip(by: 30, position: 90, duration: 100), shape: .idle,
    effects: teardown(finished: true) + [.requestUpload]),
  Row(
    start: .resuming, event: .skip(by: 30, position: 5, duration: 100), shape: .resuming(book, .catchUp), effects: []),
  Row(
    start: .renewing, event: .skip(by: 30, position: 5, duration: 100), shape: .resuming(book, .renewal), effects: []),
  Row(start: .handingOff, event: .skip(by: 30, position: 5, duration: 100), shape: .handingOff, effects: []),

  // continue on iPhone
  Row(start: .idle, event: .continueOnPhone, shape: .idle, effects: []),
  Row(start: .starting, event: .continueOnPhone, shape: .starting(book), effects: []),
  Row(
    start: .playing, event: .continueOnPhone, shape: .handingOff,
    effects: [
      .pauseAudio, .saveBookmark(atStart: false), .closeRow(ending: false, finished: false, uploadAfter: true),
      .stopTicker, .publishPlaying(false), .sendToPhone(book, anyAttempt),
    ]),
  Row(
    start: .paused, event: .continueOnPhone, shape: .handingOff,
    effects: [
      .pauseAudio, .saveBookmark(atStart: false), .closeRow(ending: false, finished: false, uploadAfter: true),
      .stopTicker, .publishPlaying(false), .sendToPhone(book, anyAttempt),
    ]),
  Row(start: .resuming, event: .continueOnPhone, shape: .resuming(book, .catchUp), effects: []),
  Row(start: .seekingPlaying, event: .continueOnPhone, shape: .seeking(target: 40, resumeAfter: true), effects: []),
  Row(start: .handingOff, event: .continueOnPhone, shape: .handingOff, effects: []),

  // tick (a due checkpoint is cut while playing only)
  Row(
    start: .playing, event: .tick(checkpointDue: false), shape: .playing(book),
    effects: [.recordTick, .saveBookmark(atStart: false)]),
  Row(
    start: .playing, event: .tick(checkpointDue: true), shape: .playing(book),
    effects: [.recordTick, .saveBookmark(atStart: false), .checkpoint]),
  Row(start: .paused, event: .tick(checkpointDue: true), shape: .paused(book), effects: []),
  Row(start: .starting, event: .tick(checkpointDue: true), shape: .starting(book), effects: []),
  Row(
    start: .seekingPlaying, event: .tick(checkpointDue: true), shape: .seeking(target: 40, resumeAfter: true),
    effects: []),

  // the end of the audio
  Row(start: .idle, event: .audioEnded, shape: .idle, effects: []),
  Row(start: .starting, event: .audioEnded, shape: .starting(book), effects: []),
  Row(start: .playing, event: .audioEnded, shape: .idle, effects: teardown(finished: true) + [.requestUpload]),
  Row(start: .paused, event: .audioEnded, shape: .paused(book), effects: []),
  Row(start: .seekingPlaying, event: .audioEnded, shape: .idle, effects: teardown(finished: true) + [.requestUpload]),
  Row(start: .handingOff, event: .audioEnded, shape: .handingOff, effects: []),

  // audio failure. One renewal for a 401 on a stream.
  Row(start: .idle, event: .audioFailed(unauthorized: false, streaming: true), shape: .idle, effects: []),
  Row(
    start: .starting, event: .audioFailed(unauthorized: false, streaming: true), shape: .idle,
    effects: release + [.show(.streamFailed)]),
  Row(
    start: .playing, event: .audioFailed(unauthorized: true, streaming: true), shape: .resuming(book, .renewal),
    effects: [.recordTick, .renew(book, anyAttempt)]),
  Row(
    start: .playing, event: .audioFailed(unauthorized: false, streaming: true), shape: .paused(book),
    effects: pausing + [.show(.streamFailed)]),
  Row(
    start: .playing, event: .audioFailed(unauthorized: true, streaming: false), shape: .paused(book),
    effects: pausing + [.show(.downloadFailed)]),
  Row(
    start: .paused, event: .audioFailed(unauthorized: false, streaming: false), shape: .paused(book),
    effects: []),
  Row(
    start: .seekingPlaying, event: .audioFailed(unauthorized: false, streaming: true), shape: .paused(book),
    effects: pausing + [.show(.streamFailed)]),
  // A paused stream's 401 must not start it playing: it keeps the renewal for the next play.
  Row(start: .paused, event: .audioFailed(unauthorized: true, streaming: true), shape: .paused(book), effects: []),
  Row(
    start: .seekingPaused, event: .audioFailed(unauthorized: true, streaming: true), shape: .paused(book),
    effects: []),
  Row(
    start: .seekingPlaying, event: .audioFailed(unauthorized: true, streaming: true),
    shape: .resuming(book, .renewal), effects: [.recordTick, .renew(book, anyAttempt)]),
  Row(start: .handingOff, event: .audioFailed(unauthorized: false, streaming: true), shape: .handingOff, effects: []),

  // A grown duration reaches the row of whatever is loaded.
  Row(start: .idle, event: .durationGrew(120), shape: .idle, effects: []),
  Row(start: .starting, event: .durationGrew(120), shape: .starting(book), effects: [.growRow(to: 120)]),
  Row(start: .playing, event: .durationGrew(120), shape: .playing(book), effects: [.growRow(to: 120)]),
  Row(start: .paused, event: .durationGrew(.infinity), shape: .paused(book), effects: []),

  // A stream that cannot continue pauses with a message; nothing retries.
  Row(start: .idle, event: .stalled, shape: .idle, effects: []),
  Row(start: .starting, event: .stalled, shape: .idle, effects: release + [.show(.streamLost)]),
  Row(start: .playing, event: .stalled, shape: .paused(book), effects: pausing + [.show(.streamLost)]),
  Row(start: .paused, event: .stalled, shape: .paused(book), effects: []),
  Row(start: .resuming, event: .stalled, shape: .paused(book), effects: pausing + [.show(.streamLost)]),
  Row(start: .renewing, event: .stalled, shape: .paused(book), effects: pausing + [.show(.streamLost)]),
  Row(start: .seekingPlaying, event: .stalled, shape: .paused(book), effects: pausing + [.show(.streamLost)]),
  Row(start: .seekingPaused, event: .stalled, shape: .seeking(target: 40, resumeAfter: false), effects: []),
  Row(start: .handingOff, event: .stalled, shape: .handingOff, effects: []),

  // An interruption that ends with shouldResume resumes a paused title plainly: no catch-up,
  // the row reopened. From any other phase it does nothing, and it never plays a bookmark.
  Row(start: .idle, event: .resumeAfterInterruption, shape: .idle, effects: []),
  Row(start: .starting, event: .resumeAfterInterruption, shape: .starting(book), effects: []),
  Row(start: .playing, event: .resumeAfterInterruption, shape: .playing(book), effects: []),
  Row(
    start: .paused, event: .resumeAfterInterruption, shape: .resuming(book, .interruption),
    effects: [.tellPeer(book), .reopenRow(anyAttempt)]),
  Row(start: .resuming, event: .resumeAfterInterruption, shape: .resuming(book, .catchUp), effects: []),
  Row(start: .renewing, event: .resumeAfterInterruption, shape: .resuming(book, .renewal), effects: []),
  Row(
    start: .seekingPlaying, event: .resumeAfterInterruption, shape: .seeking(target: 40, resumeAfter: true),
    effects: []),
  Row(
    start: .seekingPaused, event: .resumeAfterInterruption, shape: .seeking(target: 40, resumeAfter: false),
    effects: []),
  Row(start: .handingOff, event: .resumeAfterInterruption, shape: .handingOff, effects: []),
]

@Suite struct WatchPlaybackMachineTests {
  @Test(arguments: requests)
  fileprivate func aRequest(_ row: Row) {
    var machine = row.start.machine()
    let effects = machine.handle(row.event)
    #expect(Shape(machine.phase) == row.shape)
    #expect(erased(effects) == erased(row.effects))
    if let attempt = machine.phase.attempt, let tagged = effects.last.flatMap(Self.attempt) {
      #expect(tagged == attempt, "the effect's attempt is the phase's")
    }
  }

  /// A completion for an attempt that is not current asks for nothing and changes nothing: what
  /// superseded the attempt already asked for the release of what it loaded.
  @Test(arguments: Start.allCases)
  fileprivate func aStaleCompletionDoesNothing(_ start: Start) {
    let stale = Machine.Attempt(id: 999)
    let completions: [Machine.Event] = [
      .peerAnswered(stale, position: 4), .prepared(stale), .caughtUp(stale), .renewed(stale),
      .reopened(stale), .audioStarted(stale), .seekFinished(stale), .continueAnswered(stale, .accepted),
      .failed(stale, .failed),
    ]
    for completion in completions {
      var machine = start.machine()
      let before = machine
      #expect(machine.handle(completion).isEmpty, "\(completion)")
      #expect(machine == before, "\(completion)")
    }
  }

  // MARK: Interruptions

  @Test func anInterruptionResumeReopensTheRowAndPlays() {
    var machine = Start.paused.machine()
    _ = machine.handle(.resumeAfterInterruption)
    let attempt = machine.phase.attempt!
    #expect(machine.handle(.reopened(attempt)) == [.playAudio(attempt)])
    #expect(
      machine.handle(.audioStarted(attempt)) == [.startListening, .startTicker, .publishPlaying(true), .clearMessage])
    #expect(machine.phase == .playing(book))
  }

  @Test func aFailedInterruptionResumeStaysPausedWithAMessage() {
    var machine = Start.paused.machine()
    _ = machine.handle(.resumeAfterInterruption)
    let attempt = machine.phase.attempt!
    #expect(machine.handle(.failed(attempt, .failed)) == pausing + [.show(.resumeFailed)])
    #expect(machine.phase == .paused(book))
  }

  // MARK: Starts

  @Test func aStartAsksThePhonePreparesAndPlays() {
    var machine = Machine()
    let ask = machine.handle(.play(book, .ready))
    guard case .starting(book, let attempt) = machine.phase else {
      Issue.record("not starting")
      return
    }
    #expect(ask == [.askPeer(book, attempt)])
    #expect(machine.handle(.peerAnswered(attempt, position: 42)) == [.prepare(book, handoffPosition: 42, attempt)])
    #expect(machine.handle(.prepared(attempt)) == [.playAudio(attempt)])
    #expect(machine.phase == .starting(book, attempt))
    #expect(
      machine.handle(.audioStarted(attempt)) == [.startListening, .startTicker, .publishPlaying(true), .clearMessage])
    #expect(machine.phase == .playing(book))
  }

  /// A failed start ends fully stopped, the bookmark untouched, with one message.
  @Test(arguments: [false, true])
  func aFailedStartEndsFullyStopped(afterPreparing: Bool) {
    var machine = Machine()
    _ = machine.handle(.play(book, .ready))
    let attempt = machine.phase.attempt!
    _ = machine.handle(.peerAnswered(attempt, position: nil))
    if afterPreparing { _ = machine.handle(.prepared(attempt)) }
    let effects = machine.handle(.failed(attempt, .failed))
    #expect(machine.phase == .idle)
    #expect(effects == release + [.show(.startFailed)])
    #expect(!effects.contains(.saveBookmark(atStart: false)) && !effects.contains(.saveBookmark(atStart: true)))
  }

  /// A cancelled start shows nothing.
  @Test func aCancelledStartShowsNothing() {
    var machine = Machine()
    _ = machine.handle(.play(book, .ready))
    let effects = machine.handle(.failed(machine.phase.attempt!, .cancelled))
    #expect(effects == release)
  }

  /// Once a pause has cancelled a start, nothing that start reports does anything.
  @Test func aPausedStartIgnoresItsLaterSteps() {
    var machine = Machine()
    _ = machine.handle(.play(book, .ready))
    let attempt = machine.phase.attempt!
    #expect(machine.handle(.pause(.listener)) == release)
    #expect(machine.handle(.peerAnswered(attempt, position: nil)).isEmpty)
    #expect(machine.handle(.prepared(attempt)).isEmpty)
    #expect(machine.handle(.audioStarted(attempt)).isEmpty)
    #expect(machine.phase == .idle)
  }

  // MARK: Resumes

  /// A catch-up shows a resuming phase, and the title plays once it has caught up.
  @Test func aResumeCatchesUpThenPlays() {
    var machine = Start.paused.machine()
    _ = machine.handle(.resume(.ready, bookmark: nil))
    guard case .resuming(book, let attempt, .catchUp) = machine.phase else {
      Issue.record("not resuming")
      return
    }
    #expect(machine.handle(.caughtUp(attempt)) == [.playAudio(attempt)])
    #expect(
      machine.handle(.audioStarted(attempt)) == [.startListening, .startTicker, .publishPlaying(true), .clearMessage])
    #expect(machine.phase == .playing(book))
  }

  @Test func aFailedResumeStaysPausedAndSaysSo() {
    var machine = Start.resuming.machine()
    let effects = machine.handle(.failed(machine.phase.attempt!, .failed))
    #expect(machine.phase == .paused(book))
    #expect(effects == pausing + [.show(.resumeFailed)])
  }

  // MARK: Seeks

  /// The seek lands paused at its target; the row records the target.
  @Test func aPauseDuringASeekLandsPausedAtTheTarget() {
    var machine = Start.seekingPlaying.machine()
    let attempt = machine.phase.attempt!
    _ = machine.handle(.pause(.listener))
    #expect(machine.handle(.seekFinished(attempt)) == [.recordSeek(to: 40)])
    #expect(machine.phase == .paused(book))
  }

  @Test func aFinishedSeekReturnsToPlaying() {
    var machine = Start.seekingPlaying.machine()
    #expect(machine.handle(.seekFinished(machine.phase.attempt!)) == [.recordSeek(to: 40)])
    #expect(machine.phase == .playing(book))
  }

  /// Three quick skips move three skips' worth; once the seek settles, the next skip starts
  /// from the position again.
  @Test func repeatedSkipsAccumulateUntilTheSeekSettles() {
    var machine = Start.playing.machine()
    _ = machine.handle(.skip(by: 30, position: 10, duration: 1_000))
    _ = machine.handle(.skip(by: 30, position: 11, duration: 1_000))
    _ = machine.handle(.skip(by: 30, position: 12, duration: 1_000))
    guard case .seeking(_, 100, true, let attempt) = machine.phase else {
      Issue.record("\(machine.phase)")
      return
    }
    _ = machine.handle(.seekFinished(attempt))
    _ = machine.handle(.skip(by: 30, position: 101, duration: 1_000))
    #expect(Shape(machine.phase) == .seeking(target: 131, resumeAfter: true))
  }

  /// Sync failures are the controller's; here a superseded seek says nothing and an
  /// unfinished one says so.
  @Test func aSeekFailureSaysSoUnlessCancelled() {
    var cancelled = Start.seekingPlaying.machine()
    #expect(cancelled.handle(.failed(cancelled.phase.attempt!, .cancelled)).isEmpty)
    #expect(cancelled.phase == .playing(book))
    var failed = Start.seekingPaused.machine()
    #expect(failed.handle(.failed(failed.phase.attempt!, .failed)) == [.show(.seekFailed)])
    #expect(failed.phase == .paused(book))
  }

  // MARK: Renewal

  /// The renewal is spent only once it succeeds; a failed renewal leaves one for later.
  @Test func aRenewalIsSpentOnlyOnceItSucceeds() {
    var machine = Start.renewing.machine()
    _ = machine.handle(.failed(machine.phase.attempt!, .failed))
    #expect(machine.phase == .paused(book))
    // The listener plays again, which starts the title afresh; that stream is refused too.
    _ = machine.handle(.resume(.ready, bookmark: nil))
    let restart = machine.phase.attempt!
    #expect(machine.phase == .starting(book, restart))
    _ = machine.handle(.peerAnswered(restart, position: nil))
    _ = machine.handle(.prepared(restart))
    _ = machine.handle(.audioStarted(restart))
    _ = machine.handle(.audioFailed(unauthorized: true, streaming: true))
    guard case .resuming(book, let attempt, .renewal) = machine.phase else {
      Issue.record("\(machine.phase)")
      return
    }
    #expect(machine.handle(.renewed(attempt)) == [.playAudio(attempt)])
    // The renewed stream failed again before it played: that is not a second renewal's job.
    let second = machine.handle(.audioFailed(unauthorized: true, streaming: true))
    #expect(machine.phase == .paused(book))
    #expect(second == pausing + [.show(.reconnectToStream)])
  }

  /// The allowance bounds consecutive failed renewals, so a long stream outliving several
  /// token lifetimes renews once per lifetime.
  @Test func aRenewalThatPlaysAgainLeavesTheNextOneAvailable() {
    var machine = Start.renewing.machine()
    for _ in 0..<3 {
      guard case .resuming(book, let attempt, .renewal) = machine.phase else {
        Issue.record("\(machine.phase)")
        return
      }
      #expect(machine.handle(.renewed(attempt)) == [.playAudio(attempt)])
      _ = machine.handle(.audioStarted(attempt))
      #expect(machine.phase == .playing(book))
      _ = machine.handle(.audioFailed(unauthorized: true, streaming: true))
    }
    #expect(Shape(machine.phase) == .resuming(book, .renewal))
  }

  /// Audio that failed cannot play again as it is: resuming it would report playing over silence.
  @Test func resumingAfterAFailureStartsTheTitleAfresh() {
    for unauthorized in [false, true] {
      var machine = Start.paused.machine()
      _ = machine.handle(.audioFailed(unauthorized: unauthorized, streaming: true))
      #expect(machine.phase == .paused(book))
      #expect(machine.handle(.resumeAfterInterruption) == [])
      let effects = machine.handle(.resume(.ready, bookmark: nil))
      guard case .starting(book, let attempt) = machine.phase else {
        Issue.record("\(machine.phase)")
        return
      }
      #expect(effects == teardown(finished: false) + [.askPeer(book, attempt)])
    }
    // A title that merely paused resumes where it is.
    var intact = Start.paused.machine()
    _ = intact.handle(.resume(.ready, bookmark: nil))
    #expect(Shape(intact.phase) == .resuming(book, .catchUp))
  }

  /// A lost stream may be a file the player gave up on, and a renewal that was paused never
  /// replaced the audio that failed: either way the next play loads the title again.
  @Test func resumingAfterALostStreamOrAnUnfinishedRenewalStartsTheTitleAfresh() {
    var stalled = Start.playing.machine()
    _ = stalled.handle(.stalled)
    var renewing = Start.renewing.machine()
    _ = renewing.handle(.pause(.listener))
    for var machine in [stalled, renewing] {
      #expect(machine.phase == .paused(book))
      _ = machine.handle(.resume(.ready, bookmark: nil))
      guard case .starting(book, _) = machine.phase else {
        Issue.record("\(machine.phase)")
        return
      }
    }
  }

  @Test func anAudioResetPausesWithoutBlamingTheDownloadAndReloadsOnResume() {
    var machine = Start.playing.machine()
    let effects = machine.handle(.audioReset)
    #expect(effects == pausing + [.show(.audioReset)])
    #expect(machine.phase == .paused(book))
    _ = machine.handle(.resume(.ready, bookmark: nil))
    guard case .starting(book, _) = machine.phase else {
      Issue.record("\(machine.phase)")
      return
    }
  }

  @Test func aFailedRenewalAsksToReconnect() {
    var machine = Start.renewing.machine()
    let effects = machine.handle(.failed(machine.phase.attempt!, .failed))
    #expect(effects == pausing + [.show(.reconnectToStream)])
  }

  @Test func aNewStartGivesTheStreamItsRenewalBack() {
    var machine = Start.renewing.machine()
    let attempt = machine.phase.attempt!
    _ = machine.handle(.renewed(attempt))
    _ = machine.handle(.audioStarted(attempt))
    _ = machine.handle(.play(other, .ready))
    let start = machine.phase.attempt!
    _ = machine.handle(.peerAnswered(start, position: nil))
    _ = machine.handle(.prepared(start))
    _ = machine.handle(.audioStarted(start))
    _ = machine.handle(.audioFailed(unauthorized: true, streaming: true))
    #expect(Shape(machine.phase) == .resuming(other, .renewal))
  }

  // MARK: Continue on iPhone

  /// The Watch unloads only once the phone accepts; otherwise it stays paused and says why.
  @Test func continueOnIPhoneUnloadsOnlyOnAcceptance() {
    var accepted = Start.handingOff.machine()
    #expect(
      accepted.handle(.continueAnswered(accepted.phase.attempt!, .accepted)) == teardown(finished: false) + [
        .requestUpload, .clearMessage,
      ])
    #expect(accepted.phase == .idle)

    var unavailable = Start.handingOff.machine()
    #expect(
      unavailable.handle(.continueAnswered(unavailable.phase.attempt!, .phoneUnavailable)) == [.show(.phoneUnavailable)]
    )
    #expect(unavailable.phase == .paused(book))

    var unreachable = Start.handingOff.machine()
    #expect(
      unreachable.handle(.continueAnswered(unreachable.phase.attempt!, .unreachable)) == [.show(.phoneUnreachable)])
    #expect(unreachable.phase == .paused(book))
  }

  // MARK: Native feeds (ADR 0019)

  /// A native-feed title plays only from a copy the phone sent; the machine is told about it
  /// because the wire never claims Watch playability for one.
  private func nativeMachine(playing: Bool = true) -> Machine {
    var machine = Machine()
    _ = machine.handle(.play(feed, .ready, hasLocalCopy: true))
    let attempt = machine.phase.attempt!
    _ = machine.handle(.prepared(attempt))
    _ = machine.handle(.audioStarted(attempt))
    if !playing { _ = machine.handle(.pause(.listener)) }
    return machine
  }

  @Test func aNativeFeedWithoutACopyAsksForThePhoneToSendIt() {
    var machine = Machine()
    #expect(machine.handle(.play(feed, .ready)) == [.show(.nativeFeed)])
    #expect(machine.phase == .idle)
  }

  @Test func aNativeFeedWithACopyPreparesLocallyWithoutAskingThePhone() {
    var machine = Machine()
    let effects = machine.handle(.play(feed, .ready, hasLocalCopy: true))
    guard case .starting(feed, let attempt) = machine.phase else {
      Issue.record("\(machine.phase)")
      return
    }
    #expect(effects == [.prepare(feed, handoffPosition: nil, attempt)])
    #expect(!effects.contains { if case .askPeer = $0 { true } else { false } })
    #expect(machine.handle(.prepared(attempt)) == [.playAudio(attempt)])
    #expect(
      machine.handle(.audioStarted(attempt)) == [.startListening, .startTicker, .publishPlaying(true), .clearMessage])
    #expect(machine.phase == .playing(feed))
  }

  @Test func aNativeStartSupersedesWhatWasLoaded() {
    var machine = Start.playing.machine()
    let effects = machine.handle(.play(feed, .ready, hasLocalCopy: true))
    guard case .starting(feed, let attempt) = machine.phase else {
      Issue.record("\(machine.phase)")
      return
    }
    #expect(effects == teardown(finished: false) + [.prepare(feed, handoffPosition: nil, attempt)])
  }

  @Test func aReadinessRefusalWinsOverALocalCopy() {
    var machine = Machine()
    #expect(machine.handle(.play(feed, .launching, hasLocalCopy: true)) == [.show(.launching)])
    #expect(machine.phase == .idle)
  }

  @Test func resumingAPausedNativeTitleReopensItsRowWithoutThePhoneOrCatchUp() {
    var machine = nativeMachine(playing: false)
    #expect(machine.phase == .paused(feed))
    let effects = machine.handle(.resume(.ready, bookmark: nil))
    guard case .resuming(feed, let attempt, .localCopy) = machine.phase else {
      Issue.record("\(machine.phase)")
      return
    }
    #expect(effects == [.reopenRow(attempt)])
    #expect(!effects.contains { if case .tellPeer = $0 { true } else { false } })
    #expect(machine.handle(.reopened(attempt)) == [.playAudio(attempt)])
    _ = machine.handle(.audioStarted(attempt))
    #expect(machine.phase == .playing(feed))
  }

  @Test func anInterruptionResumeOfANativeCopyDoesNotTellThePhone() {
    var machine = nativeMachine(playing: false)
    let effects = machine.handle(.resumeAfterInterruption)
    guard case .resuming(feed, let attempt, .interruption) = machine.phase else {
      Issue.record("\(machine.phase)")
      return
    }
    #expect(effects == [.reopenRow(attempt)])
  }

  @Test func resumingFromIdleWithANativeBookmarkNeedsACopy() {
    var without = Machine()
    #expect(without.handle(.resume(.ready, bookmark: feed)) == [.show(.nativeFeed)])
    #expect(without.phase == .idle)

    var with = Machine()
    let effects = with.handle(.resume(.ready, bookmark: feed, bookmarkHasLocalCopy: true))
    guard case .starting(feed, let attempt) = with.phase else {
      Issue.record("\(with.phase)")
      return
    }
    #expect(effects == [.prepare(feed, handoffPosition: nil, attempt)])
  }

  /// A full handoff cannot name a native feed, and the phone asks the Watch instead.
  @Test func continueOnIPhoneDoesNothingForANativeCopy() {
    for (playing, expected) in [(true, Machine.Phase.playing(feed)), (false, .paused(feed))] {
      var machine = nativeMachine(playing: playing)
      #expect(machine.handle(.continueOnPhone).isEmpty)
      #expect(machine.phase == expected)
    }
  }

  /// A local file has no token to renew: the same 401 that renews a stream pauses this with a
  /// message instead.
  @Test func aLocalCopyNeverRenews() {
    var machine = nativeMachine()
    let effects = machine.handle(.audioFailed(unauthorized: true, streaming: false))
    #expect(effects == pausing + [.show(.downloadFailed)])
    #expect(machine.phase == .paused(feed))
    #expect(!effects.contains { if case .renew = $0 { true } else { false } })
  }

  private static func attempt(of effect: Machine.Effect) -> Machine.Attempt? {
    switch effect {
    case .askPeer(_, let attempt), .prepare(_, _, let attempt), .catchUp(_, let attempt), .renew(_, let attempt),
      .playAudio(let attempt), .seekAudio(_, let attempt), .sendToPhone(_, let attempt):
      attempt
    default: nil
    }
  }
}
