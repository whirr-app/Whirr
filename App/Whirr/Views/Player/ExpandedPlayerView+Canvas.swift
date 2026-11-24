extension ExpandedPlayerView {
  /// The ambient canvas latch's key for one drawn cover. The latch memoizes per key, so the key
  /// names the image the page draws rather than the item: episodes of one followed show share an
  /// item id but can draw different images, and each must select on its own. The revision and the
  /// provisional flag are deliberately excluded: both change as one image's identity settles, and
  /// either would re-key (and re-read) a cover that has not changed.
  nonisolated static func canvasLatchKey(
    itemID: String, identity: CoverPaletteIdentity
  ) -> String {
    "\(itemID)|\(identity.rowID)"
  }

  /// The palette the canvas may use for `identity`: its own, when resolved. A provisional identity
  /// (the item has not loaded) may show whatever the item's surfaces last asked for, so the page
  /// opens on the mini-player's colour. A resolved identity never borrows another identity of the
  /// same item: the first body after an auto-advance still sees the previous episode's image
  /// shown for the item, and adopting that colour is the bug this key exists to prevent.
  @MainActor
  static func canvasPalette(
    for identity: CoverPaletteIdentity, in service: CoverPaletteService
  ) -> CoverPalette? {
    if let palette = service.palette(for: identity) { return palette }
    guard identity.isProvisional else { return nil }
    return service.palette(forItem: identity.itemID)
  }
}
