import ABSApi
import AppModel
import DesignSystem
import MediaPlayer
import Persistence
import PlayerCore
import SyncEngine
import Testing
import UIKit

@testable import Whirr

extension NowPlayingMetadataTests {

  // MARK: - High-fidelity artwork width: shares the expanded-player request rung

  @Test(
    "Now Playing requests the quantized high-fidelity width the expanded player would request on the same scale"
  )
  func nowPlayingRequestsTheQuantizedHighFidelityWidth() async throws {
    let player = FakeAdapterPlaybackControlling()
    player.state = Self.state(position: 10)
    let sink = FakeNowPlayingInfoSink()
    let itemInfoProvider = FakeNowPlayingItemInfoProviding()
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let transport = FakeCoverHTTPClient(imageData: onePixelPNGData)
    let coverImageClient = CoverImageClient(server: server, httpClient: transport)
    let scale: CGFloat = 3.0

    let adapter = NowPlayingMetadataAdapter(
      sink: sink, controller: player, itemInfoProvider: itemInfoProvider, coverImageClient: coverImageClient,
      displayScale: scale)
    await adapter.waitForPendingArtworkForTesting()

    let requestedWidth = try #require(transport.lastRequest.flatMap(Self.requestedWidth(from:)))
    let expandedPlayerWidth = CoverRequest.quantizedWidth(
      Int((ExpandedPlayerView.artworkRequestSize * scale).rounded()))
    #expect(requestedWidth == expandedPlayerWidth)
    withExtendedLifetime(adapter) {}
  }

  @Test(
    "each idiom's high-fidelity rungs are pinned, and the phone keeps sharing detail's 2x entry"
  )
  func eachIdiomKeepsItsIntendedHighFidelityWidths() {
    // Pinned per idiom at both supported scales, because the rung is idiom-scoped: a phone that
    // can only ever draw the 380pt compact cap must not pay for the iPad's 620pt one.
    for scale in [CGFloat(2), CGFloat(3)] {
      let detail = CoverRequest.quantizedWidth(Int((ItemDetailView.coverDisplaySize * scale).rounded()))
      let phone = CoverRequest.quantizedWidth(
        Int((ExpandedPlayerView.artworkRequestSize(forIdiom: .phone) * scale).rounded()))
      let pad = CoverRequest.quantizedWidth(
        Int((ExpandedPlayerView.artworkRequestSize(forIdiom: .pad) * scale).rounded()))

      #expect(
        phone == (scale == 2 ? 768 : 1280),
        "the phone player/Now Playing rung must not drift at \(Int(scale))x")
      #expect(
        pad == (scale == 2 ? 1280 : 2048),
        "the iPad player/Now Playing rung must not drift at \(Int(scale))x")
      #expect(
        detail == (scale == 2 ? 768 : 1024),
        "the detail rung must not drift at \(Int(scale))x")
    }

    // On a 2x phone one entry still serves detail and the player, which an idiom-blind 620pt rung
    // would lose.
    #expect(
      CoverRequest.quantizedWidth(Int(ItemDetailView.coverDisplaySize * 2))
        == CoverRequest.quantizedWidth(Int(ExpandedPlayerView.artworkRequestSize(forIdiom: .phone) * 2)))
    // The iPad does not converge: its cover is genuinely larger.
    #expect(
      CoverRequest.quantizedWidth(Int(ItemDetailView.coverDisplaySize * 2))
        != CoverRequest.quantizedWidth(Int(ExpandedPlayerView.artworkRequestSize(forIdiom: .pad) * 2)))
  }

  @Test(
    "the expanded player keys its artwork on the fixed request size, so a container that resolves a smaller cover still shares Now Playing's rung"
  )
  func expandedPlayerKeysArtworkOnTheRequestSizeNotResolvedGeometry() {
    // A short 3x screen (375×812 pt class) resolves well below the compact 380pt cap, while the
    // player and Now Playing retain the fixed request rung for the idiom.
    let resolved = ExpandedPlayerView.coverSize(
      availableWidth: 375, height: 780, upperContentHeight: 420)
    #expect(resolved < ExpandedPlayerView.maximumCoverSize)

    let resolvedRung = CoverRequest.quantizedWidth(Int((resolved * 3).rounded()))
    let requestRung = CoverRequest.quantizedWidth(
      Int((ExpandedPlayerView.artworkRequestSize * 3).rounded()))
    // The divergence is real. Keying on resolved geometry cost the lock screen its warm entry, so
    // this is pinned to catch a future geometry change that removes it.
    #expect(resolvedRung != requestRung)

    // The player and Now Playing derive their key from one number for the running idiom, so the
    // rung is the same whatever geometry the player resolves.
    #expect(
      ExpandedPlayerView.artworkRequestSize(forIdiom: .pad)
        == ExpandedPlayerLayoutPresentation.regularArtworkMaximumSize)
    #expect(ExpandedPlayerView.artworkRequestSize(forIdiom: .phone) == ExpandedPlayerView.maximumCoverSize)
    for scale in [CGFloat(2), CGFloat(3)] {
      let nowPlaying = CoverRequest.quantizedWidth(
        Int((ExpandedPlayerView.artworkRequestSize(forIdiom: .pad) * scale).rounded()))
      #expect(nowPlaying == (scale == 2 ? 1280 : 2048))
    }
  }

  @Test("a wide, tall container still caps the resolved cover at the maximum")
  func expandedPlayerCoverSizeCapsOnLargeContainers() {
    #expect(
      ExpandedPlayerView.coverSize(
        availableWidth: 1024, height: 1300, upperContentHeight: 420)
        == ExpandedPlayerView.maximumCoverSize)
    // And the floor holds on a very short container rather than collapsing the cover.
    #expect(
      ExpandedPlayerView.coverSize(availableWidth: 375, height: 300, upperContentHeight: 420)
        == ExpandedPlayerView.minimumCoverSize)
  }

  /// These cases cover only the flexible upper region's artwork arithmetic: the measured
  /// metadata/status band reduces the cover bound without asserting anything about control
  /// positioning.
  @Test("a taller metadata/status band takes exactly that much off the cover")
  func expandedPlayerCoverAbsorbsTheBandsVariance() {
    // The flexible upper region's available height for a 402×874pt player.
    let height: CGFloat = 750
    let oneLineTitleWithChapterRow: CGFloat = 400
    let threeLineTitleWithChapterRow = oneLineTitleWithChapterRow + 56

    let roomy = ExpandedPlayerView.coverSize(
      availableWidth: 402, height: height, upperContentHeight: oneLineTitleWithChapterRow)
    let tight = ExpandedPlayerView.coverSize(
      availableWidth: 402, height: height, upperContentHeight: threeLineTitleWithChapterRow)

    // Point for point: the band's extra lines come out of the artwork bound.
    #expect(roomy - tight == 56)
    // Both stay in the unclamped arithmetic range, so the exact difference remains observable.
    #expect(tight > ExpandedPlayerView.minimumCoverSize)
    #expect(roomy < ExpandedPlayerView.maximumCoverSize)
  }

  /// The unmeasured first frame. `upperContentHeight` is zero until a layout pass reports the
  /// metadata/status band, so the cover runs the same arithmetic against a seeded band.
  @Test("an unmeasured page seeds the band, not the cover")
  func expandedPlayerCoverSeedsBeforeItIsMeasured() {
    let seeded = ExpandedPlayerView.coverSize(
      availableWidth: 402, height: 400, upperContentHeight: 0)

    // The unmeasured band still supplies the fallback input, but the height share binds first:
    // 0.70 × 400 = 280, below the seeded-band bound of 304.
    #expect(seeded == ExpandedPlayerView.coverHeightShare * 400)
    #expect(seeded < ExpandedPlayerView.maximumCoverSize)
    #expect(seeded > ExpandedPlayerView.minimumCoverSize)

    // The fallback remains active when the band term is the smallest unclamped bound: at 500pt,
    // a measured 250pt band leaves 226pt after the 24pt gap, below the 350pt height-share bound.
    let bandBound = ExpandedPlayerView.coverSize(
      availableWidth: 402, height: 500, upperContentHeight: 250)
    #expect(bandBound == 500 - WhirrSpacing.large - 250)
  }

  /// The upper region a 393×852 phone resolves, measured off the hosted page in
  /// `ExpandedPlayerChromeLayoutTests`: 852 less the top inset, dismiss handle, chrome and bottom
  /// clearance. The old `height * 0.42` seed was tuned for `height` as the whole page below the
  /// handle; against this smaller number it lands on the floor, so a fresh player opened clamped
  /// at `minimumCoverSize` and grew once the band reported. Seeding the band settles frame one.
  @Test("the first frame seeds the cover where the measured pass leaves it")
  func expandedPlayerCoverSeedDoesNotSettleVisibly() {
    let upperRegionHeight: CGFloat = 501.67
    let width: CGFloat = 393
    // The band's real range on this page: a title and byline alone, or the same plus a chapter
    // row.
    let bands: [CGFloat] = [49.33, 101.33]

    let seeded = ExpandedPlayerView.coverSize(
      availableWidth: width, height: upperRegionHeight, upperContentHeight: 0)
    for band in bands {
      // Exact, not approximate: this page is tall enough that the column's width caps the cover for
      // the band's whole range, so the first frame is the settled frame.
      #expect(
        ExpandedPlayerView.coverSize(
          availableWidth: width, height: upperRegionHeight, upperContentHeight: band) == seeded)
    }

    // The old ratio put the same region a hair above the floor. The grow to 345 read as the page
    // settling in front of the listener.
    #expect(upperRegionHeight * 0.42 < ExpandedPlayerView.minimumCoverSize + 1)

    // Where height or the band binds, the share absorbs part of the seed's error rather than
    // allowing it to move the cover by the band's full variance. This short container exercises
    // both paths.
    let shortRegion: CGFloat = 400
    let shortSeed = ExpandedPlayerView.coverSize(
      availableWidth: 402, height: shortRegion, upperContentHeight: 0)
    for band in bands {
      let settled = ExpandedPlayerView.coverSize(
        availableWidth: 402, height: shortRegion, upperContentHeight: band)
      #expect(settled > ExpandedPlayerView.minimumCoverSize)
      let drift = abs(shortSeed - settled)
      #expect(
        drift <= abs(ExpandedPlayerView.upperContentHeightSeed - band),
        "seed \(shortSeed) settles to \(settled) for a \(band)pt band")
    }

    // The chaptered band still exercises the fallback clamp: 400 - 24 - 101.33 = 274.67,
    // below the 280pt share bound and above the 210pt floor.
    let bandBound = ExpandedPlayerView.coverSize(
      availableWidth: 402, height: shortRegion, upperContentHeight: bands[1])
    #expect(
      abs(bandBound - (shortRegion - WhirrSpacing.large - bands[1])) < 0.001)
  }

  @Test("upper layout keeps its share cap, fallback, floor, and slack bounds")
  func expandedPlayerUpperLayoutResolvesItsBounds() {
    /// Every point of the region is accounted for by one of the three returned numbers plus the
    /// band. This is the property that keeps slack from being stranded below the metadata: a page
    /// that does not fill its region here leaves a void the chrome cannot close, because the
    /// column above it is top-aligned in a region-sized frame.
    func expectFillsRegion(
      _ layout: (coverSize: CGFloat, topInset: CGFloat, coverToMetadataSpacing: CGFloat),
      height: CGFloat, band: CGFloat, label: String
    ) {
      let occupied = layout.topInset + layout.coverSize + layout.coverToMetadataSpacing + band
      #expect(
        abs(occupied - height) < 0.001,
        "\(label) occupies \(occupied) of \(height)")
      #expect(
        layout.coverToMetadataSpacing >= WhirrSpacing.large,
        "\(label) seam \(layout.coverToMetadataSpacing) fell below the design gap")
    }

    let tall = ExpandedPlayerView.upperLayout(
      availableWidth: 402, height: 500, upperContentHeight: 100)
    #expect(tall.coverSize == ExpandedPlayerView.coverHeightShare * 500)

    let short = ExpandedPlayerView.upperLayout(
      availableWidth: 402, height: 500, upperContentHeight: 250)
    #expect(short.coverSize == 500 - WhirrSpacing.large - 250)

    let floored = ExpandedPlayerView.upperLayout(
      availableWidth: 393, height: 290.67, upperContentHeight: 101.33)
    #expect(floored.coverSize == ExpandedPlayerView.minimumCoverSize)

    let narrow = ExpandedPlayerView.upperLayout(
      availableWidth: 375, height: 1200, upperContentHeight: 100)
    #expect(narrow.coverSize == 375 - (WhirrSpacing.large * 2))

    let noSlack = ExpandedPlayerView.upperLayout(
      availableWidth: 393, height: 400, upperContentHeight: 200)
    #expect(noSlack.topInset == 0)

    let cappedSlack = ExpandedPlayerView.upperLayout(
      availableWidth: 393, height: 1200, upperContentHeight: 100)
    #expect(cappedSlack.topInset == ExpandedPlayerView.upperTopSlackCap)

    expectFillsRegion(tall, height: 500, band: 100, label: "share-capped")
    expectFillsRegion(short, height: 500, band: 250, label: "band-bound")
    expectFillsRegion(narrow, height: 1200, band: 100, label: "width-capped")
    expectFillsRegion(cappedSlack, height: 1200, band: 100, label: "slack-capped")

    // The two pages with nothing to distribute keep the plain design gap rather than borrowing
    // from a slack that is already zero.
    #expect(noSlack.coverToMetadataSpacing == WhirrSpacing.large)
    #expect(floored.coverToMetadataSpacing == WhirrSpacing.large)

    // Past the cap the seam takes the whole remainder, so the top inset stops growing and the
    // region is still fully spent. Without this, a tall page would reopen the void.
    #expect(
      cappedSlack.coverToMetadataSpacing
        > WhirrSpacing.large + ExpandedPlayerView.upperTopSlackCap)
  }

  /// A narrow phone runs out of width before it runs out of height. The cover is square, so the
  /// column's own width caps it and the leftover height settles above it rather than stretching
  /// artwork past the page's horizontal padding.
  @Test("the column's width still caps the cover before its height does")
  func expandedPlayerCoverStaysInsideItsColumn() {
    let resolved = ExpandedPlayerView.coverSize(
      availableWidth: 402, height: 1200, upperContentHeight: 400)

    #expect(resolved == 402 - (WhirrSpacing.large * 2))
  }
}
