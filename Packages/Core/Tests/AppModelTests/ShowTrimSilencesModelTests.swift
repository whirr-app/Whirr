import Foundation
import Persistence
import Synchronization
import TestSupport
import Testing

@testable import AppModel

/// One show's Trim Silences setting as the show settings page and the speed card's tick row see
/// it, and the copy both draw.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ShowTrimSilencesModelTests {
  final class FakeSettings: TrimSilencesShowSettingsReading, TrimSilencesShowSettingsWriting {
    let stored = Mutex<[String: TrimSilencesShowOverride]>([:])
    let writes = Mutex<[TrimSilencesShowOverride]>([])
    let changes = AsyncStream.makeStream(of: [String: TrimSilencesShowOverride].self)

    init(_ values: [String: TrimSilencesShowOverride] = [:]) {
      stored.withLock { $0 = values }
      changes.continuation.yield(values)
    }

    func fetchTrimSilencesOverrides() async throws -> [String: TrimSilencesShowOverride] {
      stored.withLock { $0 }
    }

    func observeTrimSilencesOverrides() -> AsyncStream<[String: TrimSilencesShowOverride]> {
      changes.stream
    }

    func setTrimSilencesOverride(itemID: String, override: TrimSilencesShowOverride) async throws {
      writes.withLock { $0.append(override) }
      let values = stored.withLock {
        $0[itemID] = override == .inherit ? nil : override
        return $0
      }
      changes.continuation.yield(values)
    }
  }

  final class FakeDefaults: TrimSilencesDefaultSource {
    let value: Mutex<TrimSilencesDefault>
    let changes = AsyncStream.makeStream(of: TrimSilencesDefault.self)

    init(_ value: TrimSilencesDefault) {
      self.value = Mutex(value)
      changes.continuation.yield(value)
    }

    var current: TrimSilencesDefault { value.withLock { $0 } }
    func observeDefault() -> AsyncStream<TrimSilencesDefault> { changes.stream }

    func set(_ next: TrimSilencesDefault) {
      value.withLock { $0 = next }
      changes.continuation.yield(next)
    }
  }

  static let show = "rss:7"

  func makeModel(
    _ overrides: [String: TrimSilencesShowOverride] = [:], default value: TrimSilencesDefault
  ) -> (ShowTrimSilencesModel, FakeSettings, FakeDefaults) {
    let settings = FakeSettings(overrides)
    let defaults = FakeDefaults(value)
    let model = ShowTrimSilencesModel(itemID: Self.show, settings: settings, defaults: defaults)
    return (model, settings, defaults)
  }

  func settle(_ condition: @MainActor () -> Bool) async {
    _ = await awaitCondition("the model follows its streams") { condition() }
  }

  // MARK: - The show settings picker

  @Test func theDefaultChoiceNamesWhatItResolvesTo() {
    #expect(
      TrimSilencesCopy.showChoiceLabel(.inherit, default: .init(isEnabled: true, strength: .moderate))
        == "Default (Low)")
    #expect(
      TrimSilencesCopy.showChoiceLabel(.inherit, default: .init(isEnabled: true, strength: .maximum))
        == "Default (High)")
    #expect(TrimSilencesCopy.showChoiceLabel(.inherit, default: .off) == "Default (Off)")
    #expect(TrimSilencesCopy.showChoiceLabel(.off, default: .off) == "Off")
    #expect(TrimSilencesCopy.showChoiceLabel(.moderate, default: .off) == "Low")
    #expect(TrimSilencesCopy.showChoiceLabel(.maximum, default: .off) == "High")
  }

  @Test func offersDefaultFirstThenEveryValue() {
    let (model, _, _) = makeModel(default: .off)
    #expect(model.choices == [.inherit, .off, .moderate, .maximum])
  }

  @Test func readsTheShowsOverrideAndFollowsTheDefault() async {
    let (model, _, defaults) = makeModel([Self.show: .maximum], default: .off)
    await settle { model.showOverride == .maximum }
    #expect(model.showOverride == .maximum)
    #expect(model.isOn)

    defaults.set(.moderateOn)
    await settle { model.defaultValue == .moderateOn }
    #expect(model.label(for: .inherit) == "Default (Low)")
  }

  @Test func choosingAValueWritesTheShow() async throws {
    let (model, settings, _) = makeModel(default: .off)
    await model.setOverride(.moderate)
    #expect(settings.writes.withLock { $0 } == [.moderate])
    await settle { model.showOverride == .moderate }
    #expect(model.showOverride == .moderate)
  }

  // MARK: - The speed card's tick row

  @Test func tickingAShowOffByDefaultWritesTheDefaultStrength() async {
    let (model, settings, _) = makeModel(
      default: TrimSilencesDefault(isEnabled: false, strength: .maximum))
    await settle { model.defaultValue.strength == .maximum }
    #expect(model.isOn == false)

    await model.toggle()

    #expect(settings.writes.withLock { $0 } == [.maximum])
    await settle { model.isOn }
    #expect(model.isOn)
  }

  @Test func untickingAShowOnByDefaultWritesOff() async {
    let (model, settings, _) = makeModel(default: .moderateOn)
    await settle { model.isOn }

    await model.toggle()

    #expect(settings.writes.withLock { $0 } == [.off])
    await settle { model.isOn == false }
    #expect(model.isOn == false)
  }

  @Test func aTapThatMatchesTheDefaultClearsTheOverride() async {
    let (model, settings, _) = makeModel([Self.show: .off], default: .moderateOn)
    await settle { model.showOverride == .off }

    await model.toggle()

    #expect(settings.writes.withLock { $0 } == [.inherit])
    await settle { model.showOverride == .inherit }
    #expect(model.showOverride == .inherit)
    #expect(model.isOn)
  }

  // MARK: - Captions and Settings copy

  @Test func cardCaptionAddsTheFocusSentenceWhileAFocusDecides() {
    let saved = PlaybackTrimStatus.trimming(savedThisEpisode: 192)
    let focus = "Your Focus decides until it ends."
    #expect(
      TrimSilencesCopy.cardCaption(status: saved, isOn: true, isGovernedByFocus: false)
        == "Saved 3:12 in this episode.")
    #expect(
      TrimSilencesCopy.cardCaption(status: saved, isOn: true, isGovernedByFocus: true)
        == "Saved 3:12 in this episode. \(focus)")
    #expect(
      TrimSilencesCopy.cardCaption(status: .off, isOn: false, isGovernedByFocus: true) == focus)
    #expect(
      TrimSilencesCopy.cardCaption(status: saved, isOn: false, isGovernedByFocus: false) == nil)
  }

  @Test func eachStatusHasItsCaption() {
    #expect(TrimSilencesCopy.caption(for: .off) == nil)
    #expect(TrimSilencesCopy.caption(for: .trimming(savedThisEpisode: 192)) == "Saved 3:12 in this episode.")
    #expect(
      TrimSilencesCopy.caption(for: .trimming(savedThisEpisode: 3_725))
        == "Saved 1:02:05 in this episode.")
    #expect(TrimSilencesCopy.caption(for: .preparing) == "Getting this episode ready…")
    #expect(TrimSilencesCopy.caption(for: .notApplicable) == "Only downloaded episodes are trimmed.")
    #expect(TrimSilencesCopy.caption(for: .unavailable) == "This episode can't be trimmed.")
  }

  /// The strength names are display only: the stored values stay `moderate` and `maximum`.
  @Test func theSettingsCopyIsShortAndNamesTheStrengthsLowAndHigh() {
    #expect(TrimSilencesCopy.strengthLabel(.moderate) == "Low")
    #expect(TrimSilencesCopy.strengthLabel(.maximum) == "High")
    #expect(
      TrimSilencesCopy.settingsFooter
        == "Shortens pauses in downloaded podcast episodes. Shows can have their own setting.")
  }
}
