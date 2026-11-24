import ABSApi
import Foundation
import Testing
import UIKit

@testable import Whirr

/// An episode's own cover that cannot be had falls back to its show's, rather than to a generated
/// cover or a blank.
@MainActor
struct CoverImageFallbackPolicyTests {
  private static func rss(_ name: String) -> ArtworkSource {
    .rss(
      RSSArtworkSource(
        feedIdentity: "rss:1", artworkURL: URL(string: "https://images.example.test/\(name).jpg")!,
        feedURL: URL(string: "https://feeds.example.test/show.xml")!)!)
  }

  private static func key(_ source: ArtworkSource) -> ArtworkKey {
    ArtworkKey(
      source: source, itemID: "rss:1", variant: .homeCard(displaySize: 140, displayScale: 3),
      revision: .unversioned)
  }

  @Test("the fallback key keeps the primary's geometry and revision under the show's source")
  func fallbackKeyKeepsGeometryUnderTheFallbackSource() throws {
    let primary = Self.key(Self.rss("episode"))

    let fallback = try #require(
      CoverImageView.fallbackKey(for: primary, fallbackSource: Self.rss("show")))

    #expect(fallback.source == Self.rss("show"))
    #expect(fallback.itemID == primary.itemID)
    #expect(fallback.variant == primary.variant)
    #expect(fallback.revision == primary.revision)
  }

  @Test("no fallback source, the primary's own source, or a generated primary has no fallback key")
  func fallbackKeyIsAbsentWhenThereIsNothingToFallBackTo() {
    let primary = Self.key(Self.rss("episode"))
    let generated = Self.key(.generated(ArtworkAccountScope("artwork:generated:rss")))

    #expect(CoverImageView.fallbackKey(for: primary, fallbackSource: nil) == nil)
    #expect(CoverImageView.fallbackKey(for: primary, fallbackSource: Self.rss("episode")) == nil)
    #expect(CoverImageView.fallbackKey(for: generated, fallbackSource: Self.rss("show")) == nil)
  }

  @Test("unavailable and failed outcomes draw the fallback; an image does not")
  func fallbackDrawsForUnavailableAndFailedOnly() {
    let fallbackKey = Self.key(Self.rss("show"))
    let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }

    #expect(CoverImageView.shouldDrawFallback(after: .unavailable, fallbackKey: fallbackKey, seeded: false))
    #expect(CoverImageView.shouldDrawFallback(after: .failed, fallbackKey: fallbackKey, seeded: false))
    #expect(
      CoverImageView.shouldDrawFallback(after: .image(image), fallbackKey: fallbackKey, seeded: false)
        == false)
  }

  @Test("without a fallback key, or with a seed of the primary on screen, nothing falls back")
  func noFallbackWithoutAKeyOrOverASeed() {
    let fallbackKey = Self.key(Self.rss("show"))

    #expect(CoverImageView.shouldDrawFallback(after: .unavailable, fallbackKey: nil, seeded: false) == false)
    #expect(CoverImageView.shouldDrawFallback(after: .failed, fallbackKey: nil, seeded: false) == false)
    #expect(
      CoverImageView.shouldDrawFallback(after: .unavailable, fallbackKey: fallbackKey, seeded: true) == false)
  }

  @Test("the primary's reprobe schedule is the same with or without a fallback")
  func reprobeScheduleIsUnchanged() {
    #expect(
      CoverImageView.reprobeSchedule(for: .homeCard, outcome: .failed)
        == [.seconds(2), .seconds(15), .seconds(60)])
    #expect(
      CoverImageView.reprobeSchedule(for: .homeCard, outcome: .unavailable)
        == [.seconds(30), .seconds(150)])
  }

  @Test("a cover has no fallback unless one is given, so existing call sites are unchanged")
  func fallbackDefaultsToNil() throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let view = CoverImageView(
      itemID: "item", title: "Title", displaySize: 140,
      client: CoverImageClient(server: server), source: nil, revision: .unversioned)

    #expect(view.fallbackSource == nil)
  }
}
