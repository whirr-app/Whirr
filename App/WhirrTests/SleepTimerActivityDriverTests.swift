import Foundation
import Observation
import PlayerCore
import TestSupport
import Testing
import WidgetProtocol

@testable import Whirr

/// Each test pins one of the plan's "Sleep timer facts" against the driver.
@MainActor
@Suite("Sleep-timer Live Activity driver", .serialized)
struct SleepTimerActivityDriverTests {
  @Test("a countdown set while playing starts a running, extendable activity")
  func countdownStarts() async throws {
    let harness = Harness()
    harness.set(timer: .countdown(remainingSeconds: 900), playing: true)
    await harness.settle()

    let state = try #require(harness.sink.started.last)
    #expect(state.label == .countdown)
    #expect(state.isRunning)
    #expect(state.endsAt == harness.clock.now.addingTimeInterval(900))
    #expect(state.canExtend)
    #expect(state.isFading == false)
    #expect(harness.sink.updates.isEmpty)
  }

  @Test("playing ticks that keep the end time within tolerance send nothing")
  func ticksAreQuiet() async throws {
    let harness = Harness()
    harness.set(timer: .countdown(remainingSeconds: 900), playing: true)
    await harness.settle()

    // Background ticks: 2 s of wall clock, 2 s off the countdown, plus up to a tick of lag.
    for step in 1...20 {
      harness.clock.now.addTimeInterval(2)
      harness.set(timer: .countdown(remainingSeconds: 900 - Double(step) * 2 + 1), playing: true)
      await harness.settle()
    }

    #expect(harness.sink.updates.isEmpty)
  }

  @Test("a seek's brief spell out of playing does not stop the clock")
  func seekIsSmoothedOver() async throws {
    let harness = Harness()
    harness.set(timer: .countdown(remainingSeconds: 900), playing: true)
    await harness.settle()

    harness.set(timer: .countdown(remainingSeconds: 900), playing: false)
    await harness.settle()
    #expect(harness.holds.pending == 1)
    harness.set(timer: .countdown(remainingSeconds: 900), playing: true)
    await harness.settle()

    #expect(harness.holds.pending == 0, "returning to playing cancels the hold")
    #expect(harness.sink.updates.isEmpty)
  }

  @Test("a pause longer than the hold freezes the activity at the time left")
  func pauseFreezes() async throws {
    let harness = Harness()
    harness.set(timer: .countdown(remainingSeconds: 900), playing: true)
    await harness.settle()

    harness.clock.now.addTimeInterval(28)
    harness.set(timer: .countdown(remainingSeconds: 872), playing: false)
    await harness.settle()
    #expect(harness.sink.updates.isEmpty, "still inside the hold")
    harness.holds.fireAll()

    let paused = try #require(harness.sink.updates.last)
    #expect(paused.isRunning == false)
    #expect(paused.endsAt == nil)
    #expect(paused.remainingSeconds == 872)
  }

  @Test("a countdown is wall-clock listening time: a rate change does not move it")
  func countdownIgnoresRate() async throws {
    let harness = Harness()
    harness.set(timer: .countdown(remainingSeconds: 900), playing: true)
    await harness.settle()

    harness.set(timer: .countdown(remainingSeconds: 900), playing: true, rate: 2)
    await harness.settle()

    #expect(harness.sink.updates.isEmpty)
  }

  @Test("end of chapter counts media time at the current rate and follows rate changes and seeks")
  func endOfChapterFollowsRateAndSeeks() async throws {
    let harness = Harness()
    harness.set(timer: .endOfChapter(atPosition: 1_000), playing: true, position: 400, total: 5_000)
    await harness.settle()
    let started = try #require(harness.sink.started.last)
    #expect(started.label == .endOfChapter)
    #expect(started.canExtend == false)
    #expect(started.endsAt == harness.clock.now.addingTimeInterval(600))

    // Ordinary playing ticks move position and clock together: nothing to send.
    harness.clock.now.addTimeInterval(10)
    harness.set(timer: .endOfChapter(atPosition: 1_000), playing: true, position: 410, total: 5_000)
    await harness.settle()
    #expect(harness.sink.updates.isEmpty)

    harness.set(timer: .endOfChapter(atPosition: 1_000), playing: true, position: 410, total: 5_000, rate: 2)
    await harness.settle()
    #expect(harness.sink.updates.last?.endsAt == harness.clock.now.addingTimeInterval(295))

    harness.set(timer: .endOfChapter(atPosition: 1_000), playing: true, position: 900, total: 5_000, rate: 2)
    await harness.settle()
    #expect(harness.sink.updates.last?.endsAt == harness.clock.now.addingTimeInterval(50))
  }

  @Test("an end position at the item's end is the end of the book or episode")
  func endOfItemLabels() {
    let book = SleepTimerActivityInput(
      timer: .endOfChapter(atPosition: 5_000), isPlaying: true, globalPosition: 0,
      totalDuration: 5_000.5, isEpisode: false, rate: 1)
    var episode = book
    episode.isEpisode = true
    var chapter = book
    chapter.timer = .endOfChapter(atPosition: 4_000)

    #expect(SleepTimerActivityDerivation.label(atPosition: 5_000, input: book) == .endOfBook)
    #expect(SleepTimerActivityDerivation.label(atPosition: 5_000, input: episode) == .endOfEpisode)
    #expect(SleepTimerActivityDerivation.label(atPosition: 4_000, input: chapter) == .endOfChapter)
  }

  @Test("an extension updates the activity on screen")
  func extensionUpdates() async throws {
    let harness = Harness()
    harness.set(timer: .countdown(remainingSeconds: 300), playing: true)
    await harness.settle()

    harness.set(timer: .countdown(remainingSeconds: 1_200), playing: true)
    await harness.settle()

    #expect(harness.sink.started.count == 1)
    #expect(harness.sink.updates.last?.remainingSeconds == 1_200)
  }

  @Test("the last fade window of a countdown is marked, once")
  func fadeIsMarked() async throws {
    let harness = Harness()
    harness.set(timer: .countdown(remainingSeconds: 20), playing: true)
    await harness.settle()

    harness.clock.now.addTimeInterval(6)
    harness.set(timer: .countdown(remainingSeconds: 14), playing: true)
    await harness.settle()
    harness.clock.now.addTimeInterval(2)
    harness.set(timer: .countdown(remainingSeconds: 12), playing: true)
    await harness.settle()

    #expect(harness.sink.updates.count == 1)
    #expect(harness.sink.updates.last?.isFading == true)
  }

  @Test("the activity ends whenever the timer goes off, whatever turned it off")
  func offEnds() async throws {
    let harness = Harness()
    harness.set(timer: .countdown(remainingSeconds: 900), playing: true)
    await harness.settle()
    let endsAtStart = harness.sink.endAllCount

    // Expiry, cancel, a new load and a stop all leave the timer off; the driver cannot tell them
    // apart and does not need to.
    harness.set(timer: .off, playing: false)
    await harness.settle()

    #expect(harness.sink.endAllCount == endsAtStart + 1)
    #expect(harness.sink.hasActivity == false)
  }

  @Test("starting ends an activity a previous process left behind")
  func startEndsLeftovers() {
    let sink = FakeSink()
    let driver = SleepTimerActivityDriver(
      read: { .off }, sink: sink, now: { Date(timeIntervalSince1970: 0) },
      scheduleHold: { _, _ in Task {} })

    driver.start()

    #expect(sink.endAllCount == 1)
    #expect(sink.started.isEmpty)
  }

  @Test("with Live Activities turned off, nothing starts")
  func disabledStartsNothing() async throws {
    let harness = Harness()
    harness.sink.enabled = false
    harness.set(timer: .countdown(remainingSeconds: 900), playing: true)
    await harness.settle()
    harness.driver.reconcile()

    #expect(harness.sink.started.isEmpty)
    #expect(harness.sink.startAttempts == 0)
  }

  @Test("a start refused in the background is retried at the next foreground, not every tick")
  func refusedStartWaitsForForeground() async throws {
    let harness = Harness()
    harness.sink.startSucceeds = false
    harness.set(timer: .countdown(remainingSeconds: 900), playing: true)
    await harness.settle()
    #expect(harness.sink.startAttempts == 1)

    harness.clock.now.addTimeInterval(2)
    harness.set(timer: .countdown(remainingSeconds: 898), playing: true)
    await harness.settle()
    #expect(harness.sink.startAttempts == 1)

    harness.sink.startSucceeds = true
    harness.driver.reconcile()
    #expect(harness.sink.started.count == 1)
    #expect(harness.sink.started.last?.remainingSeconds == 898)
  }

  @Test("a dismissed activity stays dismissed until a new timer is set")
  func dismissalIsRespectedUntilANewTimer() async throws {
    let harness = Harness()
    harness.set(timer: .countdown(remainingSeconds: 900), playing: true)
    await harness.settle()
    harness.sink.hasActivity = false

    harness.clock.now.addTimeInterval(60)
    harness.set(timer: .countdown(remainingSeconds: 840), playing: false)
    await harness.settle()
    harness.holds.fireAll()
    #expect(harness.sink.started.count == 1)

    harness.set(timer: .endOfChapter(atPosition: 100), playing: true, position: 0, total: 1_000)
    await harness.settle()
    #expect(harness.sink.started.count == 2)
  }

  @Test("logout ends the activity at once")
  func logoutEnds() async throws {
    let harness = Harness()
    harness.set(timer: .countdown(remainingSeconds: 900), playing: true)
    await harness.settle()

    harness.driver.endForLogout()

    #expect(harness.sink.hasActivity == false)
  }

  @Test("the playback hardware drives the activity for its player, and ends it on logout")
  func hardwareOwnsTheDriver() {
    let sink = FakeSink()
    let hardware = PlaybackHardware(
      remoteCommandCenter: FakeRemoteCommandRegistering(), sleepTimerActivitySink: sink)
    #expect(hardware.sleepTimerActivity != nil)
    #expect(sink.endAllCount == 1, "an activity a previous process left behind is ended at once")

    hardware.prepareForLogout()

    #expect(sink.endAllCount == 2)
    #expect(PlaybackHardware(remoteCommandCenter: FakeRemoteCommandRegistering()).sleepTimerActivity == nil)
  }

  @Test("material change: label, running, extendability, fading, or more than 2 s of end time")
  func materialChange() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let base = try SleepTimerActivityAttributes.ContentState(
      label: .countdown, isRunning: true, endsAt: now, remainingSeconds: 100, canExtend: true,
      isFading: false)
    let nudged = try SleepTimerActivityAttributes.ContentState(
      label: .countdown, isRunning: true, endsAt: now.addingTimeInterval(2), remainingSeconds: 98,
      canExtend: true, isFading: false)
    let moved = try SleepTimerActivityAttributes.ContentState(
      label: .countdown, isRunning: true, endsAt: now.addingTimeInterval(2.5), remainingSeconds: 98,
      canExtend: true, isFading: false)

    #expect(SleepTimerActivityDerivation.isMaterialChange(from: base, to: nudged) == false)
    #expect(SleepTimerActivityDerivation.isMaterialChange(from: base, to: moved))
    #expect(SleepTimerActivityDerivation.isMaterialChange(from: nil, to: base))
    #expect(SleepTimerActivityDerivation.isMaterialChange(from: base, to: nil))
    #expect(SleepTimerActivityDerivation.isMaterialChange(from: nil, to: nil) == false)
  }
}

// MARK: Fixtures

@MainActor
@Observable
private final class FakeTimerSource {
  var input = SleepTimerActivityInput.off
}

@MainActor
private final class FakeClock {
  var now = Date(timeIntervalSince1970: 1_000_000)
}

@MainActor
private final class FakeHolds {
  private var expirations: [@MainActor () -> Void] = []
  private var tasks: [Task<Void, Never>] = []

  var pending: Int {
    zip(expirations, tasks).filter { !$0.1.isCancelled }.count
  }

  func schedule(_ duration: Duration, _ expire: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    let task = Task<Void, Never> {}
    expirations.append(expire)
    tasks.append(task)
    return task
  }

  func fireAll() {
    let due = zip(expirations, tasks).filter { !$0.1.isCancelled }.map(\.0)
    expirations = []
    tasks = []
    for expire in due { expire() }
  }
}

@MainActor
private final class FakeSink: SleepTimerActivitySink {
  var enabled = true
  var startSucceeds = true
  var hasActivity = false
  private(set) var started: [SleepTimerActivityAttributes.ContentState] = []
  private(set) var updates: [SleepTimerActivityAttributes.ContentState] = []
  private(set) var startAttempts = 0
  private(set) var endAllCount = 0

  var areActivitiesEnabled: Bool { enabled }

  func start(_ state: SleepTimerActivityAttributes.ContentState) -> Bool {
    startAttempts += 1
    guard startSucceeds else { return false }
    started.append(state)
    hasActivity = true
    return true
  }

  func update(_ state: SleepTimerActivityAttributes.ContentState) {
    updates.append(state)
  }

  func endAll() {
    endAllCount += 1
    hasActivity = false
  }
}

@MainActor
private final class Harness {
  let source = FakeTimerSource()
  let clock = FakeClock()
  let holds = FakeHolds()
  let sink = FakeSink()
  let driver: SleepTimerActivityDriver

  init() {
    let source = source
    let clock = clock
    let holds = holds
    driver = SleepTimerActivityDriver(
      read: { source.input }, sink: sink, now: { clock.now },
      scheduleHold: { holds.schedule($0, $1) })
    driver.start()
  }

  func set(
    timer: SleepTimerMode, playing: Bool, position: Double = 0, total: Double? = 10_000,
    episode: Bool = false, rate: Double = 1
  ) {
    source.input = SleepTimerActivityInput(
      timer: timer, isPlaying: playing, globalPosition: position, totalDuration: total,
      isEpisode: episode, rate: rate)
  }

  /// The driver re-reads on the main actor after an observation fires; this waits for it to have
  /// read the value just set.
  func settle() async {
    await waitUntil("driver observed the input") { driver.observedInput == source.input }
  }
}
