import AppModel
import Foundation
import Observation
import TestSupport
import Testing

@testable import Whirr

@MainActor
@Suite("Home section preferences store")
struct HomeSectionPreferencesStoreTests {
  /// The contract this type provides, stated against the `@AppStorage` it replaced: that
  /// invalidates its reader on every `UserDefaults` write regardless of key, and both readers here
  /// are tab roots. See the note in `AppAppearanceStoreTests` on what this can and cannot fail on.
  @Test("an unrelated defaults write does not invalidate a preferences reader")
  func unrelatedWriteDoesNotInvalidate() async throws {
    let suite = "home-sections-unrelated-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = HomeSectionPreferencesStore(defaults: defaults)
    let invalidations = Locked(0)
    withObservationTracking {
      _ = store.hiddenSections
      _ = store.sectionOrder
      _ = store.opensContinueCardImmediately
    } onChange: {
      invalidations.withValue { $0 += 1 }
    }

    for _ in 0..<10 {
      defaults.set(Date(), forKey: "watch.context.timestamp")
      NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    }

    #expect(
      await awaitQuiescence("preferences observation", stableFor: 100) {
        "\(invalidations.value)|\(store.hiddenSections)|\(store.sectionOrder)"
      }.isObserved)
    #expect(invalidations.value == 0)
    #expect(store.hiddenSections.isEmpty)
    #expect(store.sectionOrder.isEmpty)
    #expect(store.opensContinueCardImmediately)
    // No echo: the store must not answer a notification with a write of its own.
    #expect(defaults.object(forKey: HomeSectionVisibility.storageKey) == nil)
    #expect(defaults.object(forKey: HomeSectionOrder.storageKey) == nil)
    #expect(defaults.object(forKey: HomeSectionVisibility.continueCardOpenOnTapStorageKey) == nil)
  }

  /// The one behavioural trap in the conversion. `@AppStorage(...) = true` reads an untouched
  /// install as on; `defaults.bool(forKey:)` would read it as off and silently flip what a tap on
  /// a continuation card does for everyone who never opened Home's settings.
  @Test("an untouched install still opens the continuation card immediately")
  func continueCardPreferenceDefaultsToOn() throws {
    let suite = "home-sections-default-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(HomeSectionPreferencesStore(defaults: defaults).opensContinueCardImmediately)

    defaults.set(false, forKey: HomeSectionVisibility.continueCardOpenOnTapStorageKey)
    #expect(HomeSectionPreferencesStore(defaults: defaults).opensContinueCardImmediately == false)
  }

  @Test("the settings editor's writes reach the tab roots")
  func editorWritesArePublished() async throws {
    let suite = "home-sections-editor-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = HomeSectionPreferencesStore(defaults: defaults)

    let hidden = HomeSectionVisibility.updating("", section: .recentlyAdded, isVisible: false)
    defaults.set(hidden, forKey: HomeSectionVisibility.storageKey)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    #expect(await waitUntil("hidden sections follow the editor") { store.hiddenSections == hidden })
    #expect(HomeSectionVisibility.hidden(in: store.hiddenSections) == [.recentlyAdded])

    defaults.set(false, forKey: HomeSectionVisibility.continueCardOpenOnTapStorageKey)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    #expect(
      await waitUntil("continuation preference follows the editor") {
        store.opensContinueCardImmediately == false
      })
  }

  /// Observation tracks per property, so reordering shelves must not invalidate the Podcasts tab,
  /// which reads only the continuation-card preference.
  @Test("a shelf reorder does not invalidate a reader of the continuation preference alone")
  func perPropertyTrackingIsolatesReaders() async throws {
    let suite = "home-sections-isolation-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = HomeSectionPreferencesStore(defaults: defaults)
    let invalidations = Locked(0)
    withObservationTracking {
      _ = store.opensContinueCardImmediately
    } onChange: {
      invalidations.withValue { $0 += 1 }
    }

    defaults.set("recentlyAdded", forKey: HomeSectionOrder.storageKey)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

    #expect(await waitUntil("order lands") { store.sectionOrder == "recentlyAdded" })
    #expect(invalidations.value == 0)
  }
}
