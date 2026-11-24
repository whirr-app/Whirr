import Foundation
import Observation
import TestSupport
import Testing

@testable import Whirr

@MainActor
@Suite("Skip interval store")
struct SkipIntervalStoreTests {
  /// The store invalidates its reader on every `UserDefaults` write, whatever the key. The mini
  /// player is persistent chrome present on every screen, so it is the reader that matters.
  @Test("an unrelated defaults write does not invalidate the mini player")
  func unrelatedWriteDoesNotInvalidate() async throws {
    let suite = "skip-intervals-unrelated-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SkipIntervalStore(defaults: defaults)
    let invalidations = Locked(0)
    withObservationTracking {
      _ = store.forwardSeconds
      _ = store.backwardSeconds
    } onChange: {
      invalidations.withValue { $0 += 1 }
    }

    for _ in 0..<10 {
      defaults.set(Date(), forKey: "watch.context.timestamp")
      NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    }

    #expect(
      await awaitQuiescence("skip interval observation", stableFor: 100) {
        "\(invalidations.value)|\(store.forwardSeconds)|\(store.backwardSeconds)"
      }.isObserved)
    #expect(invalidations.value == 0)
    #expect(store.forwardSeconds == SkipIntervalConfiguration.defaultForwardSeconds)
    #expect(store.backwardSeconds == SkipIntervalConfiguration.defaultBackwardSeconds)
    // No echo: the store must not answer a notification with a write of its own.
    #expect(defaults.object(forKey: SkipIntervalConfiguration.forwardStorageKey) == nil)
    #expect(defaults.object(forKey: SkipIntervalConfiguration.backwardStorageKey) == nil)
  }

  /// No default-value trap here: a missing key reads as `0`, and `resolvedSeconds` maps anything
  /// outside `presets` onto the directional default. That is why `RemoteCommandAdapter` and
  /// `WatchCataloguePublisher` can read these keys with a bare `integer(forKey:)`. Pinned here so
  /// the defaults are stated where a reader will look.
  @Test("an untouched install uses the directional defaults")
  func anUntouchedInstallUsesTheDirectionalDefaults() throws {
    let suite = "skip-intervals-default-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = SkipIntervalStore(defaults: defaults)
    #expect(store.forwardSeconds == 30)
    #expect(store.backwardSeconds == 15)
  }

  @Test("the playback settings editor's writes reach the mini player")
  func editorWritesArePublished() async throws {
    let suite = "skip-intervals-editor-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SkipIntervalStore(defaults: defaults)

    defaults.set(45, forKey: SkipIntervalConfiguration.forwardStorageKey)
    defaults.set(10, forKey: SkipIntervalConfiguration.backwardStorageKey)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

    #expect(
      await waitUntil("skip intervals follow the editor") {
        store.forwardSeconds == 45 && store.backwardSeconds == 10
      })
  }

  /// Observation tracks per property, so changing one direction must not invalidate a reader of
  /// the other. Each direction has its own key for that reason.
  @Test("changing the forward interval does not invalidate a reader of the backward one")
  func perDirectionTrackingIsolatesReaders() async throws {
    let suite = "skip-intervals-isolation-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SkipIntervalStore(defaults: defaults)
    let invalidations = Locked(0)
    withObservationTracking {
      _ = store.backwardSeconds
    } onChange: {
      invalidations.withValue { $0 += 1 }
    }

    defaults.set(90, forKey: SkipIntervalConfiguration.forwardStorageKey)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

    #expect(await waitUntil("the forward interval lands") { store.forwardSeconds == 90 })
    #expect(invalidations.value == 0)
  }

  /// The store publishes what the controls actually display, so a stored value the menu cannot
  /// represent resolves before it is published and never reaches the view as a change.
  @Test("a stored value outside the presets does not invalidate")
  func outOfPresetValueDoesNotInvalidate() async throws {
    let suite = "skip-intervals-unresolvable-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SkipIntervalStore(defaults: defaults)
    let invalidations = Locked(0)
    withObservationTracking {
      _ = store.forwardSeconds
      _ = store.backwardSeconds
    } onChange: {
      invalidations.withValue { $0 += 1 }
    }

    defaults.set(7, forKey: SkipIntervalConfiguration.forwardStorageKey)
    defaults.set(-1, forKey: SkipIntervalConfiguration.backwardStorageKey)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

    #expect(
      await awaitQuiescence("unresolvable skip intervals", stableFor: 100) {
        "\(invalidations.value)|\(store.forwardSeconds)|\(store.backwardSeconds)"
      }.isObserved)
    #expect(invalidations.value == 0)
    #expect(store.forwardSeconds == SkipIntervalConfiguration.defaultForwardSeconds)
    #expect(store.backwardSeconds == SkipIntervalConfiguration.defaultBackwardSeconds)
  }
}
