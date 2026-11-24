import Foundation
import WatchProtocol

/// Latest-only context delivery. Failed or inactive sends retain one bounded value.
@MainActor
final class WatchCatalogueTransport {
  typealias Sender = @MainActor (Data) throws -> Void
  typealias Encoder = @Sendable (WatchCatalogueSnapshot) throws -> Data

  /// The snapshot and the bytes it encoded to. Held together so a publication encodes once, not
  /// again on every send and retry.
  nonisolated private struct Pending: Sendable {
    let snapshot: WatchCatalogueSnapshot
    let data: Data
  }

  private let send: Sender
  private let encode: Encoder
  private let isReady: @MainActor () -> Bool
  private let persistTimestamp: @MainActor (Date) -> Void
  private var lastTimestamp: Date?
  /// Seeded with the restored `lastTimestamp`, so a launch that publishes nothing, or a second
  /// lifecycle persist with no publication in between, writes nothing.
  private var lastPersistedTimestamp: Date?
  private var pendingPublication: Pending?
  /// Identifies the newest enqueued publication. An encode overtaken before it starts or while it
  /// runs is dropped: delivery is latest-only, so its bytes would only be replaced.
  private var latestRequest: UInt64 = 0
  /// Encodes run one at a time, so a slow encode cannot land after a newer one and roll the
  /// Watch's context back.
  private var encoding: Task<Void, Never>?

  var pending: WatchCatalogueSnapshot? { pendingPublication?.snapshot }

  init(
    lastTimestamp: Date? = nil,
    isReady: @escaping @MainActor () -> Bool,
    persistTimestamp: @escaping @MainActor (Date) -> Void = { _ in },
    encode: @escaping Encoder = { try WatchWireCodec.encode($0) },
    send: @escaping Sender
  ) {
    self.lastTimestamp = lastTimestamp
    self.lastPersistedTimestamp = lastTimestamp
    self.isReady = isReady
    self.persistTimestamp = persistTimestamp
    self.encode = encode
    self.send = send
  }

  /// Stamps the publication on the main actor, then validates and encodes it off it. The encode
  /// is the whole catalogue through `JSONEncoder` and runs twice a second while audio plays.
  func enqueue(_ value: WatchCatalogueSnapshot) {
    let date = max(value.generatedAt, lastTimestamp?.addingTimeInterval(0.001) ?? value.generatedAt)
    lastTimestamp = date
    latestRequest &+= 1
    let request = latestRequest
    let previous = encoding
    let encode = encode
    encoding = Task { [weak self] in
      await previous?.value
      guard let self, request == self.latestRequest else { return }
      let pending = await Task.detached(priority: .userInitiated) { () -> Pending? in
        guard
          let snapshot = try? WatchCatalogueSnapshot(
            accountStamp: value.accountStamp, generatedAt: date,
            items: value.items, playbackState: value.playbackState,
            authenticatedAccountStamp: value.authenticatedAccountStamp,
            playbackRate: value.playbackRate,
            skipBackwardSeconds: value.skipBackwardSeconds, skipForwardSeconds: value.skipForwardSeconds,
            playbackRatePresets: value.playbackRatePresets,
            followedPodcastsEnabled: value.followedPodcastsEnabled,
            removePlayedNativeEpisodes: value.removePlayedNativeEpisodes),
          let data = try? encode(snapshot)
        else { return nil }
        return Pending(snapshot: snapshot, data: data)
      }.value
      guard let pending, request == self.latestRequest else { return }
      self.pendingPublication = pending
      self.flush()
    }
  }

  /// Returns once every publication enqueued so far has been encoded and offered to `send`.
  func settle() async {
    while let encoding {
      await encoding.value
      // A publication enqueued while this one was awaited chains a new task; wait for that too.
      if self.encoding == encoding { return }
    }
  }

  /// Writes the dedup timestamp through to storage at a lifecycle boundary, not on every
  /// publication. It only has to survive process death; `lastTimestamp` is the live authority. A
  /// per-publication `UserDefaults.standard` write would run several times a second, and
  /// `UserDefaults.didChangeNotification` names no key, so every `@AppStorage` reader would
  /// invalidate each time.
  func persistLastTimestamp() {
    guard let lastTimestamp, lastTimestamp != lastPersistedTimestamp else { return }
    lastPersistedTimestamp = lastTimestamp
    persistTimestamp(lastTimestamp)
  }

  func flush() {
    guard isReady(), let pendingPublication else { return }
    do {
      try send(pendingPublication.data)
      self.pendingPublication = nil
    } catch {
      // The latest context is retried on a later activation, reachability change or publication.
    }
  }
}
