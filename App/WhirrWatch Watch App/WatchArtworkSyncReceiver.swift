import Foundation
import WatchConnectivity
import WatchPlayback
import WatchProtocol

/// Receives pushed covers from the phone. Files land in an inbox before WatchConnectivity deletes
/// them, and ingest re-reads the inbox at every launch, because the background task that delivered
/// a file can be completed and the app suspended mid-ingest. Ingesting a file twice is harmless.
@MainActor
final class WatchArtworkSyncReceiver {
  private nonisolated static let manifestExtension = "manifest"
  private nonisolated static let bundleExtension = "bundle"

  nonisolated static var defaultDirectory: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("WatchArtworkSync", isDirectory: true)
  }

  private let cache: WatchArtworkCache
  private let inbox: URL
  private let stateURL: URL
  private let phoneStamp: @MainActor () -> WatchAccountStamp?
  private let send: @MainActor (WatchArtworkWantList) -> Void
  /// A request is only recorded as sent when it can be queued; the plan waits a day for an answer.
  private let canSend: @MainActor () -> Bool
  private var plan: WatchArtworkSyncPlan
  private var work: Task<Void, Never>?
  /// Told when a manifest is accepted, so rows learn its revisions, and when covers are stored.
  var onManifest: @MainActor (WatchArtworkManifest) -> Void = { _ in }
  var onCovers: @MainActor ([WatchArtworkCache.Key]) -> Void = { _ in }

  var manifest: WatchArtworkManifest? { plan.manifest }

  init(
    cache: WatchArtworkCache, directory: URL = WatchArtworkSyncReceiver.defaultDirectory,
    phoneStamp: @escaping @MainActor () -> WatchAccountStamp?,
    canSend: @escaping @MainActor () -> Bool,
    send: @escaping @MainActor (WatchArtworkWantList) -> Void
  ) {
    self.cache = cache
    inbox = Self.inbox(in: directory)
    stateURL = directory.appendingPathComponent("plan.json")
    self.phoneStamp = phoneStamp
    self.send = send
    self.canSend = canSend
    plan =
      (try? Data(contentsOf: stateURL))
      .flatMap { try? JSONDecoder().decode(WatchArtworkSyncPlan.self, from: $0) }
      .flatMap { (try? $0.manifest?.validate()) != nil ? $0 : nil } ?? WatchArtworkSyncPlan()
  }

  /// Moves a received file into the inbox. Must run before the delegate callback returns.
  nonisolated static func accept(_ file: WCSessionFile, directory: URL = defaultDirectory) {
    let kind = file.metadata?[WatchArtworkSyncTransport.fileKind] as? String
    let ext: String
    switch kind {
    case WatchArtworkSyncTransport.manifestKind: ext = manifestExtension
    case WatchArtworkSyncTransport.bundleKind: ext = bundleExtension
    default: return
    }
    let size = (try? file.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
    guard size <= WatchArtworkSyncLimits.maxReceivedFileBytes else { return }
    let inbox = inbox(in: directory)
    // A sortable timestamp keeps a later manifest after an earlier one.
    let name = String(format: "%020.6f", Date().timeIntervalSinceReferenceDate) + "-" + UUID().uuidString
    try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try? FileManager.default.moveItem(
      at: file.fileURL, to: inbox.appendingPathComponent(name).appendingPathExtension(ext))
  }

  /// Ingests the inbox, then asks the phone for whatever is still missing. Calls are serialised.
  func process() {
    let previous = work
    work = Task { [weak self] in
      await previous?.value
      await self?.ingest()
      await self?.requestIfNeeded()
    }
  }

  private func ingest() async {
    let files =
      ((try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    for file in files {
      defer { try? FileManager.default.removeItem(at: file) }
      guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
        size <= WatchArtworkSyncLimits.maxReceivedFileBytes,
        let data = try? Data(contentsOf: file)
      else { continue }
      switch file.pathExtension {
      case Self.manifestExtension:
        if let manifest = try? WatchWireCodec.decode(WatchArtworkManifest.self, from: data) {
          await receive(manifest)
        }
      case Self.bundleExtension:
        if let bundle = try? WatchWireCodec.decode(WatchArtworkBundle.self, from: data) { await receive(bundle) }
      default:
        continue
      }
    }
  }

  private func receive(_ manifest: WatchArtworkManifest) async {
    let current = phoneStamp()
    if let current { await cache.admit(current) }
    let synced = await syncedCovers(current)
    let before = plan
    guard case .accepted(let prune) = plan.receive(manifest, currentPhoneStamp: current, synced: synced) else {
      return
    }
    await cache.removeSynced(Set(prune.map { key($0, manifest.accountStamp) }))
    save(ifChangedFrom: before)
    onManifest(manifest)
  }

  private func receive(_ bundle: WatchArtworkBundle) async {
    let current = phoneStamp()
    let before = plan
    guard let entries = plan.receive(bundle, currentPhoneStamp: current) else { return }
    save(ifChangedFrom: before)
    await cache.admit(bundle.accountStamp)
    var stored: [WatchArtworkCache.Key] = []
    for entry in entries {
      let key = key(entry.cover, bundle.accountStamp)
      if await cache.storeSynced(entry.imageData, for: key) { stored.append(key) }
    }
    await cache.flush()
    if !stored.isEmpty { onCovers(stored) }
  }

  private func requestIfNeeded() async {
    guard canSend() else { return }
    let current = phoneStamp()
    let synced = await syncedCovers(current)
    let before = plan
    let request = plan.nextRequest(currentPhoneStamp: current, synced: synced)
    save(ifChangedFrom: before)
    if let request { send(request) }
  }

  private func syncedCovers(_ stamp: WatchAccountStamp?) async -> Set<WatchArtworkCover> {
    guard let stamp else { return [] }
    return Set(
      await cache.syncedKeys(accountStamp: stamp).map { WatchArtworkCover(reference: $0.reference, size: $0.size) })
  }

  private func key(_ cover: WatchArtworkCover, _ stamp: WatchAccountStamp) -> WatchArtworkCache.Key {
    WatchArtworkCache.Key(accountStamp: stamp, reference: cover.reference, size: cover.size)
  }

  /// The plan holds the manifest, so it is written only when it changes.
  private func save(ifChangedFrom before: WatchArtworkSyncPlan) {
    guard plan != before, let data = try? JSONEncoder().encode(plan) else { return }
    try? FileManager.default.createDirectory(
      at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: stateURL, options: .atomic)
  }

  private nonisolated static func inbox(in directory: URL) -> URL {
    directory.appendingPathComponent("Inbox", isDirectory: true)
  }
}
