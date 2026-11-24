import ABSApi
import AppModel
import Foundation
import Observation
import Persistence
import TestSupport
import Testing

@testable import Whirr

@Suite("Library shell presentation", .timeLimit(.minutes(1)))
struct LibraryShellPresentationTests {
  @Test("reselecting the Library tab requests a scroll to its top edge")
  func libraryTabReselectionRequestsScrollToTop() {
    var requests = LibraryReselectRequests()

    requests.record(.library, current: .library)
    requests.record(.library, current: .library)

    #expect(requests.count == 2)
  }

  @Test("only a Library reselect is worth writing shell state for")
  func onlyLibraryReselectIsWorthWritingState() {
    #expect(LibraryReselectRequests.isReselect(.library, current: .library))
    #expect(LibraryReselectRequests.isReselect(.library, current: .home) == false)
    #expect(LibraryReselectRequests.isReselect(.home, current: .home) == false)
    #expect(LibraryReselectRequests.isReselect(.search, current: .library) == false)
  }

  @Test("arriving at Library from another tab requests no scroll")
  func arrivingAtLibraryRequestsNoScroll() {
    var requests = LibraryReselectRequests()

    requests.record(.library, current: .home)

    #expect(requests == LibraryReselectRequests())
  }

  @Test("reselecting another tab requests no Library scroll")
  func reselectingAnotherTabRequestsNoLibraryScroll() {
    var requests = LibraryReselectRequests()

    requests.record(.home, current: .home)
    requests.record(.podcasts, current: .podcasts)
    requests.record(.search, current: .search)

    #expect(requests == LibraryReselectRequests())
  }

  @Test("settings and episode sheets suspend editorial palette work")
  func settingsAndEpisodeSheetsSuspendEditorialPaletteWork() {
    #expect(
      EditorialSuspensionPolicy.suspended(
        settingsPresented: true, episodePresented: false, itemDetailPresented: false,
        playerPresented: false))
    #expect(
      EditorialSuspensionPolicy.suspended(
        settingsPresented: false, episodePresented: true, itemDetailPresented: false,
        playerPresented: false))
    #expect(
      EditorialSuspensionPolicy.suspended(
        settingsPresented: false, episodePresented: false, itemDetailPresented: false,
        playerPresented: true))
  }

  @Test("editorial suspension is false only when all presentations are inactive")
  func editorialSuspensionPolicyIsFalseOnlyWhenAllPresentationsAreInactive() {
    #expect(
      EditorialSuspensionPolicy.suspended(
        settingsPresented: true, episodePresented: false, itemDetailPresented: false,
        playerPresented: false))
    #expect(
      EditorialSuspensionPolicy.suspended(
        settingsPresented: false, episodePresented: true, itemDetailPresented: false,
        playerPresented: false))
    #expect(
      EditorialSuspensionPolicy.suspended(
        settingsPresented: false, episodePresented: false, itemDetailPresented: false,
        playerPresented: true))
    #expect(
      EditorialSuspensionPolicy.suspended(
        settingsPresented: false, episodePresented: false, itemDetailPresented: false,
        playerPresented: false) == false)
  }

  @Test("the regular-width item detail card suspends editorial palette work")
  func itemDetailCardSuspendsEditorialPaletteWork() {
    #expect(
      EditorialSuspensionPolicy.suspended(
        settingsPresented: false, episodePresented: false, itemDetailPresented: true,
        playerPresented: false))
  }

  @Test("overlapping presentations keep suspension until the last completion")
  func overlappingPresentationsKeepSuspensionUntilTheLastCompletion() {
    var settingsPresented = true
    var episodePresented = true
    var playerPresented = true

    #expect(
      EditorialSuspensionPolicy.suspended(
        settingsPresented: settingsPresented,
        episodePresented: episodePresented,
        itemDetailPresented: false,
        playerPresented: playerPresented))

    // Settings has completed dismissal, but the episode presentation is still active.
    settingsPresented = false
    #expect(
      EditorialSuspensionPolicy.suspended(
        settingsPresented: settingsPresented,
        episodePresented: episodePresented,
        itemDetailPresented: false,
        playerPresented: playerPresented))

    // The episode has completed dismissal, but the player is still active.
    episodePresented = false
    #expect(
      EditorialSuspensionPolicy.suspended(
        settingsPresented: settingsPresented,
        episodePresented: episodePresented,
        itemDetailPresented: false,
        playerPresented: playerPresented))

    // The last active presentation has completed dismissal.
    playerPresented = false
    #expect(
      EditorialSuspensionPolicy.suspended(
        settingsPresented: settingsPresented,
        episodePresented: episodePresented,
        itemDetailPresented: false,
        playerPresented: playerPresented) == false)
  }

  @Test("podcast item selection defers navigation until after the current transaction")
  func podcastSelectionDefersNavigationUntilAfterCurrentTransaction() {
    #expect(
      LibraryShellPresentation.selectionNavigationScheduling(for: .podcast)
        == .afterCurrentTransaction)
  }

  @Test("book item selection remains deferred behind palette preparation")
  func bookSelectionRemainsDeferredBehindPalettePreparation() {
    #expect(
      LibraryShellPresentation.selectionNavigationScheduling(for: .audiobook)
        == .afterPalettePreparation)
    #expect(
      LibraryShellPresentation.selectionNavigationScheduling(for: .ebook)
        == .afterPalettePreparation)
  }

  @Test("item-detail selection preflights the destination's exact artwork identity")
  func detailArtworkPreflightIdentity() {
    let scope = ArtworkAccountScope("account-1")

    let twoX = LibraryShellPresentation.detailArtworkPreflightKey(
      for: .itemDetail(itemID: "book-1"), source: .audiobookshelf(scope), displayScale: 2)
    let threeX = LibraryShellPresentation.detailArtworkPreflightKey(
      for: .itemDetail(itemID: "book-1"), source: .audiobookshelf(scope), displayScale: 3)

    #expect(
      twoX
        == ArtworkKey(
          accountScope: scope,
          itemID: "book-1",
          variant: .highFidelity(pixelWidth: 768),
          revision: .unversioned))
    #expect(
      threeX
        == ArtworkKey(
          accountScope: scope,
          itemID: "book-1",
          variant: .highFidelity(pixelWidth: 1024),
          revision: .unversioned))
  }

  @Test("podcast-show preflight uses its seeded provider artwork identity")
  func podcastShowPreflightUsesSeededArtworkIdentity() throws {
    let defaultSource = ArtworkSource.audiobookshelf(ArtworkAccountScope("account-1"))
    let rssArtwork = try #require(
      RSSArtworkSource(
        feedIdentity: "rss:7", artworkURL: URL(string: "https://example.com/show.jpg")!,
        feedURL: URL(string: "https://example.com/feed.xml")!))
    let rssSource = ArtworkSource.rss(rssArtwork)
    let rssSeed = ItemSummary(
      serverItemId: "rss:7", mediaKind: "podcast", title: "RSS", author: nil,
      durationSeconds: nil, category: .podcast,
      artworkURL: URL(string: "https://example.com/show.jpg"),
      artworkFeedURL: URL(string: "https://example.com/feed.xml"))
    let serverSeed = ItemSummary(
      serverItemId: "server-show", mediaKind: "podcast", title: "Server", author: nil,
      durationSeconds: nil, category: .podcast)

    #expect(
      LibraryShellPresentation.detailArtworkPreflightKey(
        for: .podcastShow(itemID: "rss:7", seed: rssSeed), source: rssSource, displayScale: 3)
        == ArtworkKey(
          source: rssSource, itemID: "rss:7",
          variant: .homeCard(displaySize: Double(HomeView.cardCoverSize), displayScale: 3),
          revision: .unversioned))
    #expect(
      LibraryShellPresentation.detailArtworkPreflightKey(
        for: .podcastShow(itemID: "server-show", seed: serverSeed), source: defaultSource,
        displayScale: 3)
        == ArtworkKey(
          source: defaultSource, itemID: "server-show",
          variant: .homeCard(displaySize: Double(HomeView.cardCoverSize), displayScale: 3),
          revision: .unversioned))
    #expect(
      LibraryShellPresentation.detailArtworkPreflightKey(
        for: .podcastShow(itemID: "rss:7"), source: rssSource, displayScale: 3) == nil)
    #expect(
      LibraryShellPresentation.detailArtworkPreflightKey(
        for: .itemDetail(itemID: ""), source: defaultSource, displayScale: 3) == nil)
  }

  @MainActor
  @Test("navigation can change without awaiting artwork preflight")
  func artworkPreflightDoesNotBlockNavigation() async {
    let key = ArtworkKey(
      accountScope: ArtworkAccountScope("account-1"),
      itemID: "book-1",
      variant: .highFidelity(pixelWidth: 1024),
      revision: .unversioned)
    let operation = BlockingSelectionArtworkOperation()
    let preflight = LibrarySelectionArtworkPreflight()
    let navigation = NavigationModel()
    navigation.enterShell()

    preflight.start(key: key) { key in await operation.load(key) }
    navigation.navigate(to: .itemDetail(itemID: "book-1"))

    #expect(navigation[pathFor: .home] == [.itemDetail(itemID: "book-1")])
    await operation.waitUntilStarted(key)
    preflight.start(key: nil) { _ in }
  }

  @MainActor
  @Test("replacing a selection cancels only the obsolete preflight task")
  func replacingSelectionCancelsObsoletePreflight() async {
    let scope = ArtworkAccountScope("account-1")
    let first = ArtworkKey(
      accountScope: scope, itemID: "book-1", variant: .highFidelity(pixelWidth: 1024),
      revision: .unversioned)
    let second = ArtworkKey(
      accountScope: scope, itemID: "book-2", variant: .highFidelity(pixelWidth: 1024),
      revision: .unversioned)
    let operation = BlockingSelectionArtworkOperation()
    let preflight = LibrarySelectionArtworkPreflight()

    preflight.start(key: first) { key in await operation.load(key) }
    await operation.waitUntilStarted(first)
    preflight.start(key: second) { key in await operation.load(key) }

    await operation.waitUntilCancelled(first)
    await operation.waitUntilStarted(second)
    #expect(await operation.cancelledKeys == [first])
    preflight.start(key: nil) { _ in }
  }

  /// Without this, the transfer and the decode run to completion for a screen nobody is looking at.
  /// `start` is the only cancellation path, so a preflight outlives its destination until the next
  /// selection replaces it. `ArtworkImagePipeline` checks for cancellation before decoding, the
  /// expensive half. A preflight that never lets go stops that checkpoint from ever firing.
  @MainActor
  @Test("a dismissed destination releases the preflight it was opened for")
  func dismissedDestinationReleasesPreflight() async {
    let key = ArtworkKey(
      accountScope: ArtworkAccountScope("account-1"), itemID: "book-1",
      variant: .highFidelity(pixelWidth: 1024), revision: .unversioned)
    let operation = BlockingSelectionArtworkOperation()
    let preflight = LibrarySelectionArtworkPreflight()

    preflight.start(key: key) { key in await operation.load(key) }
    await operation.waitUntilStarted(key)
    preflight.destinationDisappeared(itemID: "book-1")

    await operation.waitUntilCancelled(key)
    #expect(await operation.cancelledKeys == [key])
  }

  /// A push from inside a detail screen covers the view below it, and SwiftUI disappears that view.
  /// This must not read as the newly selected item's destination going away.
  @MainActor
  @Test("a covered destination leaves the newer selection's preflight running")
  func coveredDestinationLeavesNewerPreflightRunning() async {
    let scope = ArtworkAccountScope("account-1")
    let first = ArtworkKey(
      accountScope: scope, itemID: "book-1", variant: .highFidelity(pixelWidth: 1024),
      revision: .unversioned)
    let second = ArtworkKey(
      accountScope: scope, itemID: "book-2", variant: .highFidelity(pixelWidth: 1024),
      revision: .unversioned)
    let operation = BlockingSelectionArtworkOperation()
    let preflight = LibrarySelectionArtworkPreflight()

    preflight.start(key: first) { key in await operation.load(key) }
    await operation.waitUntilStarted(first)
    preflight.start(key: second) { key in await operation.load(key) }
    await operation.waitUntilCancelled(first)
    await operation.waitUntilStarted(second)
    preflight.destinationDisappeared(itemID: "book-1")

    #expect(await operation.cancelledKeys == [first])
    preflight.start(key: nil) { _ in }
  }

  @Test("the settings shortcut appears on content roots but not settings itself")
  func settingsShortcutVisibility() {
    #expect(LibraryShellPresentation.showsSettingsShortcut(in: .home))
    #expect(LibraryShellPresentation.showsSettingsShortcut(in: .podcasts))
    #expect(LibraryShellPresentation.showsSettingsShortcut(in: .library))
    #expect(LibraryShellPresentation.showsSettingsShortcut(in: .search))
    #expect(LibraryShellPresentation.showsSettingsShortcut(in: .settings) == false)
  }

  @Test("Home, Library and Podcasts keep a large title that never collapses; the others keep the default")
  func shelfRootsUseInlineLargeTitles() {
    #expect(LibraryShellPresentation.usesInlineLargeTitle(in: .home))
    #expect(LibraryShellPresentation.usesInlineLargeTitle(in: .library))
    #expect(LibraryShellPresentation.usesInlineLargeTitle(in: .podcasts))
    #expect(LibraryShellPresentation.usesInlineLargeTitle(in: .search) == false)
    #expect(LibraryShellPresentation.usesInlineLargeTitle(in: .settings) == false)
  }

  @Test("only Search drops its root title from the bar")
  func onlySearchHidesRootTitle() {
    #expect(LibraryShellPresentation.hidesRootTitle(in: .search))
    #expect(LibraryShellPresentation.hidesRootTitle(in: .home) == false)
    #expect(LibraryShellPresentation.hidesRootTitle(in: .library) == false)
    #expect(LibraryShellPresentation.hidesRootTitle(in: .podcasts) == false)
    #expect(LibraryShellPresentation.hidesRootTitle(in: .settings) == false)
  }

  @Test("the Library toolbar keeps Settings on the outside trailing edge")
  func libraryToolbarOrder() {
    #expect(
      LibraryShellPresentation.rootToolbarTrailingOrder(
        in: .library, nativeSubscriptionsEnabled: true, isSelecting: false)
        == [.select, .filter, .settings])
    #expect(
      LibraryShellPresentation.rootToolbarTrailingOrder(
        in: .home, nativeSubscriptionsEnabled: true, isSelecting: false)
        == [.settings])
    #expect(
      LibraryShellPresentation.rootToolbarTrailingOrder(
        in: .podcasts, nativeSubscriptionsEnabled: true, isSelecting: false)
        == [.addFeed, .settings])
    #expect(
      LibraryShellPresentation.rootToolbarTrailingOrder(
        in: .podcasts, nativeSubscriptionsEnabled: false, isSelecting: false)
        == [.settings])
  }

  @Test("Authors and Series keep the independent library funnel available")
  func entityBrowseToolbarOrder() {
    #expect(
      LibraryShellPresentation.rootToolbarTrailingOrder(
        in: .library, nativeSubscriptionsEnabled: true, isSelecting: false)
        == [.select, .filter, .settings])
  }

  @Test("the Library toolbar places Select before the filter")
  func librarySelectPrecedesFilter() {
    let order = LibraryShellPresentation.rootToolbarTrailingOrder(
      in: .library, nativeSubscriptionsEnabled: true, isSelecting: false)
    #expect(order.contains(.select))
    guard let selectIndex = order.firstIndex(of: .select),
      let filterIndex = order.firstIndex(of: .filter)
    else {
      Issue.record("The Library toolbar order must contain Select and filter: \(order)")
      return
    }
    #expect(selectIndex < filterIndex)
  }

  @Test("Settings is last in every non-empty toolbar order")
  func settingsIsLastInEveryNonEmptyToolbarOrder() {
    for section in NavigationModel.Section.allCases {
      for nativeSubscriptionsEnabled in [true, false] {
        let order = LibraryShellPresentation.rootToolbarTrailingOrder(
          in: section,
          nativeSubscriptionsEnabled: nativeSubscriptionsEnabled,
          isSelecting: false)
        guard order.isEmpty == false else { continue }
        #expect(order.last == .some(.settings), "\(section) puts a control outside Settings: \(order)")
      }
    }
  }

  @Test("selection suppresses every section's root toolbar order")
  func selectingSuppressesEveryRootToolbarOrder() {
    for section in NavigationModel.Section.allCases {
      for nativeSubscriptionsEnabled in [true, false] {
        #expect(
          LibraryShellPresentation.rootToolbarTrailingOrder(
            in: section,
            nativeSubscriptionsEnabled: nativeSubscriptionsEnabled,
            isSelecting: true
          ).isEmpty,
          "\(section) exposes shell toolbar controls while selecting")
      }
    }
  }

  /// The funnel comes from this list, like everything else in the trailing group. A funnel declared
  /// in `SearchView` at `.primaryAction` sits at a different level from the shell's gear, so
  /// neither decides their order, and the buttons come out mirrored against the Library's.
  @Test("Search carries a filter, in the same order relative to Settings as the Library's")
  func searchToolbarOrder() {
    #expect(
      LibraryShellPresentation.rootToolbarTrailingOrder(
        in: .search, nativeSubscriptionsEnabled: true, isSelecting: false) == [.filter, .settings])
  }

  /// Wherever both appear, the funnel sits inboard of the gear. This is asserted across every
  /// section, not just the two known ones, so a later section cannot introduce a third order.
  @Test("the filter is always inboard of Settings, in every section that has both")
  func filterAlwaysPrecedesSettings() {
    for section in NavigationModel.Section.allCases {
      let order = LibraryShellPresentation.rootToolbarTrailingOrder(
        in: section, nativeSubscriptionsEnabled: true, isSelecting: false)
      guard let filterIndex = order.firstIndex(of: .filter),
        let settingsIndex = order.firstIndex(of: .settings)
      else { continue }
      #expect(filterIndex < settingsIndex, "\(section) puts Settings inboard of the filter")
    }
  }

  /// Add Podcast sits outboard of the gear when `PodcastsView` declares it in its own `.toolbar`
  /// and the shell declares the gear elsewhere. It is the same two-level split that mirrors
  /// Search's funnel, so it is pinned across every section, as the funnel is.
  @Test("Add Podcast is always inboard of Settings, in every section that has both")
  func addFeedAlwaysPrecedesSettings() {
    for section in NavigationModel.Section.allCases {
      for nativeSubscriptionsEnabled in [true, false] {
        let order = LibraryShellPresentation.rootToolbarTrailingOrder(
          in: section,
          nativeSubscriptionsEnabled: nativeSubscriptionsEnabled,
          isSelecting: false)
        guard let addIndex = order.firstIndex(of: .addFeed),
          let settingsIndex = order.firstIndex(of: .settings)
        else { continue }
        #expect(addIndex < settingsIndex, "\(section) puts Settings inboard of Add Podcast")
      }
    }
  }

  /// `LibraryShellView.rootToolbar` declares its items in `allCases` order and takes only
  /// membership from the order above, because `ForEach` is not usable inside
  /// `ToolbarContentBuilder`. That holds only while every section's order is a subsequence of
  /// `allCases`. Otherwise the shell would silently render an arrangement other than the one
  /// requested. This test checks that assumption.
  @Test("every section's toolbar order is one the shell can actually render, in that order")
  func toolbarOrdersAreExpressibleByTheShell() {
    let canonical = LibraryShellPresentation.RootToolbarTrailingItem.allCases
    for section in NavigationModel.Section.allCases {
      let order = LibraryShellPresentation.rootToolbarTrailingOrder(
        in: section, nativeSubscriptionsEnabled: true, isSelecting: false)
      var remaining = canonical[...]
      for item in order {
        guard let index = remaining.firstIndex(of: item) else {
          Issue.record("\(section) asks for \(order), which is not a subsequence of \(canonical)")
          break
        }
        remaining = remaining[remaining.index(after: index)...]
      }
    }
  }

  @Test("each root navigation stack keeps its tab identity")
  func rootNavigationStackIdentity() {
    for section in NavigationModel.Section.allCases {
      #expect(LibraryShellPresentation.navigationStackIdentity(for: section) == section)
    }
  }

  @MainActor
  @Test("the settings sheet binding reads and writes NavigationModel's presentation")
  func settingsPresentationBindingRoundTrips() {
    let navigation = NavigationModel()
    navigation.enterShell()
    let binding = SettingsPresentationBinding(navigation: navigation)

    #expect(binding.get == false)

    binding.set(true)
    #expect(navigation.settingsPresentation == .presented)
    #expect(binding.get)

    binding.set(false)
    #expect(navigation.settingsPresentation == .dismissed)
    #expect(binding.get == false)
  }

  /// Raising and dropping settings must leave the current section untouched, so dismissal returns
  /// you to where you were, not to an arbitrary tab.
  @MainActor
  @Test("presenting settings over a section leaves that section selected")
  func settingsSheetNeverChangesTheSelectedSection() {
    let navigation = NavigationModel()
    navigation.enterShell()
    navigation.section = .library
    let binding = SettingsPresentationBinding(navigation: navigation)

    binding.set(true)
    #expect(navigation.section == .library)

    binding.set(false)
    #expect(navigation.section == .library)
  }

  @MainActor
  @Test("navigate-driven settings entry arms selection suspension from the present edge")
  func navigateDrivenSettingsEntryBeginsSelectionSuspension() {
    let navigation = NavigationModel()
    navigation.enterShell()
    navigation.navigate(
      to: NavigationModel.Destination(section: .settings, path: [.podcastSettings]))
    #expect(navigation.settingsPresentation == .presented)
  }

  @Test("only Titles carries the Select control, and the shell decides that from the mode")
  func selectionEntryPresenceFollowsBrowseMode() {
    for mode in LibraryBrowsePresentation.Mode.allCases {
      #expect(
        LibraryShellPresentation.showsSelectionEntry(in: mode) == (mode == .titles),
        "\(mode) disagrees with Titles-only selection")
    }
  }
}

private actor BlockingSelectionArtworkOperation {
  private(set) var startedKeys: Set<ArtworkKey> = []
  private(set) var cancelledKeys: [ArtworkKey] = []

  func load(_ key: ArtworkKey) async {
    startedKeys.insert(key)
    await withTaskCancellationHandler {
      // Models an operation that blocks until cancelled. `Task.sleep` throws only on cancellation,
      // and unwinding is the behaviour under test, so the error is handled rather than swallowed
      // with `try?`.
      do {
        try await Task.sleep(for: .seconds(60))
      } catch {
        return
      }
    } onCancel: {
      Task { await self.recordCancellation(key) }
    }
  }

  /// Polls on the caller's isolation, not this actor's. The preflight starts on the main actor, so
  /// only polls that also queue there use up the budget while the main actor is busy.
  func waitUntilStarted(
    _ key: ArtworkKey,
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    await waitUntil(isolation: isolation, sourceLocation: sourceLocation) {
      await self.startedKeys.contains(key)
    }
  }

  func waitUntilCancelled(
    _ key: ArtworkKey,
    isolation: isolated (any Actor)? = #isolation,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async {
    await waitUntil(isolation: isolation, sourceLocation: sourceLocation) {
      await self.cancelledKeys.contains(key)
    }
  }

  private func recordCancellation(_ key: ArtworkKey) {
    cancelledKeys.append(key)
  }
}

/// `TabView` compares its selection binding on every shell body evaluation. A closure `Binding` is
/// a new location each time, whereas a key path on this one relay is the same location each time.
@MainActor
@Suite struct LibraryTabSelectionRelayTests {
  @Test func readsTheCurrentSection() {
    let navigation = NavigationModel()
    let relay = LibraryTabSelectionRelay()
    relay.read = { navigation.section }

    navigation.section = .search

    #expect(relay.selection == .search)
  }

  @Test func writesGoThroughTheWriteClosureIncludingReselects() {
    let relay = LibraryTabSelectionRelay()
    var writes: [NavigationModel.Section] = []
    relay.read = { .library }
    relay.write = { writes.append($0) }

    relay.selection = .library
    relay.selection = .home

    #expect(writes == [.library, .home])
  }

  @Test func readingTheSelectionTracksTheNavigationSection() {
    let navigation = NavigationModel()
    let relay = LibraryTabSelectionRelay()
    relay.read = { navigation.section }
    let notified = Locked(false)
    withObservationTracking {
      _ = relay.selection
    } onChange: {
      notified.withValue { $0 = true }
    }

    navigation.section = .search

    #expect(notified.value)
  }
}
