import ABSApi
import DesignSystem
import Foundation
import Testing

@testable import Whirr

/// `CoverPaletteMemory`'s bound, pin and per-item record, without the service around it.
@MainActor
struct CoverPaletteMemoryTests {
  private static let palette = CoverAmbientPalette.palette(
    from: CoverPaletteSamples(
      average: CoverRGBA(red: 0.2, green: 0.3, blue: 0.4),
      dominant: [CoverRGBA(red: 0.9, green: 0.2, blue: 0.2)]))

  private static func identity(_ itemID: String, _ revision: String = "r1") -> CoverPaletteIdentity {
    CoverPaletteIdentity(
      accountScope: ArtworkAccountScope("scope"), itemID: itemID,
      revision: ArtworkRevision(revision))
  }

  @Test("The least recently used palette is evicted first, and a read counts as a use")
  func evictsLeastRecentlyUsed() {
    let memory = CoverPaletteMemory(limit: 2)
    memory.insert(Self.palette, for: Self.identity("a"))
    memory.insert(Self.palette, for: Self.identity("b"))
    _ = memory.palette(for: Self.identity("a"))
    memory.insert(Self.palette, for: Self.identity("c"))

    #expect(memory.contains(Self.identity("a")))
    #expect(memory.contains(Self.identity("b")) == false)
    #expect(memory.contains(Self.identity("c")))
  }

  @Test("A peek does not count as a use")
  func peekDoesNotTouchRecency() {
    let memory = CoverPaletteMemory(limit: 2)
    memory.insert(Self.palette, for: Self.identity("a"))
    memory.insert(Self.palette, for: Self.identity("b"))
    _ = memory.peek(Self.identity("a"))
    memory.insert(Self.palette, for: Self.identity("c"))

    #expect(memory.contains(Self.identity("a")) == false)
  }

  @Test("The item pin follows the identity its surfaces show, and survives any amount of use")
  func itemPinFollowsShownIdentity() {
    let memory = CoverPaletteMemory(limit: 1)
    memory.pin(itemID: "player")
    memory.show(Self.identity("player", "r2"))
    memory.insert(Self.palette, for: Self.identity("player", "r2"))
    memory.insert(Self.palette, for: Self.identity("other"))

    #expect(memory.palette(forItem: "player") == Self.palette)
  }

  @Test("The pin follows the player across an episode switch within one show")
  func pinFollowsTheEpisodeSwitch() throws {
    func episode(_ name: String) throws -> RSSArtworkSource {
      try #require(
        RSSArtworkSource(
          feedIdentity: "rss:7", artworkURL: URL(string: "https://img.test/\(name).jpg")!))
    }
    let show = try #require(
      RSSArtworkSource(feedIdentity: "rss:7", artworkURL: URL(string: "https://img.test/show.jpg")!))
    func identity(_ source: RSSArtworkSource) -> CoverPaletteIdentity {
      CoverPaletteIdentity(
        drawing: ArtworkKey(
          source: .rss(source), itemID: "rss:7", variant: .highFidelity(displaySize: 380, displayScale: 3),
          revision: .unversioned),
        showSource: .rss(show))
    }
    let first = identity(try episode("one"))
    let second = identity(try episode("two"))
    #expect(first.itemID == second.itemID)
    #expect(first.rowID != second.rowID)

    let memory = CoverPaletteMemory(limit: 1)
    memory.pin(itemID: "rss:7")
    memory.show(first)
    memory.insert(Self.palette, for: first)
    memory.show(second)
    memory.insert(Self.palette, for: second)
    memory.insert(Self.palette, for: Self.identity("other"))

    #expect(memory.contains(second))
    #expect(memory.palette(forItem: "rss:7") == Self.palette)
  }

  @Test("Clearing drops palettes but keeps what each item shows")
  func removeAllKeepsShownIdentities() {
    let memory = CoverPaletteMemory(limit: 4)
    memory.show(Self.identity("item"))
    memory.insert(Self.palette, for: Self.identity("item"))
    memory.removeAll()

    #expect(memory.palette(forItem: "item") == nil)
    memory.insert(Self.palette, for: Self.identity("item"))
    #expect(memory.palette(forItem: "item") == Self.palette)
  }
}
