import Foundation
import Persistence
import WatchProtocol

/// Cancels one queued WatchConnectivity file transfer.
struct WatchArtworkTransferHandle {
  let cancel: @MainActor () -> Void
}

/// Pushes the phone's row covers to the Watch for one account. The phone lists every cover it can
/// serve; the Watch answers with what it lacks, and the phone fetches those, two at a time, while
/// the phone app runs. Nothing here runs in the background on its own.
@MainActor
final class WatchArtworkSyncPublisher {
  struct Sender {
    var isReady: @MainActor () -> Bool
    var transfer: @MainActor (URL, String) -> WatchArtworkTransferHandle?
    /// Files WatchConnectivity is still sending, possibly queued by an earlier launch.
    var outstanding: @MainActor () -> Set<URL>
  }

  nonisolated static let defaultDebounce: Duration = .seconds(2)
  /// Queued want lists beyond this are dropped oldest first; the Watch asks again.
  private static let maxQueuedWantLists = 4
  /// Fetches in flight at once: two of the six Audiobookshelf cover slots (API-CONVENTIONS
  /// rule 13), so phone browsing keeps four.
  private static let fetchWidth = 2

  nonisolated static var defaultOutbox: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("WatchArtworkOutbox", isDirectory: true)
  }

  private let accountStamp: WatchAccountStamp
  private let authenticatedStamp: WatchAccountStamp?
  private let load: @MainActor (WatchArtworkRequest) async -> Data?
  private let sender: Sender
  private let outbox: URL
  private let debounce: Duration
  private var library: [ItemSummary]?
  private var followedShows: [ItemSummary]?
  private var snapshot: WatchCatalogueSnapshot?
  private var lastManifest: WatchArtworkManifest?
  private var manifestTransfer: (url: URL, handle: WatchArtworkTransferHandle)?
  private var bundleTransfers: [URL: WatchArtworkTransferHandle] = [:]
  private var manifestTask: Task<Void, Never>?
  private var forceManifest = false
  private var wantLists: [WatchArtworkWantList] = []
  private var answerTask: Task<Void, Never>?
  private var stopped = false

  init(
    accountStamp: WatchAccountStamp, authenticatedStamp: WatchAccountStamp?,
    load: @escaping @MainActor (WatchArtworkRequest) async -> Data?, sender: Sender,
    outbox: URL = WatchArtworkSyncPublisher.defaultOutbox,
    debounce: Duration = WatchArtworkSyncPublisher.defaultDebounce
  ) {
    self.accountStamp = accountStamp
    self.authenticatedStamp = authenticatedStamp
    self.load = load
    self.sender = sender
    self.outbox = outbox
    self.debounce = debounce
    discardFiles(except: sender.outstanding())
  }

  func update(library: [ItemSummary]) {
    self.library = library
    scheduleManifest()
  }

  func update(followedShows: [ItemSummary]) {
    self.followedShows = followedShows
    scheduleManifest()
  }

  func update(snapshot: WatchCatalogueSnapshot?) {
    guard snapshot?.accountStamp == nil || snapshot?.accountStamp == accountStamp else { return }
    self.snapshot = snapshot
    scheduleManifest()
  }

  func watchBecameAvailable() { scheduleManifest() }

  func receive(_ wantList: WatchArtworkWantList) {
    guard !stopped, wantList.accountStamp == accountStamp else { return }
    if wantList.isManifestRequest {
      scheduleManifest(force: true)
      return
    }
    wantLists.removeAll { $0.id == wantList.id }
    wantLists.append(wantList)
    if wantLists.count > Self.maxQueuedWantLists { wantLists.removeFirst() }
    guard answerTask == nil else { return }
    answerTask = Task { [weak self] in
      while let self, !Task.isCancelled, !self.wantLists.isEmpty {
        await self.answer(self.wantLists.removeFirst())
      }
      self?.answerTask = nil
    }
  }

  func transferFinished(_ url: URL) {
    if manifestTransfer?.url == url { manifestTransfer = nil }
    bundleTransfers[url] = nil
    try? FileManager.default.removeItem(at: url)
  }

  /// Ends this account's sync: queued transfers are cancelled and their files deleted.
  func stop() {
    stopped = true
    manifestTask?.cancel()
    answerTask?.cancel()
    wantLists.removeAll()
    var urls = Array(bundleTransfers.keys)
    if let manifestTransfer { urls.append(manifestTransfer.url) }
    manifestTransfer?.handle.cancel()
    for handle in bundleTransfers.values { handle.cancel() }
    manifestTransfer = nil
    bundleTransfers.removeAll()
    for url in urls { try? FileManager.default.removeItem(at: url) }
  }

  /// Waits for the pending manifest and want-list work; tests use it to observe the result.
  func settle() async {
    while manifestTask != nil || answerTask != nil {
      await manifestTask?.value
      await answerTask?.value
    }
  }

  /// Every cover the Watch may draw from this phone, most wanted first: player covers for the
  /// catalogue's continue-listening items, then a row cover for every book and Audiobookshelf
  /// show, then followed RSS shows. Ebook-only items never appear on the Watch.
  nonisolated static func covers(
    library: [ItemSummary], followedShows: [ItemSummary], snapshot: WatchCatalogueSnapshot?
  ) -> [WatchArtworkCover] {
    var covers: [WatchArtworkCover] = []
    var seen: Set<WatchArtworkCover> = []
    func add(_ cover: WatchArtworkCover) {
      guard covers.count < WatchArtworkSyncLimits.maxManifestCovers, seen.insert(cover).inserted,
        (try? cover.reference.validate()) != nil
      else { return }
      covers.append(cover)
    }
    for item in snapshot?.items ?? [] {
      add(
        WatchArtworkCover(
          reference: WatchArtworkReference(
            selection: item.selection, revision: item.artworkRevision ?? WatchArtworkReference.unversioned),
          size: .player))
    }
    for item in library where item.category != .ebook {
      add(
        WatchArtworkCover(
          reference: WatchArtworkReference(
            source: .audiobookshelf(itemID: item.serverItemId),
            revision: WatchCatalogueWireMapper.artworkRevision(item.serverUpdatedAt)
              ?? WatchArtworkReference.unversioned),
          size: .row))
    }
    for show in followedShows where show.providerArtworkSource != nil {
      guard case .rss(let feedID) = PodcastSourceIdentity(itemId: show.serverItemId)?.source else { continue }
      add(WatchArtworkCover(reference: WatchArtworkReference(source: .nativeFeed(feedID: String(feedID))), size: .row))
    }
    return covers
  }

  private func scheduleManifest(force: Bool = false) {
    guard !stopped else { return }
    forceManifest = forceManifest || force
    manifestTask?.cancel()
    let debounce = debounce
    manifestTask = Task { [weak self] in
      if debounce > .zero { try? await Task.sleep(for: debounce) }
      guard !Task.isCancelled, let self else { return }
      self.manifestTask = nil
      self.sendManifest()
    }
  }

  private func sendManifest() {
    // Until both sources have reported, a manifest would tell the Watch to prune covers it keeps.
    guard !stopped, sender.isReady(), let library, let followedShows,
      let manifest = try? WatchArtworkManifest(
        accountStamp: accountStamp, authenticatedAccountStamp: authenticatedStamp,
        covers: Self.covers(library: library, followedShows: followedShows, snapshot: snapshot))
    else { return }
    if !forceManifest, let lastManifest, lastManifest.hasSameCovers(as: manifest) { return }
    guard let (url, handle) = send(manifest, kind: WatchArtworkSyncTransport.manifestKind) else { return }
    forceManifest = false
    if let previous = manifestTransfer {
      previous.handle.cancel()
      try? FileManager.default.removeItem(at: previous.url)
    }
    manifestTransfer = (url, handle)
    lastManifest = manifest
  }

  private func answer(_ wantList: WatchArtworkWantList) async {
    var entries: [WatchArtworkBundle.Entry] = []
    var bytes = 0
    var unavailable: [WatchArtworkCover] = []
    var index = 0
    while index < wantList.covers.count {
      guard !Task.isCancelled, !stopped else { return }
      let chunk = Array(wantList.covers[index..<min(index + Self.fetchWidth, wantList.covers.count)])
      index += chunk.count
      for (cover, data) in await fetch(chunk) {
        guard let data, !data.isEmpty, data.count <= WatchArtworkReply.maxImageBytes else {
          unavailable.append(cover)
          continue
        }
        if bytes + data.count > WatchArtworkSyncLimits.maxBundleImageBytes {
          sendBundle(answering: wantList, entries: entries, unavailable: [], isFinal: false)
          entries = []
          bytes = 0
        }
        entries.append(WatchArtworkBundle.Entry(cover: cover, imageData: data))
        bytes += data.count
      }
    }
    guard !Task.isCancelled, !stopped else { return }
    sendBundle(answering: wantList, entries: entries, unavailable: unavailable, isFinal: true)
  }

  private func fetch(_ covers: [WatchArtworkCover]) async -> [(WatchArtworkCover, Data?)] {
    let stamp = accountStamp
    let load = load
    return await withTaskGroup(of: (Int, Data?).self) { group in
      for (offset, cover) in covers.enumerated() {
        group.addTask { @MainActor in
          (offset, await load(WatchArtworkRequest(accountStamp: stamp, reference: cover.reference, size: cover.size)))
        }
      }
      var results = [Data?](repeating: nil, count: covers.count)
      for await (offset, data) in group { results[offset] = data }
      return Array(zip(covers, results))
    }
  }

  private func sendBundle(
    answering wantList: WatchArtworkWantList, entries: [WatchArtworkBundle.Entry],
    unavailable: [WatchArtworkCover], isFinal: Bool
  ) {
    guard sender.isReady(),
      let bundle = try? WatchArtworkBundle(
        answering: wantList, entries: entries, unavailable: unavailable, isFinal: isFinal),
      let (url, handle) = send(bundle, kind: WatchArtworkSyncTransport.bundleKind)
    else { return }
    bundleTransfers[url] = handle
  }

  private func send<Value: WatchWireValue>(_ value: Value, kind: String) -> (URL, WatchArtworkTransferHandle)? {
    let url = outbox.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    do {
      try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
      try WatchWireCodec.encode(value).write(
        to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    } catch {
      return nil
    }
    guard let handle = sender.transfer(url, kind) else {
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    return (url, handle)
  }

  /// Files left by an earlier launch whose transfer has finished or been dropped.
  private func discardFiles(except outstanding: Set<URL>) {
    let keep = Set(outstanding.map(\.standardizedFileURL.path))
    let files = (try? FileManager.default.contentsOfDirectory(at: outbox, includingPropertiesForKeys: nil)) ?? []
    for file in files where !keep.contains(file.standardizedFileURL.path) {
      try? FileManager.default.removeItem(at: file)
    }
  }
}
