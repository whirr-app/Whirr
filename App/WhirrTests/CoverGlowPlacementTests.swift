import ABSApi
import CoreGraphics
import Foundation
import Persistence
import Testing

@testable import Whirr

/// Where a cover hands its glow the artwork's shape. See `CoverImageView.artworkGlow`.
@MainActor
struct CoverGlowPlacementTests {
  @Test("a cover draws no glow unless its caller asks")
  func glowIsOptIn() throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let view = CoverImageView(
      itemID: "item", title: "Title", displaySize: 140,
      client: CoverImageClient(server: server), source: nil, revision: .unversioned)
    #expect(!view.artworkGlow)
  }

  @Test("a fitted cover glows at the image's own shape; a filled one at its frame's")
  func glowAspectRatio() {
    let portrait = CGSize(width: 200, height: 300)
    #expect(
      CoverImageView.glowAspectRatio(presentation: .fitTransparent, imageSize: portrait)
        == 200.0 / 300)
    #expect(CoverImageView.glowAspectRatio(presentation: .fill, imageSize: portrait) == nil)
    #expect(
      CoverImageView.glowAspectRatio(presentation: .fitTransparent, imageSize: .zero) == nil)
  }

  @Test("a podcast show tile glows its cover")
  func showTileGlows() throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let tile = PodcastShowTileView(
      show: ItemSummary(
        serverItemId: "show", mediaKind: "podcast", title: "Show", author: nil,
        durationSeconds: nil, category: .podcast, serverUpdatedAt: nil),
      coverClient: CoverImageClient(server: server), cardSize: 160, onSelect: {})
    #expect(tile.cover.artworkGlow)
  }

  @Test("the podcast show header glows its cover")
  func showHeaderGlows() {
    #expect(PodcastShowViewPresentation.headerCoverGlows)
  }
}
