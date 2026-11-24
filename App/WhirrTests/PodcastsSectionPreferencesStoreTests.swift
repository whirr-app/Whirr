import AppModel
import Foundation
import Observation
import TestSupport
import Testing

@testable import Whirr

@MainActor
@Suite("Podcasts section preferences store")
struct PodcastsSectionPreferencesStoreTests {
  @Test("an untouched install shows every section in the built-in order")
  func defaultsAreEmpty() throws {
    let suite = "podcasts-sections-default-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = PodcastsSectionPreferencesStore(defaults: defaults)

    #expect(store.hiddenSections.isEmpty)
    #expect(store.sectionOrder.isEmpty)
    #expect(
      PodcastsViewPresentation.visibleRootSections(
        hiddenSections: store.hiddenSections, sectionOrder: store.sectionOrder)
        == PodcastsRootSection.allCases)
  }

  @Test("the settings editor's writes reach the tab root")
  func editorWritesArePublished() async throws {
    let suite = "podcasts-sections-editor-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = PodcastsSectionPreferencesStore(defaults: defaults)

    let hidden = PodcastsRootSectionVisibility.updating(
      "", section: .latestEpisodes, isVisible: false)
    let order = PodcastsRootSectionOrder.stored([.yourShows, .continueListening, .latestEpisodes])
    defaults.set(hidden, forKey: PodcastsRootSectionVisibility.storageKey)
    defaults.set(order, forKey: PodcastsRootSectionOrder.storageKey)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

    #expect(
      await waitUntil("both preferences follow the editor") {
        store.hiddenSections == hidden && store.sectionOrder == order
      })
    #expect(PodcastsRootSectionVisibility.hidden(in: store.hiddenSections) == [.latestEpisodes])
  }

  @Test("an unrelated defaults write does not invalidate a preferences reader")
  func unrelatedWriteDoesNotInvalidate() async throws {
    let suite = "podcasts-sections-unrelated-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = PodcastsSectionPreferencesStore(defaults: defaults)
    let invalidations = Locked(0)
    withObservationTracking {
      _ = store.hiddenSections
      _ = store.sectionOrder
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
    // No echo: the store must not answer a notification with a write of its own.
    #expect(defaults.object(forKey: PodcastsRootSectionVisibility.storageKey) == nil)
    #expect(defaults.object(forKey: PodcastsRootSectionOrder.storageKey) == nil)
  }

  @Test("Home's keys do not move the Podcasts store")
  func homeKeysAreIndependent() async throws {
    let suite = "podcasts-sections-home-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = PodcastsSectionPreferencesStore(defaults: defaults)

    defaults.set("downloaded", forKey: HomeSectionVisibility.storageKey)
    defaults.set("recentlyAdded", forKey: HomeSectionOrder.storageKey)
    NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)

    #expect(
      await awaitQuiescence("podcasts preferences", stableFor: 100) {
        "\(store.hiddenSections)|\(store.sectionOrder)"
      }.isObserved)
    #expect(store.hiddenSections.isEmpty)
    #expect(store.sectionOrder.isEmpty)
  }
}
