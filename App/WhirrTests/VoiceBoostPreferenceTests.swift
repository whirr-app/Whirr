import AppModel
import Foundation
import Observation
import Persistence
import TestSupport
import Testing

@testable import Whirr

/// The preference's default, the observer that carries it to the engine, and the copy both
/// toggles share. The observer resolves the loaded show's own setting against that default.
@MainActor
@Suite("Voice Boost preference")
struct VoiceBoostPreferenceTests {

  private func makeDefaults() throws -> UserDefaults {
    let name = "VoiceBoostPreferenceTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("an absent key reads as off")
  func absentMeansOff() throws {
    let defaults = try makeDefaults()
    #expect(UserDefaultsPlaybackPreferences(defaults: defaults).loadVoiceBoostEnabled() == false)
    defaults.set(true, forKey: UserDefaultsPlaybackPreferences.voiceBoostKey)
    #expect(UserDefaultsPlaybackPreferences(defaults: defaults).loadVoiceBoostEnabled())
  }

  @Test("the observer applies the stored value at start-up and then each change, once")
  func observerForwardsChanges() async throws {
    let defaults = try makeDefaults()
    defaults.set(true, forKey: UserDefaultsPlaybackPreferences.voiceBoostKey)
    var applied: [Bool] = []
    let observer = VoiceBoostPreferenceObserver(defaults: defaults) { applied.append($0) }
    #expect(applied == [true])

    defaults.set(false, forKey: UserDefaultsPlaybackPreferences.voiceBoostKey)
    let arrived = await waitUntil("the change reaches the observer") { applied == [true, false] }
    #expect(arrived)

    // An unrelated write must not re-apply the same value.
    defaults.set(2, forKey: "unrelated.key")
    _ = await awaitQuiescence("unrelated writes settle", of: { "\(applied.count)" })
    #expect(applied == [true, false])
    withExtendedLifetime(observer) {}
  }

  @Test("the observer drives a real engine's switch")
  func observerDrivesTheEngine() async throws {
    let defaults = try makeDefaults()
    let voiceBoost = VoiceBoostTapFactory()
    let engine = AVQueuePlayerAudioEngine(
      queuePlayer: FakeQueuePlayer(), itemFactory: FakeItemFactory(),
      session: AudioSessionConfigurator(session: FakeAudioSessionControlling()), voiceBoost: voiceBoost)
    let observer = VoiceBoostPreferenceObserver(defaults: defaults) { [weak engine] in
      engine?.setVoiceBoostEnabled($0)
    }
    #expect(voiceBoost.isEnabled == false)

    defaults.set(true, forKey: UserDefaultsPlaybackPreferences.voiceBoostKey)
    let arrived = await waitUntil("the engine's switch turns on") { voiceBoost.isEnabled }
    #expect(arrived)
    withExtendedLifetime(observer) {}
  }

  /// The loaded show, as `PlaybackHardware` reads it from `PlaybackModel`.
  @MainActor @Observable final class LoadedShow {
    var itemID: String?
  }

  private func overrideStream() -> (
    AsyncStream<[String: VoiceBoostShowOverride]>,
    AsyncStream<[String: VoiceBoostShowOverride]>.Continuation
  ) {
    let pair = AsyncStream.makeStream(
      of: [String: VoiceBoostShowOverride].self, bufferingPolicy: .bufferingNewest(1))
    return (pair.stream, pair.continuation)
  }

  @Test("the loaded show's own setting wins over the preference, and each show resolves its own")
  func showOverrideFollowsTheLoadedShow() async throws {
    let defaults = try makeDefaults()
    var applied: [Bool] = []
    let observer = VoiceBoostPreferenceObserver(defaults: defaults) { applied.append($0) }
    let loaded = LoadedShow()
    let (overrides, continuation) = overrideStream()
    observer.followShows(overrides: overrides) { [loaded] in loaded.itemID }
    continuation.yield(["rss:1": .on, "show-2": .off])
    #expect(applied == [false])

    loaded.itemID = "rss:1"
    #expect(await waitUntil("the boosted show turns it on") { applied == [false, true] })

    // A show with no setting of its own follows the preference, which is off.
    loaded.itemID = "show-3"
    #expect(await waitUntil("an inheriting show turns it off") { applied == [false, true, false] })

    defaults.set(true, forKey: UserDefaultsPlaybackPreferences.voiceBoostKey)
    #expect(await waitUntil("the preference reaches it") { applied == [false, true, false, true] })

    // The show turned off overrides the preference.
    loaded.itemID = "show-2"
    #expect(
      await waitUntil("the show's off wins") { applied == [false, true, false, true, false] })

    // Its setting cleared, it inherits again: mid-play, with no reload.
    continuation.yield(["rss:1": .on])
    #expect(
      await waitUntil("the cleared show inherits") {
        applied == [false, true, false, true, false, true]
      })
    withExtendedLifetime(observer) {}
  }

  @Test("an audiobook or nothing loaded follows the preference alone, as does a logged-out graph")
  func noShowFollowsThePreference() async throws {
    let defaults = try makeDefaults()
    defaults.set(true, forKey: UserDefaultsPlaybackPreferences.voiceBoostKey)
    var applied: [Bool] = []
    let observer = VoiceBoostPreferenceObserver(defaults: defaults) { applied.append($0) }
    let loaded = LoadedShow()
    let (overrides, continuation) = overrideStream()
    observer.followShows(overrides: overrides) { [loaded] in loaded.itemID }
    continuation.yield(["show-1": .off])
    loaded.itemID = "show-1"
    #expect(await waitUntil("the show turns it off") { applied == [true, false] })

    // An audiobook has no show.
    loaded.itemID = nil
    #expect(await waitUntil("an audiobook follows the preference") { applied == [true, false, true] })

    loaded.itemID = "show-1"
    #expect(await waitUntil("the show again") { applied == [true, false, true, false] })
    observer.stopFollowingShows()
    #expect(applied == [true, false, true, false, true])

    // A superseded account's streams no longer reach it.
    continuation.yield([:])
    loaded.itemID = "show-2"
    _ = await awaitQuiescence("stale updates settle", of: { "\(applied.count)" })
    #expect(applied == [true, false, true, false, true])
    withExtendedLifetime(observer) {}
  }

  @Test("a show's setting drives a real engine's switch while its item stays loaded")
  func showOverrideDrivesTheEngine() async throws {
    let defaults = try makeDefaults()
    let voiceBoost = VoiceBoostTapFactory()
    let engine = AVQueuePlayerAudioEngine(
      queuePlayer: FakeQueuePlayer(), itemFactory: FakeItemFactory(),
      session: AudioSessionConfigurator(session: FakeAudioSessionControlling()), voiceBoost: voiceBoost)
    let observer = VoiceBoostPreferenceObserver(defaults: defaults) { [weak engine] in
      engine?.setVoiceBoostEnabled($0)
    }
    let loaded = LoadedShow()
    loaded.itemID = "rss:9"
    let (overrides, continuation) = overrideStream()
    observer.followShows(overrides: overrides) { [loaded] in loaded.itemID }
    #expect(voiceBoost.isEnabled == false)

    continuation.yield(["rss:9": .on])
    #expect(await waitUntil("the engine's switch turns on") { voiceBoost.isEnabled })
    continuation.yield([:])
    #expect(await waitUntil("and off again") { voiceBoost.isEnabled == false })
    withExtendedLifetime(observer) {}
  }

  @Test("the per-show model's default source reads the preference and forwards only real changes")
  func defaultSourceStream() async throws {
    let defaults = try makeDefaults()
    let source = UserDefaultsVoiceBoostDefault(defaults: defaults)
    #expect(source.current == false)
    var iterator = source.observeDefault().makeAsyncIterator()
    #expect(await iterator.next() == false)
    defaults.set(2, forKey: "unrelated.key")
    defaults.set(true, forKey: UserDefaultsPlaybackPreferences.voiceBoostKey)
    #expect(await iterator.next() == true)
  }

  @Test("the copy is one footer sentence that names no device")
  func copy() {
    #expect(VoiceBoostCopy.settingsHeader != VoiceBoostCopy.toggleTitle)
    #expect(VoiceBoostCopy.footer.filter { $0 == "." }.count == 1)
    #expect(VoiceBoostCopy.footer.hasSuffix("."))
    for device in ["iPhone", "iPad", "phone"] {
      #expect(VoiceBoostCopy.footer.localizedCaseInsensitiveContains(device) == false)
    }
  }
}
