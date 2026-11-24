import ABSApi
import AppModel
import DesignSystem
import Foundation
import Persistence
import PlayerCore
import SwiftUI
import SyncEngine
import TestSupport
import Testing
import UIKit

@testable import Whirr

enum ExpandedPlayerChromeChapterState: Sendable {
  case noChapterRow
  case chaptered
  case chapterless
  case unresolved
}

extension ExpandedPlayerChromeLayoutTests {

  typealias ChapterFixtureState = ExpandedPlayerChromeChapterState

  enum PlaybackFixtureState {
    case idle
    case recoverableError
  }

  struct Fixture {
    let itemID: String
    let episodeID: String?
    let metadataSeed: PlayerMetadataSeed?
    let chapterState: ChapterFixtureState

    init(
      itemID: String, episodeID: String?, title: String, author: String? = "Fixture Author",
      chapterState: ChapterFixtureState = .noChapterRow
    ) {
      self.itemID = itemID
      self.episodeID = episodeID
      self.chapterState = chapterState
      let identity =
        if let episodeID {
          ListeningIdentity.podcastEpisode(itemID: itemID, episodeID: episodeID)
        } else {
          ListeningIdentity.audiobook(itemID: itemID)
        }
      metadataSeed = identity.map {
        PlayerMetadataSeed(identity: $0, title: title, author: author)
      }
    }

    static let podcast = Fixture(
      itemID: "epc-podcast-fixture",
      episodeID: "epc-podcast-episode",
      title: "Podcast fixture")

    static let audiobook = Fixture(
      itemID: "epc-audiobook-fixture",
      episodeID: nil,
      title: "Audiobook fixture",
      chapterState: .chaptered)

    static let oneLineTitle = Fixture(
      itemID: "epc-one-line-title",
      episodeID: "epc-one-line-episode",
      title: "Morning Edition")

    static let twoLineTitle = Fixture(
      itemID: "epc-two-line-title",
      episodeID: "epc-two-line-episode",
      title: "A Longer Player Title That Wraps Once")

    static let threeLineTitle = Fixture(
      itemID: "epc-three-line-title",
      episodeID: "epc-three-line-episode",
      title: "A Long Player Title That Should Wrap Across Three Visible Lines")

    /// The worst nominal band: a chaptered book whose title fills the three-line budget without
    /// spilling past it. The title is shorter than `threeLineTitle`, which needs a fourth line in a
    /// 375pt column and would measure truncated rather than fitting. This one measures 157.33pt on
    /// every gated container.
    static let threeLineChapteredTitle = Fixture(
      itemID: "epc-three-line-chaptered-title",
      episodeID: nil,
      title: "A Long Player Title That Wraps Across Three Visible Lines",
      chapterState: .chaptered)

    static let overBudgetTitle = Fixture(
      itemID: "epc-over-budget-title",
      episodeID: "epc-over-budget-episode",
      title:
        "An Exceptionally Long Player Title That Clearly Exceeds The Three Line Budget And Is Truncated At Its Third Line"
    )

    static let chapterlessBook = Fixture(
      itemID: "epc-confirmed-chapterless-book",
      episodeID: nil,
      title: "Confirmed Chapterless Book",
      chapterState: .chapterless)

    static let unresolvedBook = Fixture(
      itemID: "epc-unresolved-chapter-book",
      episodeID: nil,
      title: "Unresolved Chapter Book",
      chapterState: .unresolved)

    static let resolvedBook = Fixture(
      itemID: "epc-resolved-chapter-book",
      episodeID: nil,
      title: "Resolved Chapter Book",
      chapterState: .chaptered)

    static let statusHidden = Fixture(
      itemID: "epc-status-hidden",
      episodeID: "epc-status-hidden-episode",
      title: "Status Banner Fixture")

    static let statusVisible = Fixture(
      itemID: "epc-status-visible",
      episodeID: "epc-status-visible-episode",
      title: "Status Banner Fixture")

    static let overflowBaseline = Fixture(
      itemID: "epc-overflow-baseline",
      episodeID: "epc-overflow-baseline-episode",
      title: "Short Overflow Baseline")

    static let overflowContent = Fixture(
      itemID: "epc-overflow-content",
      episodeID: nil,
      title:
        "An Accessibility Sized Title That Uses Three Lines While A Chapter Row And Recovery Banner Also Occupy The Upper Region",
      chapterState: .chaptered)
  }

  struct ChromeFrames {
    let cover: CGRect
    let metadata: CGRect
    let scrubber: CGRect
    let transport: CGRect
    let quickActions: CGRect
    let chrome: CGRect
  }

  struct FixturePair {
    let podcast: ChromeFrames
    let audiobook: ChromeFrames
    let displayScale: CGFloat
    /// What the page was actually handed, not what the test asked for: `additionalSafeAreaInsets`
    /// adds to whatever the test host's own window scene already reports.
    let safeAreaInsets: UIEdgeInsets
  }

  struct FixtureMeasurement {
    let frames: [ChromeFrames]
    let firstCoverFrames: [CGRect?]
    let displayScale: CGFloat
    let safeAreaInsets: UIEdgeInsets
  }

  struct HostedPlayerDependencies {
    let harness: UIHarnessSession
    let playback: PlaybackModel
    let player: any PlaybackControlling
    let connectivityModel: ConnectivityModel?
    let extrasAccess: any ItemDetailExtrasAccess
  }

  typealias BeforeHosting =
    @MainActor (HostedPlayerDependencies) async throws -> Void
  typealias BeforeFixture =
    @MainActor (Int, HostedPlayerDependencies) async throws -> Void
  typealias AfterFixture =
    @MainActor (UIWindow, UIHostingController<HostedPlayer>, ChromeFrames) -> Void

  /// A stable root type lets the test replace the fixture while retaining the same hosting
  /// controller and window. The view is still the production `ExpandedPlayerView`; the wrapper
  /// only pins Dynamic Type and appearance so both passes share those inputs.
  struct HostedPlayer: View {
    let fixture: Fixture
    let dependencies: HostedPlayerDependencies
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

  /// Which way `region - large - cover` bounds the band, given the clamp that resolved the cover.
  static func bandBoundDirection(cover: CGFloat, regionHeight: CGFloat) -> String {
    let tolerance = 0.01
    if abs(cover - ExpandedPlayerView.minimumCoverSize) <= tolerance {
      return "at least (cover on its floor)"
    }
    if abs(cover - ExpandedPlayerView.coverHeightShare * regionHeight) <= tolerance {
      return "at most (cover on the share cap)"
    }
    return "exact (cover on the band term)"
  }

  static let coverTopEdgeTolerance: CGFloat = 20

  static let coverAgreementTolerance: CGFloat = 3

  nonisolated static let windowBounds = CGRect(x: 0, y: 0, width: 393, height: 852)

  /// The suite's default stays zero, as those invariant tests are full-bleed. These are the page
  /// insets modelled by each named device-class container, not the scene inset UIKit contributes to
  /// the test window.
  static let targetSafeAreaInsetsByContainer: [String: UIEdgeInsets] = [
    "375x667": UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0),
    "375x812": UIEdgeInsets(top: 44, left: 0, bottom: 34, right: 0),
    "393x852": UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0),
    "402x874": UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0),
  ]

  static func targetSafeAreaInsets(for bounds: CGRect) -> UIEdgeInsets {
    let key = "\(Int(bounds.width))x\(Int(bounds.height))"
    guard let insets = targetSafeAreaInsetsByContainer[key] else {
      preconditionFailure("missing modeled device insets for \(key)")
    }
    return insets
  }

  static let dismissHandleHeight: CGFloat = 28

  static let compactContainers = [
    CGRect(x: 0, y: 0, width: 393, height: 852),
    CGRect(x: 0, y: 0, width: 402, height: 874),
  ]

  /// The containers the page's layout invariants are gated on. 375x667 is absent by decision: it
  /// overflows at ordinary Dynamic Type.
  static let gatedContainers = [
    CGRect(x: 0, y: 0, width: 375, height: 812),
    CGRect(x: 0, y: 0, width: 393, height: 852),
    CGRect(x: 0, y: 0, width: 402, height: 874),
  ]

  /// How far clear of `minimumCoverSize` the artwork must resolve before the page counts as
  /// having room. At the floor the cover is roughly half the width of a 393pt device, the reported
  /// symptom.
  static let coverFloorMargin: CGFloat = 60

  static func scrollViewsInBreadthFirstOrder(from rootView: UIView) -> [UIScrollView] {
    var views: [UIView] = [rootView]
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

  /// Hosts both fixtures in one live `UIHostingController`. Replacing `rootView` keeps the
  /// production page's retained `@State` and geometry feedback in play, since they are part of the
  /// failure surface. Two unrelated view constructions would miss the live transition.
  func measureFixturePair(
    windowBounds: CGRect = Self.windowBounds,
    dynamicTypeSize: DynamicTypeSize = .large,
    targetSafeAreaInsets: UIEdgeInsets = .zero
  ) async throws -> FixturePair {
    let measurement = try await measureFixtureSequence(
      fixtures: [.podcast, .audiobook],
      windowBounds: windowBounds,
      dynamicTypeSize: dynamicTypeSize,
      targetSafeAreaInsets: targetSafeAreaInsets)
    guard measurement.frames.count == 2 else {
      throw LayoutMeasurementError(message: "expected two fixture frames")
    }
    return FixturePair(
      podcast: measurement.frames[0], audiobook: measurement.frames[1],
      displayScale: measurement.displayScale, safeAreaInsets: measurement.safeAreaInsets)
  }

  func measureFixtureSequence(
    fixtures: [Fixture],
    windowBounds: CGRect = Self.windowBounds,
    dynamicTypeSize: DynamicTypeSize = .large,
    targetSafeAreaInsets: UIEdgeInsets = .zero,
    playbackState: PlaybackFixtureState = .idle,
    beforeHosting: BeforeHosting? = nil,
    beforeFixture: BeforeFixture? = nil,
    captureFirstCoverFrames: Bool = false,
    afterFixture: AfterFixture? = nil
  ) async throws -> FixtureMeasurement {
    guard fixtures.isEmpty == false else {
      throw LayoutMeasurementError(message: "expected at least one expanded-player fixture")
    }
    let dependencies = makeHostedPlayerDependencies(
      fixtures: fixtures, playbackState: playbackState)
    if let beforeHosting {
      try await beforeHosting(dependencies)
    }

    // `withKeyWindow` owns the key-window process global. It captures the previous key window,
    // makes this one key, and restores it from a `defer`, including on the throwing path. Both
    // hosting suites go through it, so the restore cannot be forgotten.
    return try await withKeyWindow(bounds: windowBounds) { scope in
      // Cleared once, before anything is hosted, not between fixtures. `onGeometryChange` publishes
      // only when a frame changes, so a region that holds its position across the switch would
      // never republish and would read as missing.
      PlayerLayoutProbe.reset()
      let hostingController = scope.host(
        HostedPlayer(
          fixture: fixtures[0], dependencies: dependencies, dynamicTypeSize: dynamicTypeSize))

      // `KeyWindowScope` adopts the test simulator's scene, so the hosted controller already has
      // that scene's safe area. Apply only the delta from that contribution to the modelled device
      // inset. This keeps the suite's zero-inset default while letting device-class fixtures name
      // the final inset they receive.
      scope.window.layoutIfNeeded()
      hostingController.view.layoutIfNeeded()
      let sceneSafeAreaInsets = hostingController.view.safeAreaInsets
      hostingController.additionalSafeAreaInsets = UIEdgeInsets(
        top: targetSafeAreaInsets.top - sceneSafeAreaInsets.top,
        left: targetSafeAreaInsets.left - sceneSafeAreaInsets.left,
        bottom: targetSafeAreaInsets.bottom - sceneSafeAreaInsets.bottom,
        right: targetSafeAreaInsets.right - sceneSafeAreaInsets.right)
      scope.window.layoutIfNeeded()
      hostingController.view.layoutIfNeeded()
      let resolvedSafeAreaInsets = hostingController.view.safeAreaInsets
      let insetTolerance = 1.0 / max(scope.window.screen.scale, 1)
      #expect(
        abs(resolvedSafeAreaInsets.top - targetSafeAreaInsets.top) <= insetTolerance,
        "resolved top safe area \(resolvedSafeAreaInsets.top) != target \(targetSafeAreaInsets.top)")
      #expect(
        abs(resolvedSafeAreaInsets.left - targetSafeAreaInsets.left) <= insetTolerance,
        "resolved left safe area \(resolvedSafeAreaInsets.left) != target \(targetSafeAreaInsets.left)")
      #expect(
        abs(resolvedSafeAreaInsets.bottom - targetSafeAreaInsets.bottom) <= insetTolerance,
        "resolved bottom safe area \(resolvedSafeAreaInsets.bottom) != target \(targetSafeAreaInsets.bottom)")
      #expect(
        abs(resolvedSafeAreaInsets.right - targetSafeAreaInsets.right) <= insetTolerance,
        "resolved right safe area \(resolvedSafeAreaInsets.right) != target \(targetSafeAreaInsets.right)")

      var frames: [ChromeFrames] = []
      frames.reserveCapacity(fixtures.count)
      var firstCoverFrames: [CGRect?] = []
      if captureFirstCoverFrames {
        firstCoverFrames.reserveCapacity(fixtures.count)
      }
      for (index, fixture) in fixtures.enumerated() {
        if index > 0 {
          if let beforeFixture {
            try await beforeFixture(index, dependencies)
          }
          hostingController.rootView = HostedPlayer(
            fixture: fixture, dependencies: dependencies, dynamicTypeSize: dynamicTypeSize)
        }
        if captureFirstCoverFrames {
          // Capture the first probe read after this explicit layout pass. A later quiescence read
          // would hide the one-pass settling the instrument records.
          scope.window.layoutIfNeeded()
          firstCoverFrames.append(PlayerLayoutProbe.frame(.cover))
        }
        let frame = try await settledChromeFrames(
          in: scope.window, hostingController: hostingController)
        afterFixture?(scope.window, hostingController, frame)
        frames.append(frame)
      }

      return FixtureMeasurement(
        frames: frames, firstCoverFrames: firstCoverFrames,
        displayScale: max(scope.window.screen.scale, 1),
        safeAreaInsets: hostingController.view.safeAreaInsets)
    }
  }

  /// Waits for SwiftUI's geometry publication, not just UIKit's first layout: the page's
  /// `onGeometryChange` feeds back into the cover size, so frames settle after several passes.
  /// Ten stable polls, not fifty: the loop converges well before ten agree, and the suite takes 82
  /// of these waits holding the key window, so fifty would cost about nine seconds per App run.
  func settledChromeFrames(
    in window: UIWindow,
    hostingController: UIHostingController<HostedPlayer>
  ) async throws -> ChromeFrames {
    let outcome = await awaitQuiescence(
      "expanded-player chrome frames",
      stableFor: 10,
      of: {
        window.layoutIfNeeded()
        hostingController.view.layoutIfNeeded()
        return Self.probedFrames().map { "\($0)" } ?? "unmeasured"
      })
    guard outcome.isObserved, let frames = Self.probedFrames() else {
      throw LayoutMeasurementError(
        message: "expanded-player chrome frames did not settle; probe contents: "
          + String(describing: PlayerLayoutProbe.frames))
    }
    return frames
  }

  static func probedFrames() -> ChromeFrames? {
    guard
      let cover = PlayerLayoutProbe.frame(.cover),
      let metadata = PlayerLayoutProbe.frame(.metadata),
      let scrubber = PlayerLayoutProbe.frame(.scrubber),
      let transport = PlayerLayoutProbe.frame(.transport),
      let quickActions = PlayerLayoutProbe.frame(.quickActions),
      let chrome = PlayerLayoutProbe.frame(.chrome)
    else { return nil }

    return ChromeFrames(
      cover: cover, metadata: metadata, scrubber: scrubber, transport: transport,
      quickActions: quickActions, chrome: chrome)
  }

  static func agree(_ lhs: ChromeFrames, _ rhs: ChromeFrames) -> Bool {
    lhs.cover.equalTo(rhs.cover)
      && lhs.metadata.equalTo(rhs.metadata)
      && lhs.scrubber.equalTo(rhs.scrubber)
      && lhs.transport.equalTo(rhs.transport)
      && lhs.quickActions.equalTo(rhs.quickActions)
      && lhs.chrome.equalTo(rhs.chrome)
  }

  func expectChromeInvariant(
    _ lhs: ChromeFrames, _ rhs: ChromeFrames, tolerance: CGFloat, label: String
  ) {
    #expect(
      abs(lhs.scrubber.minY - rhs.scrubber.minY) <= tolerance,
      "\(label) scrubber minY: A=\(lhs.scrubber.minY) B=\(rhs.scrubber.minY)"
    )
    #expect(
      abs(lhs.transport.midY - rhs.transport.midY) <= tolerance,
      "\(label) transport midY: A=\(lhs.transport.midY) B=\(rhs.transport.midY)"
    )
    #expect(
      abs(lhs.quickActions.maxY - rhs.quickActions.maxY) <= tolerance,
      "\(label) quick-actions bottom: A=\(lhs.quickActions.maxY) B=\(rhs.quickActions.maxY)"
    )
  }

  func expectUpperRegionChanged(
    _ lhs: ChromeFrames, _ rhs: ChromeFrames, tolerance: CGFloat, label: String
  ) {
    #expect(
      abs(lhs.metadata.height - rhs.metadata.height) > tolerance
        || abs(lhs.metadata.minY - rhs.metadata.minY) > tolerance,
      "\(label) upper region did not change: A=\(lhs.metadata) B=\(rhs.metadata)"
    )
  }

  func expectChromeInside(
    _ frames: ChromeFrames, bounds: CGRect, tolerance: CGFloat, label: String
  ) {
    #expect(
      frames.chrome.minY >= bounds.minY - tolerance,
      "\(label) chrome escaped above the container: frame=\(frames.chrome) bounds=\(bounds)"
    )
    #expect(
      frames.chrome.maxY <= bounds.maxY + tolerance,
      "\(label) chrome exceeded the container bottom: frame=\(frames.chrome) bounds=\(bounds)"
    )
    #expect(
      frames.quickActions.maxY <= bounds.maxY + tolerance,
      "\(label) quick actions exceeded the container bottom: frame=\(frames.quickActions) bounds=\(bounds)"
    )
  }

  func makeHostedPlayerDependencies(
    fixtures: [Fixture], playbackState: PlaybackFixtureState
  ) -> HostedPlayerDependencies {
    let harness = UIHarnessSession()
    let chapterStates = Dictionary(
      uniqueKeysWithValues: fixtures.map { ($0.itemID, $0.chapterState) })
    let extrasAccess = makeFixtureExtrasAccess(chapterStates: chapterStates)

    switch playbackState {
    case .idle:
      return HostedPlayerDependencies(
        harness: harness,
        playback: harness.playback,
        player: harness.player,
        connectivityModel: nil,
        extrasAccess: extrasAccess)
    case .recoverableError:
      let player = PlayerController(engine: HarnessAudioEngine(), clock: SystemPlaybackClock())
      let playback = PlaybackModel(
        sync: makeFailingPlaybackSyncing(),
        player: player,
        account: HarnessAccountLifecycle(),
        appLifecycle: HarnessAppLifecycle(),
        rateCoordinator: harness.playbackRate)
      return HostedPlayerDependencies(
        harness: harness,
        playback: playback,
        player: player,
        connectivityModel: nil,
        extrasAccess: extrasAccess)
    }
  }
}

struct LayoutMeasurementError: Error, CustomStringConvertible {
  let message: String

  var description: String { message }
}

/// Fixture-only metadata access. A chaptered fixture starts its one chapter after the static
/// playhead, so chapter clocks stay byte-identical to a chapterless fixture, while the metadata row
/// still shows that a confirmed chapter map is present.
private func makeFixtureExtrasAccess(
  chapterStates: [String: ExpandedPlayerChromeChapterState]
) -> FakeItemDetailExtrasAccess {
  let chaptered = ItemDetailExtras(
    seriesName: nil, narrator: "Fixture Author",
    chapters: [ItemChapterInfo(title: "Fixture Chapter", start: 60, end: 3_600)])
  let chapterless = ItemDetailExtras(seriesName: nil, narrator: "Fixture Author", chapters: [])
  var extrasByItem: [String: ItemDetailExtras?] = [:]
  for (itemID, state) in chapterStates {
    switch state {
    case .unresolved: extrasByItem[itemID] = .some(nil)
    case .chaptered: extrasByItem[itemID] = chaptered
    case .chapterless, .noChapterRow: extrasByItem[itemID] = chapterless
    }
  }
  let extras = FakeItemDetailExtrasAccess()
  extras.stubResults { [extrasByItem] itemID in
    if let entry = extrasByItem[itemID] { return entry }
    return chapterless
  }
  return extras
}

private func makeFailingPlaybackSyncing() -> FakePlaybackSyncing {
  let sync = FakePlaybackSyncing()
  sync.stubStartSession(.failure(PlaybackCoordinatorError.unknownItem("fixture-item")))
  return sync
}
