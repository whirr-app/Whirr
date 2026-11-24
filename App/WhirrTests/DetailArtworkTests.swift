import ABSApi
import Foundation
import Testing
import UIKit

@testable import Whirr

/// `DetailArtwork.shapes` is process-wide, so each test records under item IDs of its own.
@Suite("Detail artwork key", .timeLimit(.minutes(1)))
@MainActor
struct DetailArtworkTests {
  private static let scope = ArtworkAccountScope("https://covers.example.test")

  @Test("an unmeasured cover keeps the shared high-fidelity key")
  func unmeasuredCoverUsesTheFallback() {
    #expect(
      DetailArtwork.variant(itemID: "detail-unmeasured", revision: .unversioned, displayScale: 3)
        == .highFidelity(displaySize: Double(ItemDetailView.coverDisplaySize), displayScale: 3))
  }

  @Test("the hero, the palette task and the tap preflight resolve one key for a measured cover")
  func everySurfaceAgreesOnAMeasuredCover() {
    let itemID = "detail-agreement"
    let revision = ArtworkRevision("1790000000000")
    let sizing = DetailArtwork.sizing(displayScale: 3)
    let width = sizing.fitPixelWidth(aspectRatio: 2.0 / 3.0)
    DetailArtwork.shapes.record(
      CoverShape(aspectRatio: 2.0 / 3.0, fitPixelWidth: width), itemID: itemID, revision: revision)
    let expected = ArtworkKey(
      accountScope: Self.scope, itemID: itemID, variant: .detailFit(pixelWidth: 660),
      revision: revision)

    let hero = CoverImageView.artworkKey(
      itemID: itemID, client: FixedSourceArtworkClient(scope: Self.scope),
      displaySize: ItemDetailView.coverDisplaySize, displayScale: 3, role: .detail,
      revision: revision)
    #expect(hero == expected)
    // What the bulk pass stores for this shape is the same variant, from the same sizing.
    #expect(
      sizing.variant(for: DetailArtwork.shapes.shape(itemID: itemID, revision: revision))
        == expected.variant)
    // A replaced cover has not been measured yet, so it is back on the fallback.
    #expect(
      DetailArtwork.variant(itemID: itemID, revision: ArtworkRevision("2"), displayScale: 3)
        == sizing.fallbackVariant)
    // A screen at another scale does not read the 3x file.
    #expect(
      DetailArtwork.variant(itemID: itemID, revision: revision, displayScale: 2)
        == DetailArtwork.sizing(displayScale: 2).fallbackVariant)
  }

  @Test("the sizing mirrors the hero and preview frames")
  func sizingMirrorsTheViews() {
    #expect(DetailArtwork.heroSide == Double(ItemDetailHeroView.promotedCoverSize))
    #expect(DetailArtwork.sizing(displayScale: 3).fallbackDisplaySize == 272)
  }

  @Test("pixel size is read from the image header")
  func pixelSizeReadsTheHeader() {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let data = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60), format: format)
      .pngData { _ in }

    #expect(DetailArtwork.pixelSize(data)?.width == 40)
    #expect(DetailArtwork.pixelSize(data)?.height == 60)
    #expect(DetailArtwork.pixelSize(Data([1, 2, 3])) == nil)
  }

  @Test("the foreground sweep is due once a day")
  func sweepIsDueOnceADay() throws {
    let suite = "detail-artwork-tests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    #expect(CoverSweepSchedule.isDue(defaults: defaults, now: start))
    CoverSweepSchedule.markRun(defaults: defaults, now: start)
    #expect(CoverSweepSchedule.isDue(defaults: defaults, now: start.addingTimeInterval(3600)) == false)
    #expect(CoverSweepSchedule.isDue(defaults: defaults, now: start.addingTimeInterval(86_400)))
    // A clock moved back past the stamp does not strand the sweep.
    #expect(CoverSweepSchedule.isDue(defaults: defaults, now: start.addingTimeInterval(-60)))
  }
}

private actor FixedSourceArtworkClient: ArtworkServing {
  nonisolated let defaultSource: ArtworkSource?

  init(scope: ArtworkAccountScope) {
    defaultSource = .audiobookshelf(scope)
  }

  func fetch(_ key: ArtworkKey) async throws -> CoverImageResult {
    throw APIError.notFound
  }

  func data(for key: ArtworkKey) async -> Data? { nil }

  func needsRefresh(_ key: ArtworkKey) async -> Bool { false }
}
