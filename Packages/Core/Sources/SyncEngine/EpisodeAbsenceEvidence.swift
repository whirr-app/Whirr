import ABSApi

extension PodcastMedia {
  /// Whether this episode list can prove an episode missing from it is absent from the server.
  /// Every SyncEngine decision inferring absence from a show's list (refresh's generation-based
  /// soft delete, save preflight, save reconciliation, removal) asks this one question.
  ///
  /// Item-detail decoding is lossy: an episode sent without an id is dropped from `episodes` and
  /// recorded only in the diagnostics passed to that read. So `detailDiagnostics` must be the
  /// instance the same item-detail read decoded into (not another response's, such as the
  /// account-wide progress list), and any recorded entry means a dropped episode cannot be told
  /// from an absent one. Duplicate or unusable ids have the same effect.
  func episodeListProvesAbsence(detailDiagnostics: DecodeDiagnostics) -> Bool {
    guard isEpisodeListStructurallyComplete, detailDiagnostics.entries.isEmpty else {
      return false
    }
    let episodeIDs = episodes.map(\.id)
    return episodeIDs.allSatisfy(NativeEpisodeServerSaveSupport.usableServerIdentity)
      && Set(episodeIDs).count == episodeIDs.count
  }
}

extension NativeEpisodeServerSaveCoordinator {
  /// An item-detail read together with the diagnostics it decoded into. A read shared across
  /// several saves or reconciliations carries that evidence with it, so each consumer applies
  /// `episodeListProvesAbsence` to the read it was given.
  struct ItemDetailRead: Sendable {
    let detail: ItemDetail
    let diagnostics: DecodeDiagnostics
  }

  /// The coordinator's only item-detail read, so no save, reconciliation or removal path can
  /// read a show without the diagnostics its absence decision needs.
  func readItemDetail(account: TokenAccount, itemID: String) async throws -> ItemDetailRead {
    let diagnostics = DecodeDiagnostics()
    let detail = try await itemDetailReader.fetchItemDetail(
      account: account, itemID: itemID, diagnostics: diagnostics)
    return ItemDetailRead(detail: detail, diagnostics: diagnostics)
  }
}
