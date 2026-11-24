import ABSApi
import Foundation
import Persistence
import SwiftUI
import Testing
import UIKit

@testable import Whirr

/// A show tile's height must not depend on its text: a grid row of tiles with a one-line title or
/// no publisher beside a two-line title and a publisher would otherwise be ragged.
@MainActor
@Suite("Podcast show tile height")
struct PodcastShowTileHeightTests {
  private static let width: CGFloat = 164
  private static let sizes: [DynamicTypeSize] = [.large, .xxxLarge, .accessibility2]

  @Test("title length and a missing publisher leave the tile's height unchanged")
  func textNeverChangesHeight() throws {
    for size in Self.sizes {
      let baseline = try height(title: "Show", author: "Publisher", size: size)
      #expect(baseline > 0)
      let longTitle = String(repeating: "A long podcast title ", count: 6)
      #expect(try height(title: longTitle, author: "Publisher", size: size) == baseline, "\(size)")
      #expect(try height(title: "Show", author: nil, size: size) == baseline, "\(size)")
      #expect(try height(title: longTitle, author: nil, size: size) == baseline, "\(size)")
    }
  }

  @Test("a reserved recovery line is as tall as a shown one")
  func reservedRecoveryLineMatchesShown() throws {
    for size in Self.sizes {
      let shown = try height(title: "Show", author: "Publisher", attentionRow: .shown, size: size)
      let reserved = try height(
        title: "Show", author: "Publisher", attentionRow: .reserved, size: size)
      #expect(shown == reserved, "\(size)")
      #expect(shown > (try height(title: "Show", author: "Publisher", size: size)), "\(size)")
    }
  }

  private func height(
    title: String, author: String?,
    attentionRow: PodcastsViewPresentation.ShowTileAttentionRow = .omitted,
    size: DynamicTypeSize
  ) throws -> CGFloat {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let tile = PodcastShowTileView(
      show: ItemSummary(
        serverItemId: "show", mediaKind: "podcast", title: title, author: author,
        durationSeconds: nil, category: .podcast, serverUpdatedAt: nil),
      coverClient: CoverImageClient(server: server), cardSize: 160, attentionRow: attentionRow,
      onSelect: {})
    let host = UIHostingController(
      rootView: tile.frame(width: Self.width).environment(\.dynamicTypeSize, size))
    return host.sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude))
      .height
  }
}
