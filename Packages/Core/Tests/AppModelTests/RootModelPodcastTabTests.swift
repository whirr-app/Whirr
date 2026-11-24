import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel
@testable import SyncEngine

extension RootModelTests {
  // MARK: - Podcast-tab availability

  @Test func podcastsTabAndForegroundTriggerTheBoundedNativeFeedPass() async {
    let refresh = RootRSSFeedRefreshCoordinator()
    let lifecycle = FakeAppLifecycle()
    let model = RootModel(
      dependencies: makeDependencies(
        rssFeedRefreshCoordinator: refresh, appLifecycle: lifecycle))

    model.podcastsTabSelected()
    #expect(await waitUntil { await refresh.triggers == [.foreground] })

    #expect(await waitUntil { lifecycle.lifecycleSubscriberCount >= 1 })
    lifecycle.simulateForeground()
    #expect(await waitUntil { await refresh.triggers == [.foreground, .foreground] })
  }

  @Test("a logged-out device still refreshes its own RSS feeds on foreground")
  func loggedOutForegroundRefreshesDeviceOwnedFeeds() async {
    let account = FakeAccountLifecycle()
    let refresh = RootRSSFeedRefreshCoordinator()
    let lifecycle = FakeAppLifecycle()
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, rssFeedRefreshCoordinator: refresh, appLifecycle: lifecycle,
        nativePodcastSubscriptionsReading: RootNativeSubscriptionsAccess(enabled: true)))

    #expect(account.isAuthenticated == false)
    #expect(model.navigation.presentation == .setup)
    #expect(await waitUntil { lifecycle.lifecycleSubscriberCount >= 1 })
    lifecycle.simulateForeground()

    #expect(await waitUntil { await refresh.triggers == [.foreground] })
  }

  @Test func podcastTabAvailabilityDefaultsToVisibleUntilSelectionEvidenceArrives() {
    let model = RootModel(dependencies: makeDependencies())

    #expect(model.hasIncludedPodcastLibrary)
  }

  @Test func podcastTabAvailabilityTracksIncludedAccessiblePodcastLibraries() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let selection = RootSelectionAccess(
      snapshot: Self.mixedSelectionSnapshot(podcastIncluded: false))
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, librarySelectionReading: selection,
        hasConfiguredIncludedLibrary: { true }))

    #expect(await waitUntil { model.hasIncludedPodcastLibrary == false })

    selection.emit(Self.mixedSelectionSnapshot(podcastIncluded: true))
    #expect(await waitUntil { model.hasIncludedPodcastLibrary })

    selection.emit(Self.mixedSelectionSnapshot(podcastIncluded: true, podcastAccessible: false))
    #expect(
      await waitUntil { model.hasIncludedPodcastLibrary == false },
      "a server-removed podcast library hides the tab even while its row stays included")
  }

  @Test func nativeSubscriptionsKeepPodcastsAvailableWithoutAServerPodcastLibrary() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let selection = RootSelectionAccess(
      snapshot: Self.mixedSelectionSnapshot(podcastIncluded: false))
    let native = RootNativeSubscriptionsAccess(enabled: true)
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, nativePodcastSubscriptionsReading: native,
        librarySelectionReading: selection, hasConfiguredIncludedLibrary: { true }))

    #expect(await waitUntil { model.hasIncludedPodcastLibrary == false })
    #expect(model.nativeSubscriptionsEnabled)
    #expect(model.showsPodcastsTab)

    model.navigation.section = .podcasts
    model.navigation.navigate(to: .nativePodcastShows)
    #expect(model.navigation.section == .podcasts)
  }

  @Test func disablingNativeSubscriptionsTruncatesOnlyTheNativePartOfAMixedPath() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let selection = RootSelectionAccess(
      snapshot: Self.mixedSelectionSnapshot(podcastIncluded: true))
    let native = RootNativeSubscriptionsAccess(enabled: true)
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, nativePodcastSubscriptionsReading: native,
        librarySelectionReading: selection, hasConfiguredIncludedLibrary: { true }))

    #expect(await waitUntil { model.nativeSubscriptionsEnabled })
    model.navigation.section = .podcasts
    model.navigation[pathFor: .podcasts] = [
      .podcastShows,
      .nativePodcastShows,
      .podcastShow(itemID: "rss:1"),
    ]

    native.emit(false)

    #expect(await waitUntil { model.nativeSubscriptionsEnabled == false })
    #expect(model.showsPodcastsTab)
    #expect(model.navigation.section == .podcasts)
    #expect(model.navigation[pathFor: .podcasts] == [.podcastShows])
  }

  @Test func disablingNativeSubscriptionsCancelsEveryRefreshTrigger() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let native = RootNativeSubscriptionsAccess(enabled: true)
    let refresh = RootRSSFeedRefreshCoordinator()
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, rssFeedRefreshCoordinator: refresh,
        nativePodcastSubscriptionsReading: native,
        librarySelectionReading: RootSelectionAccess(
          snapshot: Self.mixedSelectionSnapshot(podcastIncluded: true)),
        hasConfiguredIncludedLibrary: { true }))

    #expect(await waitUntil { model.nativeSubscriptionsEnabled })
    native.emit(false)

    #expect(
      await waitUntil { await refresh.cancellations == RSSFeedRefreshTrigger.allCases })
  }

  @Test func disablingTheFinalNativeSourceReroutesBeforeRemovingTheTab() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let selection = RootSelectionAccess(
      snapshot: Self.mixedSelectionSnapshot(podcastIncluded: false))
    let native = RootNativeSubscriptionsAccess(enabled: true)
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, nativePodcastSubscriptionsReading: native,
        librarySelectionReading: selection, hasConfiguredIncludedLibrary: { true }))

    #expect(await waitUntil { model.hasIncludedPodcastLibrary == false })
    model.navigation.section = .podcasts
    model.navigation.navigate(to: .podcastShow(itemID: "rss:1"))

    native.emit(false)

    #expect(await waitUntil { model.nativeSubscriptionsEnabled == false })
    #expect(model.showsPodcastsTab == false)
    #expect(model.navigation.section == .home)
    #expect(model.navigation[pathFor: .podcasts].isEmpty)
  }

  @Test func losingTheLastPodcastLibraryReroutesThePodcastsSectionHome() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let selection = RootSelectionAccess(
      snapshot: Self.mixedSelectionSnapshot(podcastIncluded: true))
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, librarySelectionReading: selection,
        hasConfiguredIncludedLibrary: { true }))

    model.resolveLibraryIfAuthenticated()
    #expect(await waitUntil { model.hasIncludedPodcastLibrary })
    #expect(await waitUntil { model.nativeSubscriptionsEnabled == false })

    model.navigation.section = .podcasts
    model.navigation.navigate(to: .podcastShows)

    selection.emit(Self.mixedSelectionSnapshot(podcastIncluded: false))
    #expect(await waitUntil { model.hasIncludedPodcastLibrary == false })
    #expect(model.navigation.section == .home)
    #expect(
      model.navigation[pathFor: .podcasts].isEmpty,
      "the hidden tab's stack must not survive to restore a stale show later")
  }

  @Test func losingThePodcastLibraryLeavesTheUserAloneOnOtherSections() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let selection = RootSelectionAccess(
      snapshot: Self.mixedSelectionSnapshot(podcastIncluded: true))
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, librarySelectionReading: selection,
        hasConfiguredIncludedLibrary: { true }))

    model.resolveLibraryIfAuthenticated()
    #expect(await waitUntil { model.hasIncludedPodcastLibrary })
    #expect(await waitUntil { model.nativeSubscriptionsEnabled == false })

    model.navigation.section = .library
    model.navigation.navigate(to: .itemDetail(itemID: "book-1"))

    selection.emit(Self.mixedSelectionSnapshot(podcastIncluded: false))
    #expect(await waitUntil { model.hasIncludedPodcastLibrary == false })
    #expect(model.navigation.section == .library)
    #expect(model.navigation[pathFor: .library] == [.itemDetail(itemID: "book-1")])
  }

  /// A `TabView` built with the iOS 27 SDK can crash when its selection names a tab that is no
  /// longer present. `RootModel` moves the selection to Home before clearing
  /// `hasIncludedPodcastLibrary`. The neighbouring tests pin the settled result, which is the
  /// same whichever order the two writes happen in. This one observes the removal itself, so
  /// reversing the two statements in `updatePodcastAvailability(from:)` fails here and only here.
  @Test func thePodcastTabIsNeverRemovedWhileItIsStillTheSelectedSection() async {
    let account = FakeAccountLifecycle()
    account.isAuthenticated = true
    let selection = RootSelectionAccess(
      snapshot: Self.mixedSelectionSnapshot(podcastIncluded: true))
    let model = RootModel(
      dependencies: makeDependencies(
        account: account, librarySelectionReading: selection,
        hasConfiguredIncludedLibrary: { true }))

    model.resolveLibraryIfAuthenticated()
    #expect(await waitUntil { model.hasIncludedPodcastLibrary })
    #expect(await waitUntil { model.nativeSubscriptionsEnabled == false })
    model.navigation.section = .podcasts

    /// `withObservationTracking`'s `onChange` runs before the tracked write lands, so this records
    /// the section as it stands at the instant the tab is being taken away.
    final class SectionAtRemoval: @unchecked Sendable {
      var value: NavigationModel.Section?
    }
    let observed = SectionAtRemoval()
    withObservationTracking {
      _ = model.hasIncludedPodcastLibrary
    } onChange: {
      MainActor.assumeIsolated { observed.value = model.navigation.section }
    }

    selection.emit(Self.mixedSelectionSnapshot(podcastIncluded: false))
    #expect(await waitUntil { model.hasIncludedPodcastLibrary == false })
    #expect(
      observed.value == .home,
      "the selection must leave Podcasts before the tab disappears, not after")
  }
}
