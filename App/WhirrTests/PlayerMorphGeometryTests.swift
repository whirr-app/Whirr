import ABSApi
import AppModel
import SwiftUI
import Testing
import UIKit

@testable import Whirr

@MainActor
@Suite("Player morph geometry relay", .serialized)
struct PlayerMorphGeometryTests {
  private static let window = CGRect(x: 0, y: 0, width: 402, height: 874)
  private static let bar = CGRect(x: 21, y: 733, width: 360, height: 52)
  private static let barCover = CGRect(x: 33, y: 737, width: 44, height: 44)
  private static let pageCover = CGRect(x: 41, y: 140, width: 320, height: 320)

  nonisolated private static func key(
    item: String = "item-1", revision: String = "r1", variant: ArtworkVariant
  ) -> ArtworkKey {
    ArtworkKey(
      accountScope: ArtworkAccountScope("account"), itemID: item, variant: variant,
      revision: ArtworkRevision(revision))
  }

  nonisolated private static let barKey = key(
    variant: .libraryThumbnail(displaySize: 44, displayScale: 3))
  nonisolated private static let pageKey = key(
    variant: .highFidelity(displaySize: 380, displayScale: 3))

  /// Puts one anchor per role straight into `window`, registered with `geometry`. Returned so a
  /// case can move, empty or detach one of them.
  @discardableResult
  private func install(
    in window: UIWindow, geometry: PlayerMorphGeometry,
    skipping skipped: PlayerMorphGeometry.Role? = nil
  ) -> [PlayerMorphGeometry.Role: PlayerMorphAnchorView] {
    var anchors: [PlayerMorphGeometry.Role: PlayerMorphAnchorView] = [:]
    let layout: [(PlayerMorphGeometry.Role, CGRect, ArtworkKey?)] = [
      (.bar, Self.bar, nil), (.barCover, Self.barCover, Self.barKey),
      (.pageCover, Self.pageCover, Self.pageKey),
    ]
    for (role, frame, key) in layout where role != skipped {
      let anchor = PlayerMorphAnchorView(frame: frame)
      anchor.configure(geometry: geometry, role: role, coverKey: key)
      window.addSubview(anchor)
      anchors[role] = anchor
    }
    return anchors
  }

  private func landing() -> PlayerMorphGeometry {
    let geometry = PlayerMorphGeometry()
    geometry.canLand = { true }
    return geometry
  }

  // MARK: - Whether there is a bar to land on

  @Test(
    "the bar can be landed on only in the shell with the accessory up",
    arguments: [
      (NavigationModel.Presentation.shell, true, true),
      // Logout: `resetForLogout()` moves to `.setup` and collapses with the slide.
      (.setup, true, false),
      (.removalPending, true, false),
      // Nothing playing, or a selection screen holding the bottom bar: no accessory.
      (.shell, false, false),
      (.setup, false, false),
    ])
  func canLandRule(
    presentation: NavigationModel.Presentation, isAccessoryPresented: Bool, expected: Bool
  ) {
    #expect(
      PlayerMorphGeometry.canLand(
        presentation: presentation, isAccessoryPresented: isAccessoryPresented) == expected)
  }

  @Test("a new relay never lands until the shell supplies its rule")
  func defaultCannotLand() async {
    await withKeyWindow(bounds: Self.window) { scope in
      let geometry = PlayerMorphGeometry()
      install(in: scope.window, geometry: geometry)
      #expect(geometry.snapshot() == nil)
    }
  }

  // MARK: - Reading the anchors

  @Test("with every anchor in place the snapshot carries their window frames and cover keys")
  func snapshotReadsAnchors() async throws {
    try await withKeyWindow(bounds: Self.window) { scope in
      let geometry = landing()
      install(in: scope.window, geometry: geometry)
      let snapshot = try #require(geometry.snapshot())
      #expect(snapshot.bar == Self.bar)
      #expect(snapshot.barCover == Self.barCover)
      #expect(snapshot.pageCover == Self.pageCover)
      #expect(snapshot.barCoverKey == Self.barKey)
      #expect(snapshot.pageCoverKey == Self.pageKey)
      #expect(snapshot.barCornerRadius == 26)
    }
  }

  @Test("canLand is asked at read time, so a logout after registration still slides")
  func canLandIsReadLive() async {
    await withKeyWindow(bounds: Self.window) { scope in
      let geometry = landing()
      install(in: scope.window, geometry: geometry)
      #expect(geometry.snapshot() != nil)
      geometry.canLand = { false }
      #expect(geometry.snapshot() == nil)
    }
  }

  /// The bar and its cover are where the morph lands, so losing either means a slide. The page's
  /// cover only starts the cover's flight: without it the morph still runs, with no flight.
  private func expectLost(
    _ role: PlayerMorphGeometry.Role, in geometry: PlayerMorphGeometry,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let snapshot = geometry.snapshot()
    guard role == .pageCover else {
      #expect(snapshot == nil, sourceLocation: sourceLocation)
      return
    }
    #expect(snapshot != nil, sourceLocation: sourceLocation)
    #expect(snapshot?.pageCover == nil, sourceLocation: sourceLocation)
    #expect(snapshot?.pageCoverKey == nil, sourceLocation: sourceLocation)
    #expect(snapshot?.coversMatch == false, sourceLocation: sourceLocation)
  }

  @Test(
    "a missing bar anchor gives no snapshot; a missing page cover drops only the flight",
    arguments: PlayerMorphGeometry.Role.allCases)
  func missingAnchor(role: PlayerMorphGeometry.Role) async {
    await withKeyWindow(bounds: Self.window) { scope in
      let geometry = landing()
      install(in: scope.window, geometry: geometry, skipping: role)
      expectLost(role, in: geometry)
    }
  }

  @Test(
    "an anchor that has left its window is treated as missing",
    arguments: PlayerMorphGeometry.Role.allCases)
  func windowlessAnchor(role: PlayerMorphGeometry.Role) async {
    await withKeyWindow(bounds: Self.window) { scope in
      let geometry = landing()
      let anchors = install(in: scope.window, geometry: geometry)
      anchors[role]?.removeFromSuperview()
      expectLost(role, in: geometry)
    }
  }

  @Test("the snapshot carries the cover the bar is drawing, only while it is the bar's key")
  func barCoverDrawnImage() async {
    await withKeyWindow(bounds: Self.window) { scope in
      let geometry = landing()
      let anchors = install(in: scope.window, geometry: geometry)
      #expect(geometry.snapshot()?.barCoverImage == nil)

      let drawn = DrawnArtwork()
      let image = UIImage()
      drawn.note(image, for: Self.barKey)
      anchors[.barCover]?.configure(
        geometry: geometry, role: .barCover, coverKey: Self.barKey, drawnCover: drawn)
      #expect(geometry.snapshot()?.barCoverImage === image)

      // The bar has moved to another cover and not drawn it yet.
      anchors[.barCover]?.configure(
        geometry: geometry, role: .barCover, coverKey: Self.pageKey, drawnCover: drawn)
      #expect(geometry.snapshot()?.barCoverImage == nil)

      drawn.note(nil, for: Self.barKey)
      anchors[.barCover]?.configure(
        geometry: geometry, role: .barCover, coverKey: Self.barKey, drawnCover: drawn)
      #expect(geometry.snapshot()?.barCoverImage == nil)
    }
  }

  @Test("the snapshot carries the page cover the bar warmed, only for the page's own key")
  func warmedPageCoverImage() async {
    await withKeyWindow(bounds: Self.window) { scope in
      let geometry = landing()
      let anchors = install(in: scope.window, geometry: geometry)
      #expect(geometry.snapshot()?.warmedPageCoverImage == nil)

      let warmed = DrawnArtwork()
      let image = UIImage()
      warmed.note(image, for: Self.pageKey)
      anchors[.barCover]?.configure(
        geometry: geometry, role: .barCover, coverKey: Self.barKey, warmedPageCover: warmed)
      #expect(geometry.snapshot()?.warmedPageCoverImage === image)

      // The page keys its cover differently from what the bar warmed.
      let older = PlayerMorphFixture.key(
        revision: "r0", variant: .highFidelity(displaySize: 380, displayScale: 3))
      anchors[.pageCover]?.configure(geometry: geometry, role: .pageCover, coverKey: older)
      #expect(geometry.snapshot()?.warmedPageCoverImage == nil)

      // No page cover on screen: nothing names the image to fly.
      anchors[.pageCover]?.removeFromSuperview()
      #expect(geometry.snapshot()?.warmedPageCoverImage == nil)
    }
  }

  @Test("the snapshot carries the cover the page is drawing, only while it is the page's key")
  func pageCoverDrawnImage() async {
    await withKeyWindow(bounds: Self.window) { scope in
      let geometry = landing()
      let anchors = install(in: scope.window, geometry: geometry)
      #expect(geometry.snapshot()?.pageCoverImage == nil)

      let drawn = DrawnArtwork()
      let image = UIImage()
      drawn.note(image, for: Self.pageKey)
      anchors[.pageCover]?.configure(
        geometry: geometry, role: .pageCover, coverKey: Self.pageKey, drawnCover: drawn)
      #expect(geometry.snapshot()?.pageCoverImage === image)

      // The page has moved to another cover and not drawn it yet.
      let older = PlayerMorphFixture.key(
        revision: "r0", variant: .highFidelity(displaySize: 380, displayScale: 3))
      anchors[.pageCover]?.configure(
        geometry: geometry, role: .pageCover, coverKey: older, drawnCover: drawn)
      #expect(geometry.snapshot()?.pageCoverImage == nil)
    }
  }

  @Test("a released anchor is treated as missing; the relay holds anchors weakly")
  func releasedAnchor() async {
    await withKeyWindow(bounds: Self.window) { scope in
      let geometry = landing()
      install(in: scope.window, geometry: geometry, skipping: .barCover)
      do {
        let anchor = PlayerMorphAnchorView(frame: Self.barCover)
        anchor.configure(geometry: geometry, role: .barCover, coverKey: Self.barKey)
        scope.window.addSubview(anchor)
        #expect(geometry.snapshot() != nil)
        anchor.removeFromSuperview()
      }
      #expect(geometry.snapshot() == nil)
    }
  }

  @Test("an empty anchor frame is treated as missing", arguments: PlayerMorphGeometry.Role.allCases)
  func emptyAnchor(role: PlayerMorphGeometry.Role) async {
    await withKeyWindow(bounds: Self.window) { scope in
      let geometry = landing()
      let anchors = install(in: scope.window, geometry: geometry)
      anchors[role]?.frame.size = CGSize(width: 0, height: 52)
      expectLost(role, in: geometry)
    }
  }

  /// The page cover is the case that matters on device: while a pull-down's slide is paused, the
  /// page reports its end position, so its cover reads a screen height too low.
  @Test("an off-screen anchor is treated as missing", arguments: PlayerMorphGeometry.Role.allCases)
  func offScreenAnchor(role: PlayerMorphGeometry.Role) async {
    await withKeyWindow(bounds: Self.window) { scope in
      let geometry = landing()
      let anchors = install(in: scope.window, geometry: geometry)
      anchors[role]?.frame.origin.y = Self.window.maxY + 10
      expectLost(role, in: geometry)
    }
  }

  @Test(
    "an anchor in a different window from the bar is treated as missing",
    arguments: [PlayerMorphGeometry.Role.barCover, .pageCover])
  func anchorsInDifferentWindows(role: PlayerMorphGeometry.Role) async throws {
    try await withKeyWindow(bounds: Self.window) { scope in
      let geometry = landing()
      let anchors = install(in: scope.window, geometry: geometry)
      let other = UIWindow(windowScene: try #require(scope.window.windowScene))
      other.frame = Self.window
      other.isHidden = false
      defer { other.isHidden = true }
      other.addSubview(try #require(anchors[role]))
      expectLost(role, in: geometry)
    }
  }

  @Test("the newest anchor for a role wins, and a stale one cannot unregister it")
  func newestAnchorWins() async throws {
    try await withKeyWindow(bounds: Self.window) { scope in
      let geometry = landing()
      let anchors = install(in: scope.window, geometry: geometry)
      let moved = CGRect(x: 21, y: 700, width: 360, height: 52)
      let replacement = PlayerMorphAnchorView(frame: moved)
      replacement.configure(geometry: geometry, role: .bar, coverKey: nil)
      scope.window.addSubview(replacement)
      // The old view leaving its window must not take the new registration with it.
      anchors[.bar]?.removeFromSuperview()
      let snapshot = try #require(geometry.snapshot())
      #expect(snapshot.bar == moved)
    }
  }

  @Test("a page dragged down reports its cover where it is on screen")
  func transformedAncestorIsIncluded() async throws {
    try await withKeyWindow(bounds: Self.window) { scope in
      let geometry = landing()
      install(in: scope.window, geometry: geometry, skipping: .pageCover)
      let page = UIView(frame: Self.window)
      scope.window.addSubview(page)
      let anchor = PlayerMorphAnchorView(frame: Self.pageCover)
      anchor.configure(geometry: geometry, role: .pageCover, coverKey: Self.pageKey)
      page.addSubview(anchor)
      page.transform = CGAffineTransform(translationX: 0, y: 200)
      let snapshot = try #require(geometry.snapshot())
      #expect(snapshot.pageCover == Self.pageCover.offsetBy(dx: 0, dy: 200))
    }
  }

  // MARK: - Covers

  @Test(
    "the flight runs only when both covers show the same image",
    arguments: [
      (Self.barKey, Self.pageKey, true),
      (Self.barKey, key(revision: "r2", variant: .highFidelity(displaySize: 380, displayScale: 3)), false),
      (Self.barKey, key(item: "item-2", variant: .highFidelity(displaySize: 380, displayScale: 3)), false),
    ])
  func coversMatch(bar: ArtworkKey, page: ArtworkKey, expected: Bool) {
    let snapshot = PlayerMorphGeometry.Snapshot(
      bar: Self.bar, barCover: Self.barCover, barCoverKey: bar,
      pageCover: Self.pageCover, pageCoverKey: page)
    #expect(snapshot.coversMatch == expected)
  }

  @Test("the bar and the page match on an episode with its own art when both resolve it")
  func barAndPageResolveOneEpisodeSource() throws {
    let episode = ArtworkSource.rss(
      try #require(
        RSSArtworkSource(
          feedID: 7, artworkURL: URL(string: "https://img.example.test/episode.jpg")!)))
    let show = ArtworkSource.rss(
      try #require(
        RSSArtworkSource(
          feedID: 7, artworkURL: URL(string: "https://img.example.test/show.jpg")!)))
    // The bar resolves from the observed image, the page from the bar's seed: one source.
    let bar = PlayerArtworkResolution(
      episodeSource: episode, followedShowSource: show, loadedSource: nil)
    let page = PlayerArtworkResolution(
      episodeSource: episode, followedShowSource: show, loadedSource: nil)
    func key(_ resolution: PlayerArtworkResolution, _ variant: ArtworkVariant) -> ArtworkKey {
      ArtworkKey(
        source: resolution.source ?? show, itemID: "rss:7", variant: variant,
        revision: ArtworkRevision("r1"))
    }
    func snapshot(bar: ArtworkKey, page: ArtworkKey) -> PlayerMorphGeometry.Snapshot {
      PlayerMorphGeometry.Snapshot(
        bar: Self.bar, barCover: Self.barCover, barCoverKey: bar,
        pageCover: Self.pageCover, pageCoverKey: page)
    }
    let barKey = key(bar, .libraryThumbnail(displaySize: 44, displayScale: 3))
    let pageKey = key(page, .highFidelity(displaySize: 380, displayScale: 3))

    #expect(snapshot(bar: barKey, page: pageKey).coversMatch)

    // The page still drawing the show while the bar draws the episode is the degraded flight.
    let showOnly = PlayerArtworkResolution(
      episodeSource: nil, followedShowSource: show, loadedSource: nil)
    #expect(
      snapshot(
        bar: barKey, page: key(showOnly, .highFidelity(displaySize: 380, displayScale: 3))
      ).coversMatch == false)
  }

  @Test("a cover with no published key never matches")
  func missingKeyNeverMatches() {
    let snapshot = PlayerMorphGeometry.Snapshot(
      bar: Self.bar, barCover: Self.barCover, barCoverKey: nil,
      pageCover: Self.pageCover, pageCoverKey: Self.pageKey)
    #expect(snapshot.coversMatch == false)
  }

  // MARK: - SwiftUI anchors

  @Test("a SwiftUI anchor reports its view's window frame")
  func hostedAnchorReportsFrame() async throws {
    try await withKeyWindow(bounds: Self.window) { scope in
      let geometry = landing()
      scope.host(HostedAnchors(geometry: geometry, coverScale: 1))
      scope.window.layoutIfNeeded()
      let snapshot = try #require(geometry.snapshot())
      #expect(snapshot.bar.size == CGSize(width: 360, height: 52))
      #expect(snapshot.barCover.size == CGSize(width: 44, height: 44))
      #expect(snapshot.pageCover?.size == CGSize(width: 200, height: 200))
      #expect(snapshot.barCoverKey == Self.barKey)
      #expect(snapshot.pageCoverKey == Self.pageKey)
    }
  }

  @Test("an anchor inside a scale effect reports the scaled frame, as the paused page draws it")
  func hostedAnchorInsideScaleEffect() async throws {
    try await withKeyWindow(bounds: Self.window) { scope in
      let geometry = landing()
      scope.host(HostedAnchors(geometry: geometry, coverScale: 0.92))
      scope.window.layoutIfNeeded()
      let cover = try #require(geometry.snapshot()?.pageCover)
      #expect(abs(cover.width - 184) < 0.5)
      #expect(abs(cover.height - 184) < 0.5)
    }
  }

  @Test("without a relay in the environment no anchor is added")
  func noRelayNoAnchor() async {
    await withKeyWindow(bounds: Self.window) { scope in
      let host = scope.host(
        Color.clear.frame(width: 44, height: 44)
          .playerMorphAnchor(.barCover, coverKey: { Self.barKey }))
      scope.window.layoutIfNeeded()
      #expect(Self.anchorViews(in: host.view).isEmpty)
    }
  }

  private static func anchorViews(in view: UIView) -> [PlayerMorphAnchorView] {
    ((view as? PlayerMorphAnchorView).map { [$0] } ?? [])
      + view.subviews.flatMap(anchorViews(in:))
  }
}

private struct HostedAnchors: View {
  let geometry: PlayerMorphGeometry
  let coverScale: CGFloat

  var body: some View {
    VStack(spacing: 40) {
      Color.gray.frame(width: 200, height: 200)
        .playerMorphAnchor(.pageCover, coverKey: { PlayerMorphGeometryTests.pageKeyForHost })
        .scaleEffect(coverScale)
      HStack {
        Color.gray.frame(width: 44, height: 44)
          .playerMorphAnchor(.barCover, coverKey: { PlayerMorphGeometryTests.barKeyForHost })
        Spacer()
      }
      .frame(width: 360, height: 52)
      .playerMorphAnchor(.bar)
    }
    .environment(\.playerMorphGeometry, geometry)
  }
}

extension PlayerMorphGeometryTests {
  fileprivate static var pageKeyForHost: ArtworkKey { pageKey }
  fileprivate static var barKeyForHost: ArtworkKey { barKey }
}
