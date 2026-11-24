import Foundation
import Observation
import TestSupport
import Testing

@testable import Whirr

@MainActor
@Suite("App appearance store")
struct AppAppearanceStoreTests {
  /// `@AppStorage` invalidates its reader on every `UserDefaults` write, whatever the key; at the
  /// root that rebuilds the whole tab shell. Observation already suppresses a same-value
  /// mutation, so the handler's equality guard is belt-and-braces (removing it would not fail
  /// this). The load-bearing part is that `RootView` and `SettingsView` hold no `@AppStorage`.
  /// This pins that an unrelated write leaves the published value untouched and writes nothing.
  @Test("an unrelated defaults write does not invalidate an appearance reader")
  func unrelatedWriteDoesNotInvalidate() async throws {
    let suite = "appearance-unrelated-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppAppearanceStore(defaults: defaults)
    let invalidations = Locked(0)
    withObservationTracking {
      _ = store.appearance
    } onChange: {
      invalidations.withValue { $0 += 1 }
    }

    for _ in 0..<10 {
      defaults.set(Date(), forKey: "watch.context.timestamp")
      NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    }

    #expect(
      await awaitQuiescence("appearance observation", stableFor: 100) {
        "\(invalidations.value)|\(store.appearance.rawValue)"
      }.isObserved)
    #expect(invalidations.value == 0)
    #expect(store.appearance == .system)
    // No echo: the store must not answer a notification with a write of its own.
    #expect(defaults.object(forKey: AppAppearance.storageKey) == nil)
  }

  @Test("a write to the appearance key republishes exactly once")
  func appearanceWriteInvalidatesOnce() async throws {
    let suite = "appearance-changed-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppAppearanceStore(defaults: defaults)
    let invalidations = Locked(0)
    withObservationTracking {
      _ = store.appearance
    } onChange: {
      invalidations.withValue { $0 += 1 }
    }

    defaults.set(AppAppearance.dark.rawValue, forKey: AppAppearance.storageKey)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

    #expect(await waitUntil("appearance follows the stored value") { store.appearance == .dark })
    #expect(invalidations.value == 1)
  }

  @Test("an externally restored value is read at construction")
  func constructionReadsStoredValue() throws {
    let suite = "appearance-restored-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(AppAppearance.light.rawValue, forKey: AppAppearance.storageKey)

    #expect(AppAppearanceStore(defaults: defaults).appearance == .light)
  }

  @Test("an unreadable stored value resolves to System")
  func unknownStoredValueResolvesToSystem() throws {
    let suite = "appearance-unknown-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("sepia", forKey: AppAppearance.storageKey)

    #expect(AppAppearanceStore(defaults: defaults).appearance == .system)
  }

  @Test("the picker's selection writes through and publishes immediately")
  func selectionWritesThrough() throws {
    let suite = "appearance-selection-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppAppearanceStore(defaults: defaults)

    store.selection.wrappedValue = .dark

    #expect(store.appearance == .dark)
    #expect(defaults.string(forKey: AppAppearance.storageKey) == AppAppearance.dark.rawValue)
  }
}
