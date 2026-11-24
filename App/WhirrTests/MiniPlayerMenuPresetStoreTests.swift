import Foundation
import Observation
import TestSupport
import Testing

@testable import Whirr

/// The same contract `SkipIntervalStoreTests` pins for the skip intervals: the persistent
/// mini-player reads these presets, so an unrelated defaults write must not invalidate it.
@MainActor
@Suite("Mini-player menu preset store")
struct MiniPlayerMenuPresetStoreTests {
  @Test("an unrelated defaults write does not invalidate the mini player")
  func unrelatedWriteDoesNotInvalidate() async throws {
    let suite = "mini-player-presets-unrelated-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = MiniPlayerMenuPresetStore(defaults: defaults)
    let invalidations = Locked(0)
    withObservationTracking {
      _ = store.encodedRatePresets
      _ = store.encodedTimerPresets
    } onChange: {
      invalidations.withValue { $0 += 1 }
    }

    for _ in 0..<10 {
      defaults.set(Date(), forKey: "watch.context.timestamp")
      NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    }

    #expect(
      await awaitQuiescence("mini-player preset observation", stableFor: 100) {
        "\(invalidations.value)|\(store.encodedRatePresets)|\(store.encodedTimerPresets)"
      }.isObserved)
    #expect(invalidations.value == 0)
    #expect(defaults.object(forKey: MiniPlayerMenuPresetStore.ratePresetsKey) == nil)
    #expect(defaults.object(forKey: MiniPlayerMenuPresetStore.timerPresetsKey) == nil)
  }

  @Test("the playback settings editor's writes reach the mini player")
  func editorWritesArePublished() async throws {
    let suite = "mini-player-presets-editor-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = MiniPlayerMenuPresetStore(defaults: defaults)

    defaults.set("1,1.5,2", forKey: MiniPlayerMenuPresetStore.ratePresetsKey)
    defaults.set("10,20", forKey: MiniPlayerMenuPresetStore.timerPresetsKey)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

    #expect(
      await waitUntil("presets follow the editor") {
        store.encodedRatePresets == "1,1.5,2" && store.encodedTimerPresets == "10,20"
      })
  }
}
