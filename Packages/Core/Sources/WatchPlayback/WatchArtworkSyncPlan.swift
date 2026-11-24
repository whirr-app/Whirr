import Foundation
import WatchProtocol

/// The Watch's side of whole-library cover sync, as pure rules over persisted state: which phone
/// stamp it accepts, which stamps a synced cover may be drawn under, what to prune, and what to
/// ask for next. The Watch decides what is missing, so a cleared cache, new Watch and interrupted
/// transfer all recover by asking again.
public struct WatchArtworkSyncPlan: Codable, Equatable, Sendable {
  /// A want list or manifest request with no answer after this long is sent again.
  public static let unansweredAfter: TimeInterval = 24 * 60 * 60

  public struct Outstanding: Codable, Equatable, Sendable {
    public let id: UUID
    public let sentAt: Date
  }
  public struct ManifestRequest: Codable, Equatable, Sendable {
    public let accountStamp: WatchAccountStamp
    public let sentAt: Date
  }
  public enum ManifestOutcome: Equatable, Sendable {
    case rejected
    /// Synced covers the manifest no longer lists, to delete.
    case accepted(prune: Set<WatchArtworkCover>)
  }

  public private(set) var manifest: WatchArtworkManifest?
  public private(set) var outstanding: Outstanding?
  public private(set) var unavailable: Set<WatchArtworkCover> = []
  public private(set) var manifestRequest: ManifestRequest?

  public init() {}

  /// The stamps a synced cover may be drawn under: always the phone stamp it was filed under, and
  /// the Watch's own sign-in only when the phone vouches it is the same account.
  public func drawingStamps(localStamp: WatchAccountStamp?) -> Set<WatchAccountStamp> {
    guard let manifest else { return [] }
    var stamps: Set<WatchAccountStamp> = [manifest.accountStamp]
    if let localStamp, manifest.authenticatedAccountStamp == localStamp { stamps.insert(localStamp) }
    return stamps
  }

  /// Accepts only the current phone catalogue stamp. Any accepted manifest ends the wait for an
  /// outstanding want list: the phone sends one each time its app binds the account, and a want
  /// list that reached it before then was dropped. Only new covers reset what it could not serve.
  public mutating func receive(
    _ next: WatchArtworkManifest, currentPhoneStamp: WatchAccountStamp?, synced: Set<WatchArtworkCover>
  ) -> ManifestOutcome {
    guard let currentPhoneStamp, next.accountStamp == currentPhoneStamp else { return .rejected }
    outstanding = nil
    if manifest?.hasSameCovers(as: next) != true { unavailable = [] }
    manifest = next
    manifestRequest = nil
    return .accepted(prune: synced.subtracting(next.covers))
  }

  /// The entries to store, or nil when the bundle belongs to another account. Covers the manifest
  /// does not list are dropped; the final bundle for the outstanding want list clears it.
  public mutating func receive(
    _ bundle: WatchArtworkBundle, currentPhoneStamp: WatchAccountStamp?
  ) -> [WatchArtworkBundle.Entry]? {
    guard let manifest, let currentPhoneStamp, bundle.accountStamp == currentPhoneStamp,
      manifest.accountStamp == currentPhoneStamp
    else { return nil }
    let listed = Set(manifest.covers)
    unavailable.formUnion(bundle.unavailable.filter(listed.contains))
    if bundle.isFinal, outstanding?.id == bundle.wantListID { outstanding = nil }
    return bundle.entries.filter { listed.contains($0.cover) }
  }

  /// What to send now, if anything: a manifest request when there is no manifest for the current
  /// phone stamp, otherwise the next batch of missing covers. Nothing is sent while a request is
  /// still awaiting its answer, until it has gone unanswered for `unansweredAfter`.
  public mutating func nextRequest(
    currentPhoneStamp: WatchAccountStamp?, synced: Set<WatchArtworkCover>, now: Date = Date()
  ) -> WatchArtworkWantList? {
    guard let currentPhoneStamp else { return nil }
    guard let manifest, manifest.accountStamp == currentPhoneStamp else {
      if manifest != nil {
        manifest = nil
        outstanding = nil
        unavailable = []
      }
      if let manifestRequest, manifestRequest.accountStamp == currentPhoneStamp,
        now.timeIntervalSince(manifestRequest.sentAt) < Self.unansweredAfter
      {
        return nil
      }
      guard let ask = try? WatchArtworkWantList(accountStamp: currentPhoneStamp, manifestID: nil, covers: [])
      else { return nil }
      manifestRequest = ManifestRequest(accountStamp: currentPhoneStamp, sentAt: now)
      return ask
    }
    if let outstanding, now.timeIntervalSince(outstanding.sentAt) < Self.unansweredAfter { return nil }
    let unavailable = unavailable
    var wanted: [WatchArtworkCover] = []
    for cover in manifest.covers where !synced.contains(cover) && !unavailable.contains(cover) {
      wanted.append(cover)
      if wanted.count == WatchArtworkSyncLimits.maxWantedCovers { break }
    }
    guard !wanted.isEmpty,
      let wantList = try? WatchArtworkWantList(
        accountStamp: currentPhoneStamp, manifestID: manifest.id, covers: wanted)
    else {
      outstanding = nil
      return nil
    }
    outstanding = Outstanding(id: wantList.id, sentAt: now)
    return wantList
  }
}
