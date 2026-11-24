import ABSApi
import Foundation
import Persistence

/// The bulk pass's shape measurement and its sweep.
extension CoverCacheAllCoordinator {
  /// Fills the in-memory index from the table, once. Until this has run the index is empty, and a
  /// pass would measure and fetch every detail cover again.
  public func loadShapes() async {
    guard let shapes, shapesLoaded == false else { return }
    guard let records = try? await shapeStore.fetchAll() else { return }
    for record in records {
      shapes.index.record(
        CoverShape(aspectRatio: record.aspectRatio, fitPixelWidth: record.fitPixelWidth),
        itemID: record.itemId, revision: ArtworkRevision(record.revision))
    }
    shapesLoaded = true
  }

  func needsMeasurement(
    _ item: ItemDAO.ServerItemKind, shapes: CoverShapeMeasurement
  ) -> Bool {
    let revision = ArtworkRevision(serverUpdatedAt: item.serverUpdatedAt)
    guard let shape = shapes.index.shape(itemID: item.serverItemId, revision: revision) else {
      return true
    }
    // The rule or the display scale changed since the shape was recorded.
    return shapes.sizing.fitPixelWidth(aspectRatio: shape.aspectRatio) != shape.fitPixelWidth
  }

  /// Measures a cover's shape from its card image, fetches the detail cover at the width that
  /// shape needs, and only then records the shape.
  ///
  /// Order matters: views ask for the fitted width only once the shape is recorded, so the file
  /// must exist by then. Recording first would leave a detail screen opened before the fetch, or
  /// offline, on a key with nothing behind it.
  ///
  /// The server's resized-cover cache ignores the revision, so the card image can still have a
  /// replaced cover's shape. The fitted image is a fresh width, so its own shape is the check: on
  /// a disagreement of more than 2% the width is recomputed from it and fetched once more.
  func measureAndFetchDetail(
    item: ItemDAO.ServerItemKind, shapes: CoverShapeMeasurement, accountID: Int64
  ) async -> VariantOutcome {
    let fallback = key(for: item, artworkVariant: shapes.sizing.fallbackVariant)
    guard
      let cardData = await covers.data(for: key(for: item, variant: .homeCard)),
      var aspectRatio = Self.aspectRatio(of: cardData, shapes: shapes)
    else {
      // No card image to measure: keep the item on today's key until a later pass.
      return await ensure(fallback, item: item, accountID: accountID)
    }

    var width = shapes.sizing.fitPixelWidth(aspectRatio: aspectRatio)
    var detailKey = key(for: item, artworkVariant: Self.detailVariant(width: width, shapes: shapes))
    var outcome = await ensure(detailKey, item: item, accountID: accountID)
    guard outcome == .fetched || outcome == .alreadyPresent else { return outcome }
    guard
      let detailData = await covers.data(for: detailKey),
      let fetchedAspectRatio = Self.aspectRatio(of: detailData, shapes: shapes)
    else { return outcome }

    if abs(fetchedAspectRatio - aspectRatio) / aspectRatio > 0.02 {
      aspectRatio = fetchedAspectRatio
      let corrected = shapes.sizing.fitPixelWidth(aspectRatio: aspectRatio)
      if corrected != width {
        width = corrected
        detailKey = key(for: item, artworkVariant: Self.detailVariant(width: width, shapes: shapes))
        let second = await ensure(detailKey, item: item, accountID: accountID)
        guard second == .fetched || second == .alreadyPresent else { return second }
        if second == .fetched { outcome = .fetched }
      }
    }

    let revision = ArtworkRevision(serverUpdatedAt: item.serverUpdatedAt)
    let record = CoverShapeRecord(
      itemId: item.serverItemId, revision: revision.rawValue, aspectRatio: aspectRatio,
      fitPixelWidth: width, measuredAt: now())
    guard (try? await shapeStore.upsert(record)) != nil else { return outcome }
    shapes.index.record(
      CoverShape(aspectRatio: aspectRatio, fitPixelWidth: width),
      itemID: item.serverItemId, revision: revision)
    return outcome
  }

  private static func aspectRatio(of data: Data, shapes: CoverShapeMeasurement) -> Double? {
    guard let size = shapes.pixelSize(data), size.width > 0, size.height > 0 else { return nil }
    return Double(size.width) / Double(size.height)
  }

  private static func detailVariant(width: Int, shapes: CoverShapeMeasurement) -> ArtworkVariant {
    let fallback = shapes.sizing.fallbackVariant
    return width < fallback.pixelWidth ? .detailFit(pixelWidth: width) : fallback
  }

  // MARK: Sweep

  /// How long a cover outside the bulk pass's own key set is kept unread.
  public static let unlistedCoverLifetime: TimeInterval = 30 * 24 * 60 * 60
  /// The store's backstop ceiling, about twice the expected fill.
  public static let coverStoreByteCeiling: Int64 = 300 * 1024 * 1024

  /// Removes covers nothing will ask for again: old revisions, items no longer in the library,
  /// widths no surface has read for `unlistedCoverLifetime`, and a previous login's covers. Only
  /// deletes, so it is not subject to the automatic top-up preference or the network policy.
  @discardableResult
  public func sweep() async -> CoverCachePruneSummary? {
    guard let account = try? await accountDAO.fetchAsync(), let accountID = account.id,
      let eligible = try? await itemDAO.serverItemKindsEligibleForArtworkAsync(accountId: accountID)
    else { return nil }
    await loadShapes()
    return await prune(accountID: accountID, eligible: eligible)
  }

  /// `live` is every item the account still has, not the eligible set: that set drops items in
  /// de-selected libraries and items kept only for their downloads or progress, whose covers are
  /// still shown. `keep` is exactly what a pass warms.
  @discardableResult
  func prune(
    accountID: Int64, eligible: [ItemDAO.ServerItemKind]
  ) async -> CoverCachePruneSummary? {
    guard let all = try? await itemDAO.allServerItemKindsAsync(accountId: accountID) else {
      return nil
    }
    var live: [String: ArtworkRevision] = [:]
    for item in all {
      live[item.serverItemId] = ArtworkRevision(serverUpdatedAt: item.serverUpdatedAt)
    }
    let keep = eligible.flatMap { item in
      variants(for: item).map { key(for: item, variant: $0) }
    }
    return await covers.pruneCachedArtwork(
      live: live, keep: keep, unlistedOlderThan: Self.unlistedCoverLifetime,
      byteCeiling: Self.coverStoreByteCeiling, now: now())
  }
}
