import Foundation
import Persistence
import Synchronization
import TestSupport
import Testing

@testable import AppModel

/// One show's Voice Boost setting as the show settings page and the speed card's tick row see
/// it.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ShowVoiceBoostModelTests {
  final class FakeSettings: VoiceBoostShowSettingsReading, VoiceBoostShowSettingsWriting {
    let stored = Mutex<[String: VoiceBoostShowOverride]>([:])
    let writes = Mutex<[VoiceBoostShowOverride]>([])
    let changes = AsyncStream.makeStream(of: [String: VoiceBoostShowOverride].self)

    init(_ values: [String: VoiceBoostShowOverride] = [:]) {
      stored.withLock { $0 = values }
      changes.continuation.yield(values)
    }

    func fetchVoiceBoostOverrides() async throws -> [String: VoiceBoostShowOverride] {
      stored.withLock { $0 }
    }

    func observeVoiceBoostOverrides() -> AsyncStream<[String: VoiceBoostShowOverride]> {
      changes.stream
    }

    func setVoiceBoostOverride(itemID: String, override: VoiceBoostShowOverride) async throws {
      writes.withLock { $0.append(override) }
      let values = stored.withLock {
        $0[itemID] = override == .inherit ? nil : override
        return $0
      }
      changes.continuation.yield(values)
    }
  }

  final class FakeDefault: VoiceBoostDefaultSource {
    let value: Mutex<Bool>
    let changes = AsyncStream.makeStream(of: Bool.self)

    init(_ value: Bool) {
      self.value = Mutex(value)
      changes.continuation.yield(value)
    }

    var current: Bool { value.withLock { $0 } }
    func observeDefault() -> AsyncStream<Bool> { changes.stream }

    func set(_ next: Bool) {
      value.withLock { $0 = next }
      changes.continuation.yield(next)
    }
  }

  static let show = "rss:7"

  func makeModel(
    _ overrides: [String: VoiceBoostShowOverride] = [:], default isEnabled: Bool
  ) -> (ShowVoiceBoostModel, FakeSettings, FakeDefault) {
    let settings = FakeSettings(overrides)
    let defaults = FakeDefault(isEnabled)
    let model = ShowVoiceBoostModel(itemID: Self.show, settings: settings, defaults: defaults)
    return (model, settings, defaults)
  }

  func settle(_ condition: @MainActor () -> Bool) async {
    _ = await awaitCondition("the model follows its streams") { condition() }
  }

  @Test func resolvesTheShowAgainstTheDefault() {
    #expect(VoiceBoostResolution.isOn(default: true, showOverride: .inherit))
    #expect(VoiceBoostResolution.isOn(default: false, showOverride: .inherit) == false)
    #expect(VoiceBoostResolution.isOn(default: false, showOverride: .on))
    #expect(VoiceBoostResolution.isOn(default: true, showOverride: .off) == false)
  }

  @Test func theDefaultChoiceNamesWhatItResolvesTo() {
    #expect(VoiceBoostShowCopy.showChoiceLabel(.inherit, default: true) == "Default (On)")
    #expect(VoiceBoostShowCopy.showChoiceLabel(.inherit, default: false) == "Default (Off)")
    #expect(VoiceBoostShowCopy.showChoiceLabel(.on, default: false) == "On")
    #expect(VoiceBoostShowCopy.showChoiceLabel(.off, default: true) == "Off")
    let (model, _, _) = makeModel(default: false)
    #expect(model.choices == [.inherit, .on, .off])
  }

  @Test func readsTheShowsOverrideAndFollowsTheDefault() async {
    let (model, _, defaults) = makeModel([Self.show: .off], default: true)
    await settle { model.showOverride == .off }
    #expect(model.isOn == false)

    defaults.set(false)
    await settle { model.defaultValue == false }
    #expect(model.label(for: .inherit) == "Default (Off)")
  }

  @Test func choosingAValueWritesTheShow() async {
    let (model, settings, _) = makeModel(default: false)
    await model.setOverride(.on)
    #expect(settings.writes.withLock { $0 } == [.on])
    await settle { model.isOn }
    #expect(model.isOn)
  }

  @Test func tickingAShowOffByDefaultWritesOn() async {
    let (model, settings, _) = makeModel(default: false)
    await model.toggle()
    #expect(settings.writes.withLock { $0 } == [.on])
    await settle { model.isOn }
    #expect(model.isOn)
  }

  @Test func untickingAShowOnByDefaultWritesOff() async {
    let (model, settings, _) = makeModel(default: true)
    await model.toggle()
    #expect(settings.writes.withLock { $0 } == [.off])
    await settle { model.isOn == false }
    #expect(model.isOn == false)
  }

  @Test func aTapThatMatchesTheDefaultClearsTheOverride() async {
    let (model, settings, _) = makeModel([Self.show: .on], default: true)
    await settle { model.showOverride == .on }
    await model.toggle()
    #expect(settings.writes.withLock { $0 } == [.off])
    // The stream catches up with the write before the next tap reads it.
    await settle { model.showOverride == .off }

    await model.toggle()
    #expect(settings.writes.withLock { $0 } == [.off, .inherit])
    await settle { model.showOverride == .inherit }
    #expect(model.showOverride == .inherit)
    #expect(model.isOn)
  }
}
