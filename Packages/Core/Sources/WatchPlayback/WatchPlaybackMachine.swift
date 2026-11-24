import WatchProtocol

/// The Watch's local playback, as phases and the ordered effects each event asks for. The
/// controller performs the effects and reports what its asynchronous work did as completion
/// events carrying the `Attempt` that started it. A completion whose attempt is no longer current
/// produces no effects: whatever superseded it (a pause, stop, newer start, handoff or logout)
/// already asked for the release of what that attempt loaded, after it.
public struct WatchPlaybackMachine: Sendable, Equatable {
  /// One start, resume, seek, renewal or Continue on iPhone. Each is newer than every earlier one.
  public struct Attempt: Sendable, Hashable {
    public let id: Int
  }

  /// Why a resume is in flight: a paused title catching up and reopening its row, a stream
  /// renewing its authorization after a 401, or a title reloading from a Watch-local copy.
  public enum Resumption: Sendable, Equatable {
    case catchUp
    case renewal
    /// The end of an interruption that paused the title; no catch-up.
    case interruption
    /// A native-feed title playing from a local copy: its row reopens, but there is no server
    /// progress to catch up to and no phone to tell.
    case localCopy
  }

  public enum Phase: Sendable, Equatable {
    case idle
    case starting(WatchSelection, Attempt)
    case playing(WatchSelection)
    case paused(WatchSelection)
    case resuming(WatchSelection, Attempt, Resumption)
    case seeking(WatchSelection, target: Double, resumeAfter: Bool, Attempt)
    case handingOff(WatchSelection, Attempt)

    /// The title this phase concerns: shown as loaded from the moment a start is asked for.
    public var selection: WatchSelection? {
      switch self {
      case .idle: nil
      case .starting(let selection, _), .playing(let selection), .paused(let selection),
        .resuming(let selection, _, _), .seeking(let selection, _, _, _), .handingOff(let selection, _):
        selection
      }
    }

    /// Playback is wanted, whether or not it is audible yet.
    var wantsPlayback: Bool {
      switch self {
      case .playing, .resuming, .seeking(_, _, true, _): true
      case .idle, .starting, .paused, .seeking, .handingOff: false
      }
    }

    /// A start or playback is under way, audible or not: the screen shows loading and offers Pause.
    public var isStartingOrPlaying: Bool {
      if case .starting = self { return true }
      return wantsPlayback
    }

    public var attempt: Attempt? {
      switch self {
      case .idle, .playing, .paused: nil
      case .starting(_, let attempt), .resuming(_, let attempt, _), .seeking(_, _, _, let attempt),
        .handingOff(_, let attempt):
        attempt
      }
    }
  }

  public enum PauseSource: Sendable, Equatable {
    /// The listener, here or through a remote command.
    case listener
    /// The phone is starting: the bookmark is saved so the reply's position survives.
    case peer
  }

  public enum ContinueOutcome: Sendable, Equatable {
    case accepted
    case phoneUnavailable
    case unreachable
  }

  public enum Event: Sendable, Equatable {
    /// `hasLocalCopy` is the Watch's own evidence for a native-feed title (ADR 0019): the wire never
    /// claims Watch playability for one.
    case play(WatchSelection, WatchPlaybackReadiness, hasLocalCopy: Bool = false)
    /// `bookmark` is the retained title a resume with nothing loaded starts.
    /// `bookmarkHasLocalCopy` says whether that native-feed title is held on the Watch.
    case resume(WatchPlaybackReadiness, bookmark: WatchSelection?, bookmarkHasLocalCopy: Bool = false)
    case pause(PauseSource)
    case stop(finished: Bool)
    case seek(to: Double)
    /// A relative skip: `position` and `duration` are the engine's when the skip was asked for.
    case skip(by: Double, position: Double, duration: Double)
    case continueOnPhone
    case tick(checkpointDue: Bool)
    case audioEnded
    case audioFailed(unauthorized: Bool, streaming: Bool)
    case durationGrew(Double)
    /// The stream could not continue within the bound, or failed to play to the end.
    case stalled
    /// The system reset its audio services: the title is intact but must load again.
    case audioReset
    /// An interruption that paused the title ended with `shouldResume`.
    case resumeAfterInterruption

    case peerAnswered(Attempt, position: Double?)
    case prepared(Attempt)
    case caughtUp(Attempt)
    case renewed(Attempt)
    case reopened(Attempt)
    case audioStarted(Attempt)
    case seekFinished(Attempt)
    case continueAnswered(Attempt, ContinueOutcome)
    case failed(Attempt, WatchPlaybackFailure)
  }

  public enum Effect: Sendable, Equatable {
    /// Silences the audio at once; performed before anything is written.
    case pauseAudio
    case saveBookmark(atStart: Bool)
    /// Closes the open progress row; `ending` also unloads the title's progress.
    case closeRow(ending: Bool, finished: Bool, uploadAfter: Bool)
    case stopTicker
    /// Unloads the audio, clears Now Playing and deactivates the session.
    case stopAudio
    case publishPlaying(Bool)
    case requestUpload
    case show(WatchPlaybackNotice)
    case clearMessage
    /// Asks a phone that reports playing to pause, waiting only for its own title.
    case askPeer(WatchSelection, Attempt)
    /// Asks a phone that reports playing to pause, without waiting.
    case tellPeer(WatchSelection)
    /// Chooses the resume position (or the handed-over one), loads the audio and opens the row.
    case prepare(WatchSelection, handoffPosition: Double?, Attempt)
    /// Moves to newer listening elsewhere, not as a Watch listen, and reopens the row.
    case catchUp(WatchSelection, Attempt)
    case renew(WatchSelection, Attempt)
    /// Reopens the paused title's row for a resume that needs no catch-up; completes `reopened`.
    case reopenRow(Attempt)
    case playAudio(Attempt)
    /// Listening time counts from here, and the title was listened to now.
    case startListening
    case startTicker
    case seekAudio(to: Double, Attempt)
    case recordSeek(to: Double)
    case recordTick
    case checkpoint
    case sendToPhone(WatchSelection, Attempt)
    case growRow(to: Double)
  }

  public private(set) var phase: Phase = .idle
  private var lastAttempt = 0
  /// A renewal loaded and has not yet played again, so another 401 now is a renewal that did
  /// not help. Cleared once audio plays, which bounds consecutive failed renewals, not the stream's total.
  private var renewalSpent = false
  /// The loaded audio failed and cannot play again as it is: the next play starts the title afresh
  /// from where it stopped, which loads it again and gives a stream new authorization.
  private var audioBroken = false

  public init() {}

  public func isCurrent(_ attempt: Attempt) -> Bool { phase.attempt == attempt }

  public mutating func handle(_ event: Event) -> [Effect] {
    switch event {
    case .play(let selection, let readiness, let hasLocalCopy): play(selection, readiness, hasLocalCopy: hasLocalCopy)
    case .resume(let readiness, let bookmark, let bookmarkHasLocalCopy):
      resume(readiness, bookmark: bookmark, bookmarkHasLocalCopy: bookmarkHasLocalCopy)
    case .pause(let source): pause(source)
    case .stop(let finished): stop(finished: finished)
    case .seek(let target): seek(to: target)
    case .skip(let delta, let position, let duration): skip(by: delta, from: position, duration: duration)
    case .continueOnPhone: continueOnPhone()
    case .tick(let checkpointDue): tick(checkpointDue: checkpointDue)
    case .audioEnded: audioEnded()
    case .audioFailed(let unauthorized, let streaming): audioFailed(unauthorized: unauthorized, streaming: streaming)
    case .durationGrew(let duration): phase.selection == nil || !duration.isFinite ? [] : [.growRow(to: duration)]
    case .stalled: stalled()
    case .audioReset: audioReset()
    case .resumeAfterInterruption: resumeAfterInterruption()
    case .peerAnswered(let attempt, let position): peerAnswered(attempt, position: position)
    case .prepared(let attempt): isCurrentStart(attempt) ? [.playAudio(attempt)] : []
    case .caughtUp(let attempt), .renewed(let attempt), .reopened(let attempt): resumed(attempt)
    case .audioStarted(let attempt): audioStarted(attempt)
    case .seekFinished(let attempt): seekFinished(attempt)
    case .continueAnswered(let attempt, let outcome): continueAnswered(attempt, outcome)
    case .failed(let attempt, let failure): failed(attempt, failure)
    }
  }

  // MARK: Requests

  private mutating func play(
    _ selection: WatchSelection, _ readiness: WatchPlaybackReadiness, hasLocalCopy: Bool
  ) -> [Effect] {
    // A native-feed title without a copy is a permanent refusal, so it says so whatever the
    // readiness: the phone sends the copy. With one, it starts like any other local title.
    if case .nativeFeed = selection, !hasLocalCopy { return [.show(.nativeFeed)] }
    if let notice = readiness.refusal { return [.show(notice)] }
    let teardown = supersede()
    let attempt = nextAttempt()
    phase = .starting(selection, attempt)
    renewalSpent = false
    audioBroken = false
    // No Watch→phone pause for a native feed: the handoff request cannot name one, and the phone
    // asks the Watch to pause instead.
    if case .nativeFeed = selection { return teardown + [.prepare(selection, handoffPosition: nil, attempt)] }
    return teardown + [.askPeer(selection, attempt)]
  }

  private mutating func resume(
    _ readiness: WatchPlaybackReadiness, bookmark: WatchSelection?, bookmarkHasLocalCopy: Bool
  ) -> [Effect] {
    switch phase {
    case .paused(let selection):
      if audioBroken { return play(selection, readiness, hasLocalCopy: Self.loadedFromLocalCopy(selection)) }
      let attempt = nextAttempt()
      // A local copy has no server progress, and its row reopens without asking the phone.
      if case .nativeFeed = selection {
        phase = .resuming(selection, attempt, .localCopy)
        return [.reopenRow(attempt)]
      }
      phase = .resuming(selection, attempt, .catchUp)
      return [.tellPeer(selection), .catchUp(selection, attempt)]
    case .idle:
      if let bookmark { return play(bookmark, readiness, hasLocalCopy: bookmarkHasLocalCopy) }
      return [.show(readiness.refusal ?? .nothingToResume)]
    // A second tap while catching up does not start a second catch-up.
    case .starting, .playing, .resuming, .seeking, .handingOff:
      return []
    }
  }

  private mutating func pause(_ source: PauseSource) -> [Effect] {
    switch phase {
    case .idle, .handingOff:
      return []
    case .starting:
      phase = .idle
      return Self.release
    case .paused:
      return source == .peer ? [.saveBookmark(atStart: false)] : []
    case .playing(let selection):
      phase = .paused(selection)
      return Self.pausing(source)
    case .resuming(let selection, _, let resumption):
      phase = .paused(selection)
      // A renewal was replacing audio that had failed, and it did not finish.
      if resumption == .renewal { audioBroken = true }
      return Self.pausing(source)
    case .seeking(let selection, let target, _, let attempt):
      // The seek completes and lands paused at its target.
      phase = .seeking(selection, target: target, resumeAfter: false, attempt)
      return Self.pausing(source)
    }
  }

  private mutating func stop(finished: Bool) -> [Effect] {
    let teardown: [Effect]
    switch phase {
    case .idle: return []
    case .starting: teardown = Self.release
    case .playing, .paused, .resuming, .seeking, .handingOff:
      teardown = Self.teardown(finished: finished) + [.requestUpload]
    }
    phase = .idle
    return teardown
  }

  private mutating func seek(to target: Double) -> [Effect] {
    guard target.isFinite else { return [] }
    return seekTo(max(0, target))
  }

  private mutating func skip(by delta: Double, from position: Double, duration: Double) -> [Effect] {
    guard delta.isFinite, position.isFinite, duration.isFinite else { return [] }
    switch phase {
    case .playing, .paused, .seeking: break
    case .idle, .starting, .resuming, .handingOff: return []
    }
    // A skip during a seek builds on where that seek is going, not on the sampled position, so
    // three quick skips of 30 s move 90 s. Positions are global across a title's files.
    let base: Double = if case .seeking(_, let target, _, _) = phase { target } else { position }
    let target = min(max(0, base + delta), max(0, duration))
    // A skip onto the end finishes the title.
    if duration > 0, target >= duration { return stop(finished: true) }
    return seekTo(target)
  }

  private mutating func seekTo(_ target: Double) -> [Effect] {
    switch phase {
    case .playing(let selection), .paused(let selection):
      let attempt = nextAttempt()
      let resumeAfter = if case .playing = phase { true } else { false }
      phase = .seeking(selection, target: target, resumeAfter: resumeAfter, attempt)
      return [.recordTick, .seekAudio(to: target, attempt)]
    case .seeking(let selection, _, let resumeAfter, _):
      let attempt = nextAttempt()
      phase = .seeking(selection, target: target, resumeAfter: resumeAfter, attempt)
      return [.seekAudio(to: target, attempt)]
    case .idle, .starting, .resuming, .handingOff:
      return []
    }
  }

  private mutating func continueOnPhone() -> [Effect] {
    switch phase {
    case .playing(let selection), .paused(let selection):
      // A native-feed episode has no full phone handoff: the handoff cannot name it, and playback
      // is moved by asking the phone to start it instead. The Watch UI hides the action.
      if case .nativeFeed = selection { return [] }
      let attempt = nextAttempt()
      phase = .handingOff(selection, attempt)
      return Self.pausing(.peer) + [.sendToPhone(selection, attempt)]
    case .idle, .starting, .resuming, .seeking, .handingOff:
      return []
    }
  }

  private func tick(checkpointDue: Bool) -> [Effect] {
    guard case .playing = phase else { return [] }
    return [.recordTick, .saveBookmark(atStart: false)] + (checkpointDue ? [.checkpoint] : [])
  }

  private mutating func audioEnded() -> [Effect] {
    switch phase {
    case .playing, .seeking, .resuming: stop(finished: true)
    case .idle, .starting, .paused, .handingOff: []
    }
  }

  private mutating func audioFailed(unauthorized: Bool, streaming: Bool) -> [Effect] {
    switch phase {
    case .idle, .handingOff:
      return []
    case .starting:
      phase = .idle
      return Self.release + [.show(streaming ? .streamFailed : .downloadFailed)]
    case .paused:
      // Nobody is listening: the next play starts the title afresh, with no message now.
      audioBroken = true
      return []
    case .playing(let selection), .resuming(let selection, _, _), .seeking(let selection, _, _, _):
      if unauthorized, streaming, !renewalSpent {
        // A renewal ends in playing, so a title nobody asked to play stays paused without a
        // message: the next play starts it afresh.
        guard phase.wantsPlayback else {
          phase = .paused(selection)
          audioBroken = true
          return []
        }
        let attempt = nextAttempt()
        phase = .resuming(selection, attempt, .renewal)
        return [.recordTick, .renew(selection, attempt)]
      }
      phase = .paused(selection)
      audioBroken = true
      let notice: WatchPlaybackNotice = !streaming ? .downloadFailed : unauthorized ? .reconnectToStream : .streamFailed
      return Self.pausing(.listener) + [.show(notice)]
    }
  }

  private mutating func audioReset() -> [Effect] {
    switch phase {
    case .idle, .handingOff:
      return []
    case .starting:
      phase = .idle
      return Self.release + [.show(.startFailed)]
    case .paused:
      audioBroken = true
      return []
    case .playing(let selection), .resuming(let selection, _, _), .seeking(let selection, _, _, _):
      phase = .paused(selection)
      audioBroken = true
      return Self.pausing(.listener) + [.show(.audioReset)]
    }
  }

  /// A lost stream pauses with a message and closes the row; nothing retries.
  private mutating func stalled() -> [Effect] {
    switch phase {
    case .idle, .paused, .handingOff, .seeking(_, _, false, _):
      return []
    case .starting:
      phase = .idle
      return Self.release + [.show(.streamLost)]
    case .playing(let selection), .resuming(let selection, _, _), .seeking(let selection, _, true, _):
      phase = .paused(selection)
      // The player may have given up on the file for good, so the next play loads it again.
      audioBroken = true
      return Self.pausing(.listener) + [.show(.streamLost)]
    }
  }

  /// A plain resume of the title the interruption paused, never a bookmark.
  private mutating func resumeAfterInterruption() -> [Effect] {
    guard case .paused(let selection) = phase, !audioBroken else { return [] }
    let attempt = nextAttempt()
    phase = .resuming(selection, attempt, .interruption)
    // A local copy needs no phone pause and has no server progress to catch up to.
    if case .nativeFeed = selection { return [.reopenRow(attempt)] }
    return [.tellPeer(selection), .reopenRow(attempt)]
  }

  // MARK: Completions

  private func isCurrentStart(_ attempt: Attempt) -> Bool {
    if case .starting(_, attempt) = phase { true } else { false }
  }

  private func peerAnswered(_ attempt: Attempt, position: Double?) -> [Effect] {
    guard case .starting(let selection, attempt) = phase else { return [] }
    return [.prepare(selection, handoffPosition: position, attempt)]
  }

  private mutating func resumed(_ attempt: Attempt) -> [Effect] {
    guard case .resuming(_, attempt, let resumption) = phase else { return [] }
    if resumption == .renewal { renewalSpent = true }
    return [.playAudio(attempt)]
  }

  private mutating func audioStarted(_ attempt: Attempt) -> [Effect] {
    switch phase {
    case .starting(let selection, attempt), .resuming(let selection, attempt, _):
      renewalSpent = false
      phase = .playing(selection)
      return [.startListening, .startTicker, .publishPlaying(true), .clearMessage]
    default:
      return []
    }
  }

  private mutating func seekFinished(_ attempt: Attempt) -> [Effect] {
    guard case .seeking(let selection, let target, let resumeAfter, attempt) = phase else { return [] }
    phase = resumeAfter ? .playing(selection) : .paused(selection)
    return [.recordSeek(to: target)]
  }

  private mutating func continueAnswered(_ attempt: Attempt, _ outcome: ContinueOutcome) -> [Effect] {
    guard case .handingOff(let selection, attempt) = phase else { return [] }
    switch outcome {
    case .accepted:
      phase = .idle
      return Self.teardown(finished: false) + [.requestUpload, .clearMessage]
    case .phoneUnavailable:
      phase = .paused(selection)
      return [.show(.phoneUnavailable)]
    case .unreachable:
      phase = .paused(selection)
      return [.show(.phoneUnreachable)]
    }
  }

  private mutating func failed(_ attempt: Attempt, _ failure: WatchPlaybackFailure) -> [Effect] {
    guard isCurrent(attempt) else { return [] }
    let notice: (WatchPlaybackNotice) -> [Effect] = { failure.showsMessage ? [.show($0)] : [] }
    switch phase {
    case .idle, .playing, .paused:
      return []
    case .starting:
      // A failed start ends fully stopped, the bookmark untouched, with one message.
      phase = .idle
      return Self.release + notice(.startFailed)
    case .resuming(let selection, _, let resumption):
      phase = .paused(selection)
      // A renewal was replacing audio that had failed; any other resume found it intact.
      if resumption == .renewal { audioBroken = true }
      return Self.pausing(.listener) + notice(resumption == .renewal ? .reconnectToStream : .resumeFailed)
    case .seeking(let selection, _, let resumeAfter, _):
      phase = resumeAfter ? .playing(selection) : .paused(selection)
      return notice(.seekFailed)
    case .handingOff(let selection, _):
      phase = .paused(selection)
      return notice(.phoneUnreachable)
    }
  }

  // MARK: Effect lists

  private mutating func nextAttempt() -> Attempt {
    lastAttempt &+= 1
    return Attempt(id: lastAttempt)
  }

  /// A native-feed title can only be loaded here through a local copy: nothing else reaches a
  /// phase holding one, so restarting it restarts locally.
  private static func loadedFromLocalCopy(_ selection: WatchSelection) -> Bool {
    if case .nativeFeed = selection { true } else { false }
  }

  /// What a newer start does to the current phase before it begins.
  private func supersede() -> [Effect] {
    switch phase {
    case .idle: []
    case .starting: Self.release
    case .playing, .paused, .resuming, .seeking, .handingOff: Self.teardown(finished: false)
    }
  }

  /// Keeps the title loaded and paused, with no open row.
  private static func pausing(_ source: PauseSource) -> [Effect] {
    [.pauseAudio] + (source == .peer ? [.saveBookmark(atStart: false)] : [])
      + [.closeRow(ending: false, finished: false, uploadAfter: true), .stopTicker, .publishPlaying(false)]
  }

  /// One teardown for a stop, an accepted Continue on iPhone and the end of a title. Audio goes
  /// first, and the bookmark is taken while the position is still the title's.
  private static func teardown(finished: Bool) -> [Effect] {
    [
      .pauseAudio, .saveBookmark(atStart: finished), .closeRow(ending: true, finished: finished, uploadAfter: false),
      .stopTicker, .stopAudio, .publishPlaying(false),
    ]
  }

  /// Unloads whatever a start that did not finish loaded, leaving the bookmark untouched.
  private static let release: [Effect] = [
    .pauseAudio, .closeRow(ending: true, finished: false, uploadAfter: false), .stopTicker, .stopAudio,
    .publishPlaying(false),
  ]
}
