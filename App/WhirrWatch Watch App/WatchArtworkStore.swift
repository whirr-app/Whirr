import ABSApi
import Foundation
import ImageIO
import Observation
import UIKit
import WatchPlayback
import WatchProtocol

/// One account-fenced, two-request artwork queue shared by visible rows and the player.
@MainActor @Observable
final class WatchArtworkStore {
  typealias Key = WatchArtworkCache.Key
  private(set) var localStamp: WatchAccountStamp?
  private(set) var phoneStamp: WatchAccountStamp?
  private(set) var generation = 0
  private var revisions: [Key: Int] = [:]
  /// Observed: a newly learned cover revision changes the keys views ask for, so they re-load.
  private var coverRevisions = WatchArtworkRevisions()
  /// Bumps when a cover revision is learned, so download pinning follows the keys rows use.
  private(set) var coverRevisionEpoch = 0
  @ObservationIgnored private var sessionEpoch: Int?
  @ObservationIgnored private var companion: WatchCompanionStore?
  @ObservationIgnored private var coverClient: CoverImageClient?
  @ObservationIgnored private var flights: [Key: (id: UUID, task: Task<Data?, Never>)] = [:]
  @ObservationIgnored private var interest: [Key: Set<UUID>] = [:]
  @ObservationIgnored private var permitted: Set<Key> = []
  @ObservationIgnored private var failures: [Key: Failure] = [:]
  @ObservationIgnored private var images = NSCache<NSString, UIImage>()
  @ObservationIgnored private let gate = ServerRequestGate(maximumConcurrent: 2)
  /// Age-based refreshes of covers already shown wait here, one at a time, never ahead of a
  /// missing cover.
  @ObservationIgnored private let refreshGate = ServerRequestGate(maximumConcurrent: 1)
  private static let baseRetryDelay: TimeInterval = 1
  private static let maximumRetryDelay: TimeInterval = 5 * 60
  @ObservationIgnored private let cache: WatchArtworkCache
  /// The phone's last accepted cover manifest, owned by the sync receiver.
  @ObservationIgnored var syncedManifest: @MainActor () -> WatchArtworkManifest? = { nil }

  /// The one disk cache, shared with the sync receiver so pushed covers land where rows read.
  static func makeCache() -> WatchArtworkCache {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return WatchArtworkCache(
      directory: caches.appendingPathComponent("WatchThumbnails-v2", isDirectory: true),
      legacyDirectories: [caches.appendingPathComponent("WatchThumbnails-v1", isDirectory: true)])
  }

  init(cache: WatchArtworkCache) {
    self.cache = cache
    images.countLimit = 64
    images.totalCostLimit = 2 * 1024 * 1024
  }

  func configure(context: WatchSessionContext?, companion: WatchCompanionStore) async {
    let nextLocal = context?.authenticatedStamp
    let nextPhone = companion.snapshot?.accountStamp
    guard localStamp != nextLocal || phoneStamp != nextPhone || sessionEpoch != context?.epoch || self.companion == nil
    else { return }
    generation &+= 1
    let epoch = generation
    for flight in flights.values { flight.task.cancel() }
    flights.removeAll()
    interest.removeAll()
    permitted.removeAll()
    failures.removeAll()
    revisions.removeAll()
    sessionEpoch = context?.epoch
    images.removeAllObjects()
    localStamp = nextLocal
    phoneStamp = nextPhone
    // The synced manifest's stamp is kept too, so a launch that has not yet restored the phone's
    // snapshot does not delete every pushed cover.
    let accounts = Set([nextLocal, nextPhone, syncedManifest()?.accountStamp].compactMap { $0 })
    coverRevisions.retain(accounts: accounts)
    self.companion = companion
    learnCoverRevisions(from: companion.snapshot)
    if let manifest = syncedManifest() { learnSyncedRevisions(from: manifest) }
    let previousClient = coverClient
    coverClient = context.map {
      CoverImageClient(
        server: $0.service.server,
        memoryCapacity: 512 * 1024,
        artworkScope: ArtworkAccountScope($0.authenticatedStamp.accountIdentityHash),
        // watchOS cannot decode WebP, so `WatchArtworkThumbnail.prepare` would reject every cover.
        format: .jpeg)
    }
    await previousClient?.clearCachedArtwork()
    guard generation == epoch else { return }
    await cache.retainAccounts(accounts)
    guard generation == epoch else { return }
    // Refresh view task identities after the disk cache has admitted this account.
    generation &+= 1
  }

  func key(
    selection: WatchSelection, size: WatchArtworkSize,
    accountStamp: WatchAccountStamp? = nil, phoneCatalogueStamp: WatchAccountStamp? = nil
  ) -> Key? {
    let stamp: WatchAccountStamp?
    if let phoneCatalogueStamp {
      guard phoneCatalogueStamp == phoneStamp else { return nil }
      stamp = phoneCatalogueStamp
    } else if let accountStamp {
      guard accountStamp == localStamp else { return nil }
      stamp = accountStamp
    } else {
      stamp = localStamp ?? phoneStamp
    }
    guard let stamp else { return nil }
    return Key(
      accountStamp: stamp, reference: coverRevisions.reference(for: selection, accountStamp: stamp), size: size)
  }

  func learnCoverRevisions(from snapshot: WatchCatalogueSnapshot?) {
    guard let snapshot, let stamp = snapshot.accountStamp, [localStamp, phoneStamp].contains(stamp) else { return }
    if coverRevisions.learn(from: snapshot) { coverRevisionEpoch &+= 1 }
  }

  func learnCoverRevisions(from rows: [WatchBrowseRow], accountStamp: WatchAccountStamp) {
    guard [localStamp, phoneStamp].contains(accountStamp) else { return }
    if coverRevisions.learn(rows, accountStamp: accountStamp) { coverRevisionEpoch &+= 1 }
  }

  /// Teaches the pushed manifest's revisions under the phone stamp, and under the Watch's own
  /// sign-in when the phone vouches it is the same account.
  func learnSyncedRevisions(from manifest: WatchArtworkManifest) {
    var changed = false
    if manifest.accountStamp == phoneStamp { changed = coverRevisions.learn(manifest, as: manifest.accountStamp) }
    if let localStamp, manifest.authenticatedAccountStamp == localStamp {
      changed = coverRevisions.learn(manifest, as: localStamp) || changed
    }
    if changed { coverRevisionEpoch &+= 1 }
  }

  /// Rows showing a placeholder for these keys ask again.
  func syncedCoversArrived(_ keys: [Key]) {
    for key in keys {
      bumpRevision(key)
      guard let localStamp else { continue }
      let local = Key(accountStamp: localStamp, reference: key.reference, size: key.size)
      if syncedAlias(of: local) == key { bumpRevision(local) }
    }
  }

  func image(for key: Key, backdrop: Bool = false) async -> UIImage? {
    let epoch = generation
    let name = cacheName(key, backdrop: backdrop)
    if let image = images.object(forKey: name) {
      if await cache.needsRefresh(key), await syncedData(for: key) == nil {
        Task { _ = await self.load(key, lane: .refresh) }
      }
      return image
    }
    if let (data, source) = await storedData(for: key) {
      guard epoch == generation, !Task.isCancelled else { return nil }
      let image = decode(data, backdrop: backdrop)
      if let image { remember(image, name: name) }
      if await cache.needsRefresh(source) { Task { _ = await self.load(key, lane: .refresh) } }
      return image
    }
    guard let data = await load(key), epoch == generation, !Task.isCancelled else { return nil }
    let image = decode(data, backdrop: backdrop)
    if let image { remember(image, name: name) }
    return image
  }

  func revision(for key: Key?) -> Int { key.flatMap { revisions[$0] } ?? 0 }

  func pinDownloads(_ selections: [WatchSelection]) async {
    guard let localStamp else {
      await cache.setPinned([])
      return
    }
    let keys = Set(
      selections.flatMap { selection in
        [WatchArtworkSize.row, .player].map {
          Key(
            accountStamp: localStamp,
            reference: coverRevisions.reference(for: selection, accountStamp: localStamp), size: $0)
        }
      })
    await cache.setPinned(keys)
    for key in keys {
      guard !Task.isCancelled, self.localStamp == localStamp else { return }
      if await storedData(for: key) == nil { _ = await load(key) }
    }
  }

  /// The key's own cover, else the phone's pushed copy when the phone vouches for the account,
  /// with the key it was stored under.
  private func storedData(for key: Key) async -> (Data, Key)? {
    if let data = await cache.data(for: key) { return (data, key) }
    guard let alias = syncedAlias(of: key), let data = await cache.data(for: alias) else { return nil }
    return (data, alias)
  }

  private func syncedData(for key: Key) async -> Data? {
    guard let alias = syncedAlias(of: key) else { return nil }
    return await cache.data(for: alias)
  }

  /// The phone-stamped key a Watch sign-in key may draw from: only when the phone's manifest says
  /// its catalogue account and the Watch's sign-in are the same person on the same server.
  private func syncedAlias(of key: Key) -> Key? {
    guard let localStamp, key.accountStamp == localStamp, let phoneStamp, phoneStamp != localStamp,
      let manifest = syncedManifest(), manifest.accountStamp == phoneStamp,
      manifest.authenticatedAccountStamp == localStamp
    else { return nil }
    return Key(accountStamp: phoneStamp, reference: key.reference, size: key.size)
  }

  /// Which gate a load waits at: a missing cover, or the age-based refresh of one already shown.
  private enum Lane { case wanted, refresh }
  private enum Outcome {
    case cancelled, failed
    case loaded(Data)
  }
  private struct Failure {
    var attempts: Int
    var retryAt: Date
  }

  /// Joins or starts the key's flight. The caller's interest keeps a queued flight alive; when the
  /// last interested caller is cancelled (its row left the screen) a flight still waiting for a
  /// permit is cancelled, so visible rows never queue behind rows that have gone.
  private func load(_ key: Key, lane: Lane = .wanted) async -> Data? {
    guard let task = flights[key]?.task ?? startFlight(key, lane: lane) else { return nil }
    let token = UUID()
    interest[key, default: []].insert(token)
    let data = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      Task { @MainActor [weak self] in self?.loseInterest(key, token: token) }
    }
    loseInterest(key, token: token)
    return data
  }

  private func loseInterest(_ key: Key, token: UUID) {
    guard interest[key]?.remove(token) != nil, interest[key]?.isEmpty == true else { return }
    interest[key] = nil
    if !permitted.contains(key), let flight = flights[key] {
      flight.task.cancel()
      flights[key] = nil
    }
  }

  private func startFlight(_ key: Key, lane: Lane) -> Task<Data?, Never>? {
    guard [localStamp, phoneStamp].contains(key.accountStamp) else { return nil }
    if let failure = failures[key], failure.retryAt > Date() { return nil }
    let epoch = generation
    let id = UUID()
    let task = Task { [weak self] () -> Data? in
      guard let self else { return nil }
      let outcome = await self.fetch(key, lane: lane, epoch: epoch)
      if self.flights[key]?.id == id { self.flights[key] = nil }
      guard self.generation == epoch else { return nil }
      switch outcome {
      case .cancelled:
        return nil
      case .failed:
        self.recordFailure(key)
        return nil
      case .loaded(let data):
        self.failures[key] = nil
        await self.remember(data, for: key, epoch: epoch)
        return data
      }
    }
    flights[key] = (id, task)
    return task
  }

  private func fetch(_ key: Key, lane: Lane, epoch: Int) async -> Outcome {
    let gate = lane == .refresh ? refreshGate : self.gate
    guard let permit = try? await gate.acquire() else { return .cancelled }
    guard generation == epoch, !Task.isCancelled else {
      await permit.release()
      return .cancelled
    }
    permitted.insert(key)
    defer { permitted.remove(key) }
    let data: Data?
    if key.accountStamp == localStamp {
      // The phone only answers for its own catalogue stamp, so a cover under the Watch's own
      // sign-in can come only from the Watch's server client.
      if let client = coverClient, case .audiobookshelf(let id) = key.reference.source {
        let artwork = ArtworkKey(
          accountScope: ArtworkAccountScope(key.accountStamp.accountIdentityHash),
          itemID: id, variant: .libraryThumbnail(pixelWidth: key.size.pixelWidth),
          revision: ArtworkRevision(key.reference.revision))
        if let result = try? await client.fetch(artwork) {
          data = await Task.detached(priority: .utility) {
            WatchArtworkThumbnail.prepare(result.data, size: key.size)
          }.value
        } else {
          data = nil
        }
      } else {
        data = nil
      }
    } else {
      data = await companion?.artwork(
        WatchArtworkRequest(accountStamp: key.accountStamp, reference: key.reference, size: key.size))
    }
    await permit.release()
    return data.map(Outcome.loaded) ?? .failed
  }

  private func remember(_ data: Data, for key: Key, epoch: Int) async {
    let stored = await cache.store(data, for: key)
    guard generation == epoch, stored else { return }
    let plain = cacheName(key, backdrop: false)
    let backdrop = cacheName(key, backdrop: true)
    guard images.object(forKey: plain) != nil || images.object(forKey: backdrop) != nil else { return }
    images.removeObject(forKey: plain)
    images.removeObject(forKey: backdrop)
    bumpRevision(key)
  }

  /// Exponential jittered backoff (API-CONVENTIONS rule 14). When it ends, the key's revision
  /// bumps so a row still showing its placeholder asks again without being scrolled away.
  private func recordFailure(_ key: Key) {
    if failures[key] == nil, failures.count >= 128,
      let oldest = failures.min(by: { $0.value.retryAt < $1.value.retryAt })?.key
    {
      failures[oldest] = nil
    }
    let attempts = (failures[key]?.attempts ?? 0) + 1
    let ceiling = min(Self.maximumRetryDelay, Self.baseRetryDelay * pow(2, Double(min(attempts - 1, 16))))
    let delay = Double.random(in: (ceiling / 2)...ceiling)
    failures[key] = Failure(attempts: attempts, retryAt: Date().addingTimeInterval(delay))
    let epoch = generation
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard let self, self.generation == epoch, self.failures[key] != nil else { return }
      self.bumpRevision(key)
    }
  }

  private func bumpRevision(_ key: Key) {
    if revisions.count >= 512 { revisions.removeAll() }
    revisions[key, default: 0] += 1
  }

  private func decode(_ data: Data, backdrop: Bool) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let cg = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: backdrop ? 12 : 320,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    else { return nil }
    return UIImage(cgImage: cg)
  }
  private func remember(_ image: UIImage, name: NSString) {
    images.setObject(image, forKey: name, cost: Int(image.size.width * image.size.height) * 4)
  }
  private func cacheName(_ key: Key, backdrop: Bool) -> NSString {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return ((try? encoder.encode(key).base64EncodedString()) ?? "").appending(backdrop ? "-background" : "") as NSString
  }
}
