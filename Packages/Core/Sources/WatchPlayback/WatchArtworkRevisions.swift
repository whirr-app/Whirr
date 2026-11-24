import Foundation
import WatchProtocol

/// The cover revisions the phone has reported, per account and cover, so every Watch surface asks
/// for the same revision of a cover. A row the phone cannot date leaves an earlier revision in
/// place; a never-dated cover, or one arriving once the account is full, stays unversioned and
/// falls back to the cache's age-based refresh.
public struct WatchArtworkRevisions: Sendable, Equatable {
  /// Matches the largest manifest, so a synced library's revisions all fit.
  public static let maxCoversPerAccount = WatchArtworkSyncLimits.maxManifestCovers
  private var known: [WatchAccountStamp: [WatchBrowseShowIdentity: String]] = [:]

  public init() {}

  /// Returns whether anything changed, so callers can avoid needless observation churn.
  @discardableResult
  public mutating func learn(from snapshot: WatchCatalogueSnapshot) -> Bool {
    guard let stamp = snapshot.accountStamp else { return false }
    return learn(
      snapshot.items.compactMap { item in
        item.artworkRevision.map { (WatchArtworkReference(selection: item.selection).source, $0) }
      },
      accountStamp: stamp)
  }

  @discardableResult
  public mutating func learn(_ rows: [WatchBrowseRow], accountStamp: WatchAccountStamp) -> Bool {
    learn(
      rows.compactMap { row in
        guard case .show(let show) = row, let revision = show.artworkRevision else { return nil }
        return (show.id, revision)
      },
      accountStamp: accountStamp)
  }

  /// Teaches the manifest's dated covers under `accountStamp`: the phone stamp it was filed under,
  /// or the Watch's own stamp when the phone vouches both are the same account.
  @discardableResult
  public mutating func learn(_ manifest: WatchArtworkManifest, as accountStamp: WatchAccountStamp) -> Bool {
    learn(
      manifest.covers.compactMap { cover in
        cover.reference.revision == WatchArtworkReference.unversioned
          ? nil : (cover.reference.source, cover.reference.revision)
      },
      accountStamp: accountStamp)
  }

  public func reference(for selection: WatchSelection, accountStamp: WatchAccountStamp) -> WatchArtworkReference {
    let unversioned = WatchArtworkReference(selection: selection)
    guard let revision = known[accountStamp]?[unversioned.source] else { return unversioned }
    return WatchArtworkReference(selection: selection, revision: revision)
  }

  /// Drops every account but these, as the artwork cache does when the session changes.
  public mutating func retain(accounts: Set<WatchAccountStamp>) {
    known = known.filter { accounts.contains($0.key) }
  }

  private mutating func learn(
    _ revisions: [(WatchBrowseShowIdentity, String)], accountStamp: WatchAccountStamp
  ) -> Bool {
    var covers = known[accountStamp] ?? [:]
    var changed = false
    for (cover, revision) in revisions where covers[cover] != revision {
      // A full account keeps what it knows; a new cover past the cap stays unversioned.
      if covers[cover] == nil, covers.count >= Self.maxCoversPerAccount { continue }
      covers[cover] = revision
      changed = true
    }
    if changed { known[accountStamp] = covers }
    return changed
  }
}
