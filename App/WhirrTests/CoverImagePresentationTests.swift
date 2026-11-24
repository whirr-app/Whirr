import ABSApi
import Foundation
import Persistence
import SwiftUI
import TestSupport
import Testing
import UIKit

@testable import Whirr

/// Covers the `.fitTransparent` presentation mode. These pin two properties a plumbing-only value
/// suite would miss: `.fitTransparent` fits a portrait cover whole and leaves its side margins
/// transparent (the surface behind shows through, not painted bars), while `.fill` crops it. The
/// mode is inert by default and cannot leak into the seed or placeholder branches. Geometry is
/// asserted with `ImageRenderer` pixel sampling.
@MainActor
struct CoverImagePresentationTests {

  private static func portraitImage() -> UIImage {
    UIImage(data: ImageTestFixtures.portraitCoverData)!
  }

  @Test("The portrait fixture is genuinely portrait and decodes")
  func portraitFixtureIsPortrait() {
    let image = Self.portraitImage()
    #expect(image.size.width == 200)
    #expect(image.size.height == 300)
    #expect(image.size.height > image.size.width)
  }

  @Test("Presentation defaults to .fill, so every existing call site is unchanged")
  func presentationDefaultsToFill() throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let view = CoverImageView(
      itemID: "item", title: "Title", displaySize: 140,
      client: CoverImageClient(server: server), source: nil, revision: .unversioned)
    #expect(view.presentation == .fill)
  }

  @Test("RSS artwork uses its declared source and no artwork uses generated art")
  func rssArtworkSourceResolvesBeforeGeneratedFallback() throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let client = CoverImageClient(server: server)
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: 7)).itemId
    let artworkURL = try #require(URL(string: "https://images.example.test/show.jpg"))
    let feedURL = try #require(URL(string: "https://feeds.example.test/show.xml"))
    let rssSource = try #require(
      RSSArtworkSource(feedID: 7, artworkURL: artworkURL, feedURL: feedURL))

    let declaredKey = CoverImageView.artworkKey(
      itemID: itemID,
      client: client,
      source: .rss(rssSource),
      displaySize: 44,
      displayScale: 2,
      role: .libraryThumbnail, revision: .unversioned)
    let noArtworkKey = CoverImageView.artworkKey(
      itemID: itemID,
      client: client,
      source: nil,
      displaySize: 44,
      displayScale: 2,
      role: .libraryThumbnail, revision: .unversioned)

    #expect(declaredKey.source == .rss(rssSource))
    #expect(noArtworkKey.source == .generated(ArtworkAccountScope("artwork:generated:rss")))
  }

  @Test("a generated unavailable outcome does not mark the key missing, but a real source does")
  func generatedUnavailableDoesNotMarkMissingButRealSourceDoes() throws {
    let generatedKey = Self.key(
      source: .generated(ArtworkAccountScope("artwork:generated:rss")))
    let rssKey = Self.rssKey()

    #expect(
      CoverImageView.shouldMarkMissing(for: .unavailable, key: generatedKey) == false)
    #expect(CoverImageView.shouldMarkMissing(for: .unavailable, key: rssKey))
  }

  /// A "no cover" verdict is about one moment: a server may still be attaching the cover of a book
  /// uploaded minutes ago. Surfaces that show one cover ask again. A library grid does not, because
  /// a screenful of missing thumbnails would become a screenful of extra requests for tiles already
  /// scrolled past.
  @Test("only the single-cover surfaces re-ask after being told the item has no artwork")
  func onlySingleCoverSurfacesReprobe() {
    #expect(CoverImageView.reprobeSchedule(for: .libraryThumbnail, outcome: .unavailable).isEmpty)
    #expect(
      CoverImageView.reprobeSchedule(for: .highFidelity, outcome: .unavailable)
        == [.seconds(30), .seconds(150)])
    #expect(
      CoverImageView.reprobeSchedule(for: .homeCard, outcome: .unavailable)
        == [.seconds(30), .seconds(150)])
  }

  /// A transport failure leaves a tile permanently blank, and it says something about the attempt,
  /// not the item. So every surface retries it, including the grids that stay silent after a
  /// genuine "no artwork" verdict.
  @Test("every surface retries a transport failure on the same backoff")
  func everySurfaceRetriesATransportFailure() {
    let expected: [Duration] = [.seconds(2), .seconds(15), .seconds(60)]

    for role in [CoverImageView.Role.libraryThumbnail, .homeCard, .highFidelity] {
      #expect(CoverImageView.reprobeSchedule(for: role, outcome: .failed) == expected)
    }
  }

  /// A smaller cached rung of the same item and revision proves the cover exists. That outranks a
  /// larger width's "no cover", which was asked for before the server attached it. Generated art
  /// would replace a real cover the device already holds.
  @Test("a cached smaller cover outranks an unavailable verdict for the larger width")
  func seededUnavailableDoesNotMarkMissing() {
    #expect(
      CoverImageView.shouldMarkMissing(for: .unavailable, key: Self.rssKey(), seeded: true)
        == false)
    #expect(
      CoverImageView.shouldMarkMissing(for: .unavailable, key: Self.rssKey(), seeded: false))
  }

  /// With the seed on screen the verdict is about the moment, not the item, so every surface
  /// re-asks on the transport-failure backoff rather than waiting thirty seconds.
  @Test("a seeded unavailable outcome re-asks on the transport-failure backoff")
  func seededUnavailableReprobesPromptly() {
    let expected: [Duration] = [.seconds(2), .seconds(15), .seconds(60)]

    for role in [CoverImageView.Role.libraryThumbnail, .homeCard, .highFidelity] {
      #expect(
        CoverImageView.reprobeSchedule(for: role, outcome: .unavailable, seeded: true)
          == expected)
    }
  }

  @Test("an image outcome never schedules a re-probe")
  func imageOutcomeDoesNotReprobe() {
    #expect(
      CoverImageView.reprobeSchedule(for: .homeCard, outcome: .image(UIImage())).isEmpty)
  }

  @Test("generated to RSS retains only for the same item and revision")
  func generatedToRSSRetainsOnlyForSameItemAndRevision() {
    let revision = ArtworkRevision("revision-1")
    let generatedKey = Self.key(
      source: .generated(ArtworkAccountScope("artwork:generated:rss")), revision: revision)
    let sameItemAndRevision = Self.rssKey(itemID: "item-1", revision: revision)
    let differentItem = Self.rssKey(itemID: "item-2", revision: revision)
    let differentRevision = Self.rssKey(itemID: "item-1", revision: ArtworkRevision("revision-2"))

    #expect(CoverImageView.canRetainImage(from: generatedKey, for: sameItemAndRevision))
    #expect(CoverImageView.canUseSeed(from: generatedKey, for: sameItemAndRevision))
    #expect(CoverImageView.canRetainImage(from: generatedKey, for: differentItem) == false)
    #expect(CoverImageView.canUseSeed(from: generatedKey, for: differentItem) == false)
    #expect(CoverImageView.canRetainImage(from: generatedKey, for: differentRevision) == false)
    #expect(CoverImageView.canUseSeed(from: generatedKey, for: differentRevision) == false)
  }

  @Test("a genuine Audiobookshelf account-scope change rejects retained pixels and seeds")
  func differentAudiobookshelfScopesRejectReuse() {
    let firstKey = Self.key(
      source: .audiobookshelf(ArtworkAccountScope("account-1")))
    let secondKey = Self.key(
      source: .audiobookshelf(ArtworkAccountScope("account-2")))

    #expect(CoverImageView.canRetainImage(from: firstKey, for: secondKey) == false)
    #expect(CoverImageView.canUseSeed(from: firstKey, for: secondKey) == false)
  }

  @Test(".fitTransparent letterboxes a portrait cover: transparent side margins, cover at centre")
  func fitTransparentLetterboxesPortraitArt() {
    let sample = renderedSampler(
      CoverImageView.CoverArtImage(
        uiImage: Self.portraitImage(), presentation: .fitTransparent),
      side: 140)
    // Portrait 2:3 fitted into a square pillarboxes left and right. The residual margins are
    // transparent (alpha 0), never a painted bar colour.
    #expect(isTransparent(sample(5, 70)))
    #expect(isTransparent(sample(134, 70)))
    // The cover itself is opaque teal at the centre. The fit does not shrink it away.
    #expect(isTeal(sample(70, 70)))
  }

  /// A cover fitted into a frame taller than its own aspect is centred by default, leaving a
  /// transparent band at both ends. A grid that marks the artwork's top corners asks for `.top`
  /// instead, so the art and the frame share that edge and the mark has something under it.
  @Test(".fitTransparent honours its alignment: .top moves the whole residual margin below the art")
  func fitTransparentAlignsToTheTop() {
    let centred = renderedSampler(
      CoverImageView.CoverArtImage(
        uiImage: Self.portraitImage(), presentation: .fitTransparent),
      width: 140, height: 240)
    // Centred, the 30 points the 2:3 art cannot fill split into a band at each end.
    #expect(isTransparent(centred(70, 4)))
    #expect(isTransparent(centred(70, 235)))

    let topAligned = renderedSampler(
      CoverImageView.CoverArtImage(
        uiImage: Self.portraitImage(), presentation: .fitTransparent, fitAlignment: .top),
      width: 140, height: 240)
    // Rows run top-down here, so row 4 is the frame's top edge: art, with the whole band below it.
    #expect(isTeal(topAligned(70, 4)))
    #expect(isTransparent(topAligned(70, 235)))
  }

  @Test("Alignment defaults to centre, so every existing call site is unchanged")
  func fitAlignmentDefaultsToCentre() throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let view = CoverImageView(
      itemID: "item", title: "Title", displaySize: 140,
      client: CoverImageClient(server: server), source: nil, revision: .unversioned)
    #expect(view.fitAlignment == .center)
  }

  @Test(".fill crops a portrait cover to the square with no margins")
  func fillCropsPortraitArt() {
    let sample = renderedSampler(
      CoverImageView.CoverArtImage(uiImage: Self.portraitImage(), presentation: .fill),
      side: 140)
    // Where `.fitTransparent` left transparent margins, `.fill` shows opaque cover to the edge.
    #expect(!isTransparent(sample(5, 70)))
    #expect(!isTransparent(sample(134, 70)))
    #expect(isTeal(sample(5, 70)))
    #expect(isTeal(sample(70, 70)))
  }

  /// A wide episode image proposed a 70-point square reports a wider layout size unless the fill
  /// pins it, and a caller's `.frame` centres rather than clips. The canvas is larger than the slot
  /// so overflow is visible; a canvas the size of the slot hides it.
  @Test(".fill stays inside a framed slot when the image is not square")
  func fillStaysInsideFramedSlotForWideArt() {
    let wide = UIImage(data: ImageTestFixtures.solidPNGData(width: 300, height: 100))!
    let sample = renderedSampler(
      coverView(cache: FakeArtworkCache(image: wide) { _ in true }, presentation: .fill)
        .frame(width: 70, height: 70),
      side: 140)
    #expect(isTeal(sample(70, 70)))
    #expect(isTeal(sample(40, 70)), "the slot's leading edge is filled")
    #expect(isTransparent(sample(20, 70)), "nothing is drawn left of the slot")
    #expect(isTransparent(sample(120, 70)), "nothing is drawn right of the slot")
  }

  @Test("A cover overlay on wide .fill art lands on the slot's corner")
  func coverArtworkOverlayFollowsTheSlotForWideFill() {
    let wide = UIImage(data: ImageTestFixtures.solidPNGData(width: 300, height: 100))!
    let sample = renderedSampler(
      coverView(cache: FakeArtworkCache(image: wide) { _ in true }, presentation: .fill)
        .frame(width: 70, height: 70)
        .coverArtworkOverlay(alignment: .bottomTrailing) {
          Color.red.frame(width: 10, height: 10)
        },
      side: 140)
    // The slot spans 35...105, so its trailing-bottom mark covers x 95...105, y 95...105.
    #expect(isRed(sample(100, 100)), "the mark sits on the slot's corner")
    #expect(!isRed(sample(120, 100)), "the mark does not follow the oversized image")
  }

  @Test("The seed branch presents identically to the real branch - it never renders full-bleed")
  func seedBranchMatchesRealBranch() {
    // Real branch: the cache hits the primary key.
    let realSample = renderedSampler(
      coverView(cache: FakeArtworkCache(image: Self.portraitImage()) { _ in true }),
      side: 140)
    // Seed branch: the primary (home-card) key misses, a smaller library-thumbnail seed hits.
    let seedSample = renderedSampler(
      coverView(
        cache: FakeArtworkCache(image: Self.portraitImage()) { key in
          if case .homeCard = key.variant { return false }
          return true
        }),
      side: 140)
    // Both letterbox: the seed does not render the cover full-bleed while the real image fits.
    #expect(isTransparent(realSample(5, 70)))
    #expect(isTransparent(seedSample(5, 70)))
    #expect(isTeal(realSample(70, 70)))
    #expect(isTeal(seedSample(70, 70)))
  }

  /// A fitted portrait cover is inset from both sides of its square box, so a mark pinned to the
  /// box's bottom-trailing corner hangs in the transparent margin beside the artwork. That was
  /// 23 points off the artwork on the hero's 140-point cover.
  @Test("A cover overlay lands on the fitted artwork's corner, not on the box's")
  func coverArtworkOverlayFollowsTheFittedArtwork() {
    let sample = renderedSampler(
      CoverImageView.CoverArtImage(
        uiImage: Self.portraitImage(), presentation: .fitTransparent
      )
      .coverArtworkOverlay(alignment: .bottomTrailing) {
        Color.red.frame(width: 20, height: 20)
      },
      side: 140)

    // 2:3 art fitted into the square is 93 points wide and centred, so its trailing edge is at
    // x≈117. A 20-point mark in that corner covers x≈97 to 117.
    #expect(isRed(sample(106, 130)), "the mark must sit inside the artwork's trailing edge")
    // The bad position: past the artwork, on the page showing through the margin.
    #expect(
      isTransparent(sample(126, 130)),
      "nothing may be drawn in the margin the box leaves beside the art")
  }

  @Test("With no artwork underneath, the overlay is the view's own corner")
  func coverArtworkOverlayFallsBackToItsOwnBounds() {
    let sample = renderedSampler(
      Color.clear.coverArtworkOverlay(alignment: .bottomTrailing) {
        Color.red.frame(width: 20, height: 20)
      },
      side: 140)

    #expect(isRed(sample(130, 130)), "an unreported cover must behave exactly like .overlay")
    #expect(isTransparent(sample(106, 130)))
  }

  @Test("Presentation cannot alter the placeholder branch")
  func placeholderIsPresentationInvariant() {
    // An empty cache and no seed leave the placeholder branch; presentation must not touch it.
    let fill = renderedBuffer(
      coverView(cache: FakeArtworkCache(image: nil) { _ in false }, presentation: .fill),
      side: 60)
    let fitTransparent = renderedBuffer(
      coverView(cache: FakeArtworkCache(image: nil) { _ in false }, presentation: .fitTransparent),
      side: 60)
    #expect(fill == fitTransparent)
  }

  /// The cover can be fetched by someone else (Home's palette work, a prefetcher, the same item on
  /// another shelf) after this tile's body drew its placeholder but before its task ran. The task
  /// then finds a prepared hit, and that hit must still reach the screen. Recording it only where
  /// the body can observe it left the tile blank for the rest of the process.
  @Test("a prepared hit that lands between the body pass and the task still paints the cover")
  func lateCacheHitRepaints() async throws {
    let red = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }
    let side: CGFloat = 140
    let cache = FillsAfterFirstReadArtworkCache(image: red)
    let view = coverView(cache: cache, presentation: .fill)

    let painted = await withKeyWindow(bounds: CGRect(x: 0, y: 0, width: side, height: side)) {
      scope in
      let host = scope.host(view.frame(width: side, height: side))
      // Serviced polls, not a wall-clock budget: under load the wait stretches with the render.
      let outcome = await awaitCondition(
        "the prepared hit paints the cover", recordingIssue: false,
        observing: { "primary reads \(cache.primaryReads)" },
        until: { cache.primaryReads >= 2 && isRed(centrePixel(of: host.view)) })
      if case .observed = outcome { return true }
      return false
    }

    #expect(cache.primaryReads >= 2, "the task never consulted the prepared cache")
    #expect(painted, "the prepared hit never replaced the placeholder")
  }

  // MARK: - Helpers

  private func centrePixel(of view: UIView) -> (r: Int, g: Int, b: Int, a: Int) {
    let bounds = view.bounds
    let snapshot = UIGraphicsImageRenderer(bounds: bounds).image { _ in
      view.drawHierarchy(in: bounds, afterScreenUpdates: true)
    }
    var px = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
      data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let cg = snapshot.cgImage!
    // Draw the full snapshot offset so its centre lands on the single destination pixel.
    context.draw(
      cg,
      in: CGRect(
        x: -CGFloat(cg.width) / 2, y: -CGFloat(cg.height) / 2,
        width: CGFloat(cg.width), height: CGFloat(cg.height)))
    return (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))
  }

  private static func key(
    source: ArtworkSource,
    itemID: String = "item-1",
    revision: ArtworkRevision = .unversioned
  ) -> ArtworkKey {
    ArtworkKey(
      source: source, itemID: itemID, variant: .libraryThumbnail(pixelWidth: 44), revision: revision)
  }

  private static func rssKey(
    itemID: String = "item-1", revision: ArtworkRevision = .unversioned
  ) -> ArtworkKey {
    let source = RSSArtworkSource(
      feedIdentity: "rss:1", artworkURL: URL(string: "https://images.example.test/show.jpg")!)!
    return key(source: .rss(source), itemID: itemID, revision: revision)
  }

  private func coverView(
    cache: any PreparedArtworkCaching,
    presentation: CoverImageView.Presentation = .fitTransparent
  ) -> CoverImageView {
    let server = try! ABSServerConfig(url: URL(string: "https://books.example.test")!)
    return CoverImageView(
      itemID: "item", title: "Title", displaySize: 140,
      client: CoverImageClient(server: server), source: nil, role: .homeCard,
      presentation: presentation, revision: .unversioned, cache: cache)
  }

  /// A pillarbox margin left by a fitted portrait cover is fully transparent, so the surface
  /// behind shows through. Premultiplied-alpha buffers zero the colour channels there too, so
  /// alpha alone is the discriminator.
  private func isTransparent(_ px: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
    px.a < 10
  }

  private func isTeal(_ px: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
    px.r < 70 && px.g > 80 && px.b > 80 && px.a > 200
  }

  /// The overlay marker: a flat colour the teal fixture cannot be mistaken for.
  private func isRed(_ px: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
    px.r > 180 && px.g < 80 && px.b < 80 && px.a > 200
  }

  /// Rasterises `view` in a `side` by `side` frame at scale 1 and returns a point sampler. The
  /// origin is bottom-left (Core Graphics), but every assertion samples a full-height margin column
  /// or the exact centre, both invariant under the vertical flip.
  private func renderedSampler(
    _ view: some View, side: Int
  ) -> (Int, Int) -> (r: Int, g: Int, b: Int, a: Int) {
    renderedSampler(view, width: side, height: side)
  }

  private func renderedSampler(
    _ view: some View, width: Int, height: Int
  ) -> (Int, Int) -> (r: Int, g: Int, b: Int, a: Int) {
    let data = renderedBuffer(view, width: width, height: height)
    return { x, y in
      let i = (y * width + x) * 4
      return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
    }
  }

  private func renderedBuffer(_ view: some View, side: Int) -> [UInt8] {
    renderedBuffer(view, width: side, height: side)
  }

  private func renderedBuffer(_ view: some View, width: Int, height: Int) -> [UInt8] {
    let renderer = ImageRenderer(
      content: view.frame(width: CGFloat(width), height: CGFloat(height)))
    renderer.scale = 1
    let cg = renderer.uiImage!.cgImage!
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
      data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    return data
  }
}

/// A synchronous prepared-artwork cache that returns `image` for keys satisfying `matches`. Lets a
/// render exercise the real-image branch (match the primary key) or the seed branch (miss it, hit a
/// smaller variant) without running the async pipeline.
private final class FakeArtworkCache: PreparedArtworkCaching, @unchecked Sendable {
  private let image: UIImage?
  private let matches: @Sendable (ArtworkKey) -> Bool

  init(image: UIImage?, matches: @escaping @Sendable (ArtworkKey) -> Bool) {
    self.image = image
    self.matches = matches
  }

  func image(for key: ArtworkKey) -> UIImage? { matches(key) ? image : nil }
  func insert(_ image: UIImage, for key: ArtworkKey) {}
  func removeAll() {}
}

/// Misses the primary key on its first read (the body's first pass) and hits on every read after
/// it, standing in for another consumer filling the shared cache in between. Seed variants always
/// miss, so the only pixels that can reach the screen are the primary key's.
private final class FillsAfterFirstReadArtworkCache: PreparedArtworkCaching, @unchecked Sendable {
  private let image: UIImage
  private let lock = NSLock()
  private var reads = 0
  private var primaryKey: ArtworkKey?

  init(image: UIImage) {
    self.image = image
  }

  var primaryReads: Int { lock.withLock { reads } }

  func image(for key: ArtworkKey) -> UIImage? {
    lock.withLock {
      // The body reads the primary key before any seed key, so the first key seen is the primary.
      if primaryKey == nil { primaryKey = key }
      guard key == primaryKey else { return nil }
      reads += 1
      return reads == 1 ? nil : image
    }
  }

  func insert(_ image: UIImage, for key: ArtworkKey) {}
  func removeAll() {}
}
