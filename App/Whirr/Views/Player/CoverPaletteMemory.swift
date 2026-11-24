import Foundation
import Observation

/// `CoverPaletteService`'s resolved palettes: bounded by recency, with one pinned identity that is
/// never evicted, and the identity each item's player or detail surface last asked for.
///
/// Views read it in `body`, so the palettes and the shown identities are observed while recency is
/// not: a read touches recency, and an observed write there would invalidate the view reading it.
@MainActor
@Observable
final class CoverPaletteMemory {
  private var palettes: [CoverPaletteIdentity: CoverPalette] = [:]
  private var shown: [String: CoverPaletteIdentity] = [:]
  @ObservationIgnored private var recencies: [CoverPaletteIdentity: UInt64] = [:]
  @ObservationIgnored private var recency: UInt64 = 0
  @ObservationIgnored private var pinned: CoverPaletteIdentity?
  @ObservationIgnored private var pinnedItemID: String?
  @ObservationIgnored private let limit: Int

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  /// Whether `identity` is resolved, without counting as a use.
  func contains(_ identity: CoverPaletteIdentity) -> Bool {
    palettes[identity] != nil
  }

  /// `identity`'s palette, without counting as a use.
  func peek(_ identity: CoverPaletteIdentity) -> CoverPalette? {
    palettes[identity]
  }

  /// `identity`'s palette, counted as a use so it is evicted last.
  func palette(for identity: CoverPaletteIdentity) -> CoverPalette? {
    guard let palette = palettes[identity] else { return nil }
    recencies[identity] = nextRecency()
    return palette
  }

  /// The palette for the identity `itemID`'s surfaces last asked for.
  func palette(forItem itemID: String) -> CoverPalette? {
    shown[itemID].flatMap { palette(for: $0) }
  }

  /// Stores `palette` as the most recent use, evicting the least recent unpinned palettes past
  /// the limit.
  func insert(_ palette: CoverPalette, for identity: CoverPaletteIdentity) {
    palettes[identity] = palette
    recencies[identity] = nextRecency()
    while palettes.count > limit {
      guard
        let oldest = palettes.keys.filter({ $0 != pinned }).min(by: {
          recencies[$0, default: 0] < recencies[$1, default: 0]
        })
      else { return }
      palettes[oldest] = nil
      recencies[oldest] = nil
    }
  }

  /// Protects `identity` from eviction, replacing any earlier pin.
  func pin(_ identity: CoverPaletteIdentity?) {
    pinned = identity
    if let identity { _ = palette(for: identity) }
  }

  /// Pins whichever identity `itemID`'s surfaces ask for, now and as it changes.
  func pin(itemID: String) {
    pinnedItemID = itemID
    pin(shown[itemID])
  }

  /// Makes `identity` the one `palette(forItem:)` reads for its item, moving the item pin with it.
  func show(_ identity: CoverPaletteIdentity) {
    if shown[identity.itemID] != identity {
      shown[identity.itemID] = identity
    }
    if identity.itemID == pinnedItemID {
      pin(identity)
    }
  }

  /// Drops every palette and the pin. Which identity each item shows, and which item is pinned,
  /// stay: the surfaces asking have not changed, and their next answers land where they read.
  func removeAll() {
    palettes.removeAll()
    recencies.removeAll()
    recency = 0
    pinned = nil
  }

  private func nextRecency() -> UInt64 {
    recency &+= 1
    return recency
  }
}
