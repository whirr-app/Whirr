import ABSApi
import AppModel
import Foundation
import Persistence
import PlayerCore
import SwiftUI
import SyncEngine
import TestSupport
import Testing
import UIKit

@testable import Whirr

/// The UIKit dismissal interactor must keep finding the upper scroll view once the chrome is its
/// bottom sibling.
@MainActor
@Suite("Expanded player dismissal boundary", .serialized)
struct ExpandedPlayerDismissalBoundaryTests {

  fileprivate static let windowBounds = CGRect(x: 0, y: 0, width: 375, height: 812)
  /// The app-hosted test window has no automatic top inset; the upper page owns its zero boundary.
  private static let expectedHostedTopInset: CGFloat = 0

  @Test("the short podcast exposes one upper scroll view at the dismissal boundary")
  func shortPodcastHasOneUpperScrollViewAtTop() async throws {
    try await ExpandedPlayerDismissalBoundaryHost.withHost(fixture: .podcast) { host in
      try await host.waitForLayoutToSettle()

      let scrollView = try requireSingleScrollView(in: host)
      let chromeFrame = try #require(PlayerLayoutProbe.frame(.chrome))
      let scrollFrame = host.globalFrame(of: scrollView)

      #expect(
        // Adjacent, not overlapping: the chrome starts where the scrolling region ends, so none of
        // it can scroll away.
        chromeFrame.minY >= scrollFrame.maxY,
        "upper scroll frame must end before chrome: scroll=\(scrollFrame) chrome=\(chromeFrame)"
      )
      expectHostedTopBoundary(scrollView, label: "short podcast")
      expectChromeOutsideScrollView(chromeFrame, scrollView: scrollView, host: host)
    }
  }

  @Test("scrolled accessibility overflow is not eligible for pull-down dismissal")
  func overflowingAccessibilityContentGatesDismissalAfterScrolling() async throws {
    try await ExpandedPlayerDismissalBoundaryHost.withHost(
      fixture: .accessibilityOverflow, dynamicTypeSize: .accessibility3
    ) { host in
      try await host.waitForLayoutToSettle()

      let scrollView = try requireSingleScrollView(in: host)
      let chromeFrame = try #require(PlayerLayoutProbe.frame(.chrome))
      let scrollFrame = host.globalFrame(of: scrollView)

      #expect(
        // Adjacent, not overlapping: the chrome starts where the scrolling region ends, so none of
        // it can scroll away.
        chromeFrame.minY >= scrollFrame.maxY,
        "upper scroll frame must end before chrome: scroll=\(scrollFrame) chrome=\(chromeFrame)"
      )
      expectHostedTopBoundary(scrollView, label: "accessibility overflow before scrolling")
      expectChromeOutsideScrollView(chromeFrame, scrollView: scrollView, host: host)

      #expect(
        scrollView.contentSize.height > scrollView.bounds.height,
        "accessibility fixture must overflow the upper scroll view: content=\(scrollView.contentSize) bounds=\(scrollView.bounds)"
      )

      let maximumOffsetY = max(
        -scrollView.adjustedContentInset.top,
        scrollView.contentSize.height - scrollView.bounds.height
          + scrollView.adjustedContentInset.bottom)
      scrollView.setContentOffset(CGPoint(x: 0, y: maximumOffsetY), animated: false)
      host.window.layoutIfNeeded()

      #expect(
        scrollView.contentOffset.y
          > -scrollView.adjustedContentInset.top + PlayerDismissalPolicy.scrollTopTolerance,
        "fixture did not reach a mid-content offset: offset=\(scrollView.contentOffset.y)"
      )
      #expect(
        !PlayerDismissalPolicy.isAtScrollTop(
          contentOffsetY: scrollView.contentOffset.y,
          adjustedContentInsetTop: scrollView.adjustedContentInset.top),
        "a pull from mid-content must not be eligible for dismissal"
      )
    }
  }

  private func requireSingleScrollView(
    in host: ExpandedPlayerDismissalBoundaryHost
  ) throws -> UIScrollView {
    let scrollViews = host.scrollViewsInBreadthFirstOrder()
    #expect(
      scrollViews.count == 1,
      "the hosted player must expose exactly one UIScrollView, found \(scrollViews.count)"
    )
    guard let scrollView = scrollViews.first else {
      throw ExpandedPlayerDismissalBoundaryTestError(message: "hosted player exposed no UIScrollView")
    }
    return scrollView
  }

  private func expectHostedTopBoundary(_ scrollView: UIScrollView, label: String) {
    #expect(
      scrollView.adjustedContentInset.top == Self.expectedHostedTopInset,
      "\(label) adjustedContentInset.top changed: expected \(Self.expectedHostedTopInset), got \(scrollView.adjustedContentInset.top)"
    )
    #expect(
      scrollView.contentOffset.y == 0,
      "\(label) contentOffset.y should start at the hosted top boundary: got \(scrollView.contentOffset.y)"
    )
    #expect(
      PlayerDismissalPolicy.isAtScrollTop(
        contentOffsetY: scrollView.contentOffset.y,
        adjustedContentInsetTop: scrollView.adjustedContentInset.top),
      "\(label) should be eligible for a downward pull at rest"
    )
  }

  private func expectChromeOutsideScrollView(
    _ chromeFrame: CGRect,
    scrollView: UIScrollView,
    host: ExpandedPlayerDismissalBoundaryHost
  ) {
    let chromeInScrollView = scrollView.convert(chromeFrame, from: nil)
    #expect(
      !scrollView.bounds.contains(chromeInScrollView),
      "chrome frame must not be contained by the upper scroll view: bounds=\(scrollView.bounds) chrome=\(chromeInScrollView)"
    )
    #expect(
      host.globalFrame(of: scrollView).maxY <= chromeFrame.minY,
      "chrome must remain below, not inside, the upper scroll view"
    )
  }
}

private struct ExpandedPlayerDismissalBoundaryFixture: Sendable {
  let itemID: String
  let episodeID: String?
  let metadataSeed: PlayerMetadataSeed?

  init(itemID: String, episodeID: String?, title: String) {
    self.itemID = itemID
    self.episodeID = episodeID
    let identity =
      if let episodeID {
        ListeningIdentity.podcastEpisode(itemID: itemID, episodeID: episodeID)
      } else {
        ListeningIdentity.audiobook(itemID: itemID)
      }
    metadataSeed = identity.map {
      PlayerMetadataSeed(identity: $0, title: title, author: "Fixture Author")
    }
  }

  static let podcast = Self(
    itemID: "epc-dismissal-podcast",
    episodeID: "epc-dismissal-podcast-episode",
    title: "Podcast fixture")

  nonisolated static let accessibilityOverflowItemID = "epc-dismissal-overflow"
  nonisolated static let accessibilityOverflow = Self(
    itemID: accessibilityOverflowItemID,
    episodeID: nil,
    title:
      "An Accessibility Sized Title That Uses Three Lines While A Chapter Row And Recovery Banner Also Occupy The Upper Region"
  )
}

@MainActor
private struct ExpandedPlayerDismissalBoundaryHostedPlayer: View {
  let fixture: ExpandedPlayerDismissalBoundaryFixture
  let dependencies: ExpandedPlayerDismissalBoundaryDependencies
  let dynamicTypeSize: DynamicTypeSize

  var body: some View {
    ExpandedPlayerView(
      itemID: fixture.itemID,
      episodeID: fixture.episodeID,
      metadataSeed: fixture.metadataSeed,
      playback: dependencies.playback,
      connectivityModel: dependencies.connectivityModel,
      player: dependencies.player,
      library: dependencies.harness.library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading(),
      coverClient: dependencies.harness.coverClient,
      navigation: dependencies.harness.navigation,
      paletteService: dependencies.harness.paletteService,
      actions: dependencies.harness.actions,
      playbackRate: dependencies.harness.playbackRate,
      finishedStatus: dependencies.harness.finishedStatus,
      extrasAccess: dependencies.extrasAccess,
      authorSeriesReading: NoOpAuthorSeriesReading(),
      makeListeningQueueModel: { ListeningQueueModel() },
      makeItemHistoryModel: { itemID in
        ItemHistoryModel(
          itemId: itemID, category: .audiobook, history: dependencies.harness.historyAccess)
      }
    )
    .dynamicTypeSize(dynamicTypeSize)
    .preferredColorScheme(.dark)
  }
}

@MainActor
private struct ExpandedPlayerDismissalBoundaryDependencies {
  let harness: UIHarnessSession
  let playback: PlaybackModel
  let player: any PlaybackControlling
  let connectivityModel: ConnectivityModel?
  let extrasAccess: any ItemDetailExtrasAccess
}

@MainActor
private final class ExpandedPlayerDismissalBoundaryHost {
  let window: UIWindow
  private let hostingController: UIHostingController<ExpandedPlayerDismissalBoundaryHostedPlayer>

  private init(
    window: UIWindow,
    hostingController: UIHostingController<ExpandedPlayerDismissalBoundaryHostedPlayer>
  ) {
    self.window = window
    self.hostingController = hostingController
  }

  /// Hosts `fixture` for the duration of `body`.
  ///
  /// Scoped rather than a `make()`/`tearDown()` pair: the key window is a process global, so a
  /// forgotten restore would silently change what every later suite hosts. `withKeyWindow` runs
  /// the restore from a `defer`, including on the throwing path.
  static func withHost<T>(
    fixture: ExpandedPlayerDismissalBoundaryFixture,
    dynamicTypeSize: DynamicTypeSize = .large,
    _ body: (ExpandedPlayerDismissalBoundaryHost) async throws -> T
  ) async rethrows -> T {
    try await withKeyWindow(bounds: ExpandedPlayerDismissalBoundaryTests.windowBounds) { scope in
      let host = await make(fixture: fixture, dynamicTypeSize: dynamicTypeSize, in: scope)
      return try await body(host)
    }
  }

  private static func make(
    fixture: ExpandedPlayerDismissalBoundaryFixture,
    dynamicTypeSize: DynamicTypeSize,
    in scope: KeyWindowScope
  ) async -> ExpandedPlayerDismissalBoundaryHost {
    let harness = UIHarnessSession()
    let dependencies: ExpandedPlayerDismissalBoundaryDependencies

    if fixture.itemID == ExpandedPlayerDismissalBoundaryFixture.accessibilityOverflowItemID {
      let player = PlayerController(engine: HarnessAudioEngine(), clock: SystemPlaybackClock())
      let playback = PlaybackModel(
        sync: makeFailingSyncing(itemID: fixture.itemID),
        player: player,
        account: HarnessAccountLifecycle(),
        appLifecycle: HarnessAppLifecycle(),
        rateCoordinator: harness.playbackRate)
      dependencies = ExpandedPlayerDismissalBoundaryDependencies(
        harness: harness,
        playback: playback,
        player: player,
        connectivityModel: nil,
        extrasAccess: makeExtrasAccess())
      await playback.start(
        itemID: fixture.itemID, episodeID: fixture.episodeID, origin: .queueAdvance)
    } else {
      dependencies = ExpandedPlayerDismissalBoundaryDependencies(
        harness: harness,
        playback: harness.playback,
        player: harness.player,
        connectivityModel: nil,
        extrasAccess: makeExtrasAccess())
    }

    PlayerLayoutProbe.reset()
    let hostingController = scope.host(
      ExpandedPlayerDismissalBoundaryHostedPlayer(
        fixture: fixture, dependencies: dependencies, dynamicTypeSize: dynamicTypeSize))

    return Self(window: scope.window, hostingController: hostingController)
  }

  func scrollViewsInBreadthFirstOrder() -> [UIScrollView] {
    var views: [UIView] = [hostingController.view]
    var scrollViews: [UIScrollView] = []
    var nextIndex = 0

    while nextIndex < views.count {
      let view = views[nextIndex]
      nextIndex += 1
      if let scrollView = view as? UIScrollView {
        scrollViews.append(scrollView)
      }
      views.append(contentsOf: view.subviews)
    }

    return scrollViews
  }

  func globalFrame(of scrollView: UIScrollView) -> CGRect {
    scrollView.convert(scrollView.bounds, to: nil)
  }

  func waitForLayoutToSettle() async throws {
    let outcome = await awaitQuiescence(
      "expanded-player dismissal boundary layout",
      of: {
        window.layoutIfNeeded()
        hostingController.view.layoutIfNeeded()
        guard
          let chromeFrame = PlayerLayoutProbe.frame(.chrome),
          let scrollView = scrollViewsInBreadthFirstOrder().first
        else { return "unmeasured" }

        let current = ExpandedPlayerDismissalBoundaryLayoutSnapshot(
          chromeFrame: chromeFrame,
          scrollFrame: globalFrame(of: scrollView),
          contentSize: scrollView.contentSize,
          contentOffset: scrollView.contentOffset,
          adjustedContentInsetTop: scrollView.adjustedContentInset.top)
        return String(describing: current)
      })
    guard outcome.isObserved,
      PlayerLayoutProbe.frame(.chrome) != nil,
      scrollViewsInBreadthFirstOrder().first != nil
    else {
      throw ExpandedPlayerDismissalBoundaryTestError(
        message: "hosted dismissal boundary did not settle; probe=\(PlayerLayoutProbe.frames)")
    }
  }
}

private struct ExpandedPlayerDismissalBoundaryLayoutSnapshot: Equatable {
  let chromeFrame: CGRect
  let scrollFrame: CGRect
  let contentSize: CGSize
  let contentOffset: CGPoint
  let adjustedContentInsetTop: CGFloat
}

private struct ExpandedPlayerDismissalBoundaryTestError: Error, CustomStringConvertible {
  let message: String

  var description: String { message }
}

private func makeExtrasAccess() -> FakeItemDetailExtrasAccess {
  let overflowItemID = ExpandedPlayerDismissalBoundaryFixture.accessibilityOverflowItemID
  let extras = FakeItemDetailExtrasAccess()
  extras.stubResults { itemID in
    let chapters: [ItemChapterInfo] =
      itemID == overflowItemID
      ? [ItemChapterInfo(title: "Fixture Chapter", start: 60, end: 3_600)]
      : []
    return ItemDetailExtras(seriesName: nil, narrator: "Fixture Author", chapters: chapters)
  }
  return extras
}

private func makeFailingSyncing(itemID: String) -> FakePlaybackSyncing {
  let sync = FakePlaybackSyncing()
  sync.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem(itemID)))
  return sync
}
