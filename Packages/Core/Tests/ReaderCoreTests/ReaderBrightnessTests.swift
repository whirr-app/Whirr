import Testing

@testable import ReaderCore

@MainActor
@Suite("Reader brightness")
struct ReaderBrightnessTests {

  @Test("entering the reader does not capture or write brightness")
  func enteringTheReaderDoesNotCaptureOrWriteBrightness() {
    let screen = FakeScreen(brightness: 0.72)
    let store = FakeStore()
    let controller = ReaderBrightnessController(screen: screen, store: store)

    controller.enterReader()

    #expect(controller.isOverriding == false)
    #expect(controller.overrideLevel == nil)
    #expect(screen.events.isEmpty)
    #expect(store.events.isEmpty)
  }

  @Test("the borrowed level is saved before the screen is overridden and levels are clamped")
  func borrowedLevelIsSavedBeforeScreenIsOverriddenAndLevelsAreClamped() {
    let timeline = EventTimeline()
    let screen = FakeScreen(brightness: 0.72, timeline: timeline)
    let store = FakeStore(timeline: timeline)
    let controller = ReaderBrightnessController(screen: screen, store: store)

    controller.setOverride(2.0)

    #expect(
      timeline.events == [
        .screenRead,
        .storeSave(0.72),
        .screenWrite(1.0),
      ])
    #expect(controller.overrideLevel == 1.0)
    #expect(controller.isOverriding)
    #expect(store.borrowedLevel == 0.72)
  }

  @Test("the user's brightness is captured once across override changes and lifecycle cycles")
  func usersBrightnessIsCapturedOnceAcrossOverrideChangesAndLifecycleCycles() {
    let timeline = EventTimeline()
    let screen = FakeScreen(brightness: 0.72, timeline: timeline)
    let store = FakeStore(timeline: timeline)
    let controller = ReaderBrightnessController(screen: screen, store: store)

    controller.enterReader()
    controller.setOverride(0.20)
    controller.willResignActive()
    controller.didBecomeActive()
    controller.setOverride(0.08)
    controller.leaveReader()

    #expect(
      timeline.events == [
        .screenRead,
        .storeSave(0.72),
        .screenWrite(0.20),
        .screenWrite(0.72),
        .screenWrite(0.20),
        .screenWrite(0.08),
        .screenWrite(0.72),
        .storeSave(nil),
      ])
    #expect(screen.readCount == 1)
    #expect(screen.brightness == 0.72)
    #expect(store.borrowedLevel == nil)
    #expect(controller.overrideLevel == nil)
    #expect(controller.isOverriding == false)
  }

  @Test("background restoration keeps the borrow until foreground re-applies the override")
  func backgroundRestorationKeepsTheBorrowUntilForegroundReappliesTheOverride() {
    let timeline = EventTimeline()
    let screen = FakeScreen(brightness: 0.61, timeline: timeline)
    let store = FakeStore(timeline: timeline)
    let controller = ReaderBrightnessController(screen: screen, store: store)

    controller.enterReader()
    controller.setOverride(0.15)
    timeline.events.removeAll()

    controller.willResignActive()
    #expect(timeline.events == [.screenWrite(0.61)])
    #expect(store.borrowedLevel == 0.61)
    #expect(controller.overrideLevel == 0.15)

    timeline.events.removeAll()
    controller.didBecomeActive()
    #expect(timeline.events == [.screenWrite(0.15)])
    #expect(screen.readCount == 1)
    #expect(store.borrowedLevel == 0.61)
  }

  @Test("restoring writes the screen before clearing the durable borrow")
  func restoringWritesTheScreenBeforeClearingTheDurableBorrow() {
    let timeline = EventTimeline()
    let screen = FakeScreen(brightness: 0.83, timeline: timeline)
    let store = FakeStore(timeline: timeline)
    let controller = ReaderBrightnessController(screen: screen, store: store)

    controller.setOverride(0.08)
    timeline.events.removeAll()

    controller.clearOverride()

    #expect(timeline.events == [.screenWrite(0.83), .storeSave(nil)])
    #expect(screen.brightness == 0.83)
    #expect(store.borrowedLevel == nil)

    timeline.events.removeAll()
    controller.clearOverride()
    #expect(timeline.events.isEmpty)
  }

  @Test("stranded brightness recovery restores before clearing and is idempotent")
  func strandedBrightnessRecoveryRestoresBeforeClearingAndIsIdempotent() {
    let timeline = EventTimeline()
    let screen = FakeScreen(brightness: 0.08, timeline: timeline)
    let store = FakeStore(borrowedLevel: 0.76, timeline: timeline)
    let controller = ReaderBrightnessController(screen: screen, store: store)

    controller.recoverStrandedBrightness()

    #expect(
      timeline.events == [
        .storeLoad,
        .screenWrite(0.76),
        .storeSave(nil),
      ])
    #expect(screen.brightness == 0.76)
    #expect(store.borrowedLevel == nil)

    timeline.events.removeAll()
    controller.recoverStrandedBrightness()

    #expect(timeline.events.isEmpty)
    #expect(screen.brightness == 0.76)
    #expect(store.borrowedLevel == nil)
  }
}

@MainActor
private final class EventTimeline {
  var events: [ReaderBrightnessEvent] = []
}

private enum ReaderBrightnessEvent: Equatable {
  case screenRead
  case screenWrite(Double)
  case storeLoad
  case storeSave(Double?)
}

@MainActor
private final class FakeScreen: ReaderScreenBrightnessControlling {
  private var storedBrightness: Double
  private let timeline: EventTimeline
  private(set) var readCount = 0

  init(brightness: Double, timeline: EventTimeline = EventTimeline()) {
    storedBrightness = brightness
    self.timeline = timeline
  }

  var brightness: Double {
    get {
      timeline.events.append(.screenRead)
      readCount += 1
      return storedBrightness
    }
    set {
      timeline.events.append(.screenWrite(newValue))
      storedBrightness = newValue
    }
  }

  var events: [ReaderBrightnessEvent] { timeline.events }
}

@MainActor
private final class FakeStore: ReaderBrightnessStoring {
  private(set) var borrowedLevel: Double?
  private let timeline: EventTimeline

  init(borrowedLevel: Double? = nil, timeline: EventTimeline = EventTimeline()) {
    self.borrowedLevel = borrowedLevel
    self.timeline = timeline
  }

  func loadBorrowedSystemBrightness() -> Double? {
    timeline.events.append(.storeLoad)
    return borrowedLevel
  }

  func saveBorrowedSystemBrightness(_ level: Double?) {
    timeline.events.append(.storeSave(level))
    borrowedLevel = level
  }

  var events: [ReaderBrightnessEvent] { timeline.events }
}
