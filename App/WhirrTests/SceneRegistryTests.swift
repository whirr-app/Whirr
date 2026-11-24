import SwiftUI
import Testing

@testable import Whirr

/// `SceneRegistry` aggregates the phone and CarPlay scenes into one process lifecycle. Each test
/// drives it with scene reports, then reads back which effects fired and in what order.
@MainActor
@Suite("Scene registry")
struct SceneRegistryTests {
  private let phone = SceneRegistry.SceneID(role: .phone, session: "phone")
  private let car = SceneRegistry.SceneID(role: .car, session: "car")

  @Test("a phone scene alone behaves as the single phase variable did")
  func phoneOnly() {
    let log = Log()
    let registry = SceneRegistry(effects: log.effects)

    registry.report(.active, for: phone)
    registry.report(.inactive, for: phone)
    registry.report(.background, for: phone)

    #expect(
      log.events == [
        .lifecycle(.active), .phone(.active), .phoneActive, .anyActive,
        .lifecycle(.inactive), .phone(.inactive),
        .lifecycle(.background), .phone(.background), .allBackground,
      ])
  }

  @Test("a bounce through inactive reports active again, as the lifecycle mapper relies on")
  func inactiveBounceReportsActiveAgain() {
    let log = Log()
    let registry = SceneRegistry(effects: log.effects)
    registry.report(.active, for: phone)
    log.events.removeAll()

    registry.report(.inactive, for: phone)
    registry.report(.active, for: phone)

    #expect(
      log.events == [
        .lifecycle(.inactive), .phone(.inactive),
        .lifecycle(.active), .phone(.active), .phoneActive, .anyActive,
      ])
  }

  @Test("repeating a scene's phase fires nothing")
  func repeatedPhaseIsSilent() {
    let log = Log()
    let registry = SceneRegistry(effects: log.effects)
    registry.report(.active, for: phone)
    log.events.removeAll()

    registry.report(.active, for: phone)

    #expect(log.events.isEmpty)
  }

  @Test("a scene that launches into the background schedules nothing")
  func launchingBackgroundedIsNotAnEntryToBackground() {
    let log = Log()
    let registry = SceneRegistry(effects: log.effects)

    registry.report(.background, for: phone)

    #expect(log.events == [.lifecycle(.background), .phone(.background)])
  }

  @Test("a car-only drive is foreground for the process and runs no phone-only work")
  func carOnly() {
    let log = Log()
    let registry = SceneRegistry(effects: log.effects)

    registry.report(.inactive, for: car)
    registry.report(.active, for: car)
    registry.report(.background, for: car)

    #expect(
      log.events == [
        .carWithoutPhone, .lifecycle(.inactive),
        .lifecycle(.active), .anyActive,
        .lifecycle(.background), .allBackground,
      ])
  }

  @Test("the phone backgrounding under an active car scene does not background the process")
  func phoneBackgroundsUnderActiveCar() {
    let log = Log()
    let registry = SceneRegistry(effects: log.effects)
    registry.report(.active, for: phone)
    registry.report(.active, for: car)
    log.events.removeAll()

    registry.report(.inactive, for: phone)
    registry.report(.background, for: phone)

    #expect(log.events == [.phone(.inactive), .phone(.background)])
    #expect(registry.phase == .active)
  }

  @Test("a second scene becoming active fires the process-wide work once")
  func secondActiveSceneDoesNotRefire() {
    let log = Log()
    let registry = SceneRegistry(effects: log.effects)
    registry.report(.active, for: car)
    log.events.removeAll()

    registry.report(.active, for: phone)

    #expect(log.events == [.phone(.active), .phoneActive])
  }

  @Test("the phone returning under an active car scene restores only the phone's own work")
  func phoneReturnsUnderActiveCar() {
    let log = Log()
    let registry = SceneRegistry(effects: log.effects)
    registry.report(.active, for: phone)
    registry.report(.active, for: car)
    registry.report(.background, for: phone)
    log.events.removeAll()

    registry.report(.active, for: phone)

    #expect(log.events == [.phone(.active), .phoneActive])
  }

  @Test("a car scene joining a phone scene claims nothing for a phone-less process")
  func carJoiningPhoneIsNotHeadless() {
    let log = Log()
    let registry = SceneRegistry(effects: log.effects)
    registry.report(.active, for: phone)
    log.events.removeAll()

    registry.report(.inactive, for: car)

    #expect(log.events.isEmpty)
  }

  @Test("the process backgrounds only when the last scene does")
  func backgroundWaitsForTheLastScene() {
    let log = Log()
    let registry = SceneRegistry(effects: log.effects)
    registry.report(.active, for: phone)
    registry.report(.active, for: car)
    registry.report(.background, for: phone)
    log.events.removeAll()

    registry.report(.background, for: car)

    #expect(log.events == [.lifecycle(.background), .allBackground])
  }

  @Test("disconnecting the car while the phone is active changes nothing")
  func carDisconnectsUnderActivePhone() {
    let log = Log()
    let registry = SceneRegistry(effects: log.effects)
    registry.report(.active, for: phone)
    registry.report(.active, for: car)
    log.events.removeAll()

    registry.disconnect(car)

    #expect(log.events.isEmpty)
    #expect(registry.phase == .active)
  }

  @Test("disconnecting the only scene while it is active backgrounds the process")
  func disconnectingTheOnlyActiveScene() {
    let log = Log()
    let registry = SceneRegistry(effects: log.effects)
    registry.report(.active, for: car)
    log.events.removeAll()

    registry.disconnect(car)

    #expect(log.events == [.lifecycle(.background), .allBackground])
    #expect(registry.phase == nil)
  }

  @Test("disconnecting an already backgrounded scene, or an unknown one, fires nothing")
  func disconnectingABackgroundedScene() {
    let log = Log()
    let registry = SceneRegistry(effects: log.effects)
    registry.report(.active, for: car)
    registry.report(.background, for: car)
    log.events.removeAll()

    registry.disconnect(car)
    registry.disconnect(phone)

    #expect(log.events.isEmpty)
  }

  @Test("a reconnecting car scene is a fresh phone-less entry")
  func carReconnects() {
    let log = Log()
    let registry = SceneRegistry(effects: log.effects)
    registry.report(.active, for: car)
    registry.disconnect(car)
    log.events.removeAll()

    registry.report(.active, for: car)

    #expect(log.events == [.carWithoutPhone, .lifecycle(.active), .anyActive])
  }
}

@MainActor
private final class Log {
  enum Event: Equatable {
    case lifecycle(ScenePhase)
    case phone(ScenePhase)
    case carWithoutPhone
    case anyActive
    case phoneActive
    case allBackground
  }

  var events: [Event] = []

  var effects: SceneRegistry.Effects {
    SceneRegistry.Effects(
      lifecyclePhase: { self.events.append(.lifecycle($0)) },
      phoneScenePhase: { self.events.append(.phone($0)) },
      carConnectedWithoutPhone: { self.events.append(.carWithoutPhone) },
      anySceneBecameActive: { self.events.append(.anyActive) },
      phoneSceneBecameActive: { self.events.append(.phoneActive) },
      allScenesEnteredBackground: { self.events.append(.allBackground) })
  }
}
