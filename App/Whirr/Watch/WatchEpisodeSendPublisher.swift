import Foundation
import Persistence
import WatchProtocol

/// Everything the phone knows about one `rssEpisode` row, independent of any phone download. An
/// offer is described from the feed's own metadata because the Watch downloads the enclosure
/// itself (ADR 0020 Decision 1); the phone never needs a copy.
struct WatchEpisodeOfferFacts: Equatable, Sendable {
  let feedId: Int64
  let identityKey: String
  let title: String
  let showTitle: String
  let duration: Double?
  /// The enclosure the Watch will fetch. A URL that cannot cross the wire makes the episode
  /// ineligible rather than being sent unvalidated.
  let enclosureURL: URL?
  /// The length the feed declared, as a reservation estimate only (ADR 0020 Decision 2).
  let declaredBytes: Int64?
  /// The size of the phone's own finished copy, when it has one: a measured length, so it beats the
  /// feed's. The phone still sends no file.
  var downloadedBytes: Int64? = nil
  let mimeType: String
  /// The chapters parsed from the phone's own copy, when it has one; an unparsed episode sends
  /// none.
  let chapters: [WatchEpisodeChapter]
  let position: Double
  /// The phone's `rssEpisodeState.updatedAt`; `nil` when the phone has no state row.
  let lastListenedAt: Date?
  let finished: Bool
  /// The same `updatedAt`, kept separately for the finished comparison against `requestedAt`.
  let stateUpdatedAt: Date?
  /// ADR 0006's private-feed rule: a credentialed feed is never offered (ADR 0020 Decision 2).
  let isPrivateFeed: Bool
}

/// Sends the phone's desired native-RSS set to the active Watch and keeps it in step.
///
/// The desired set is device-owned, so this object is process-lifetime and is not composed
/// or stopped by the ABS account bind. It touches no phone file: each offer entry names the
/// enclosure URL, its declared length and its chapters, and the Watch reports what it holds.
///
/// Ownership split: the phone offers; the Watch downloads and reports. Only a `ready`
/// inventory entry is delivery truth, and a failed download is retried by re-offering the episode
/// at a new revision.
@MainActor
final class WatchEpisodeSendPublisher {
  struct Reader {
    var facts: @MainActor (Int64) async -> WatchEpisodeOfferFacts?
  }

  struct Sender {
    var isWatchInstalled: @MainActor () -> Bool
    /// Queues the encoded offer over `transferUserInfo`; the Watch answers with an inventory.
    var sendOffer: @MainActor (Data) -> Bool
  }

  nonisolated static let defaultDebounce: Duration = .seconds(1)

  private struct SentOffer {
    let generation: UInt64
    let entries: [WatchEpisodeOfferEntry]
  }

  private let copies: RSSWatchCopyStore
  private let reader: Reader
  private let sender: Sender
  private let now: @MainActor () -> Date
  /// Whether a finished episode leaves the Watch once the phone records the finish. Off pins the
  /// copy until the listener removes it by hand.
  private let removesPlayedEpisodes: @MainActor () -> Bool
  private let coalescer: WatchSendCoalescer

  /// The last offer actually queued in this process, so an unchanged generation is not re-queued.
  private var lastSentOffer: SentOffer?

  init(
    copies: RSSWatchCopyStore, reader: Reader, sender: Sender,
    now: @escaping @MainActor () -> Date = { Date() },
    debounce: Duration = WatchEpisodeSendPublisher.defaultDebounce,
    removesPlayedEpisodes: @escaping @MainActor () -> Bool = { true }
  ) {
    self.copies = copies
    self.reader = reader
    self.sender = sender
    self.now = now
    self.removesPlayedEpisodes = removesPlayedEpisodes
    self.coalescer = WatchSendCoalescer(debounce: debounce)
  }

  /// Coalesced planning. Every trigger (composition, install state, an applied inventory, and the
  /// UI's own store writes) calls this.
  func refresh() {
    coalescer.schedule { [weak self] token in
      await self?.runRefresh(token: token)
    }
  }

  /// The Watch app became installed (or the session activated): the offer may now be sent.
  func watchBecameAvailable() { refresh() }

  /// Waits for the pending planning pass; tests observe the result through it.
  func settle() async {
    await coalescer.settle()
  }

  /// The phone account boundary: the previous account's desired set is gone, and the next
  /// empty offer is what makes the Watch drop the copies. The Watch's identity and sequence stay.
  func clearForAccountChange() async {
    try? await copies.clearForAccountChange()
    lastSentOffer = nil
    refresh()
  }

  // MARK: - Planning

  private func runRefresh(token: Int) async {
    guard !coalescer.isStopped, coalescer.isCurrent(token) else { return }

    var missingFacts: Set<Int64> = []
    var factsByID: [Int64: WatchEpisodeOfferFacts] = [:]
    func facts(_ episodeId: Int64) async -> WatchEpisodeOfferFacts? {
      if let cached = factsByID[episodeId] { return cached }
      if missingFacts.contains(episodeId) { return nil }
      guard let loaded = await reader.facts(episodeId) else {
        missingFacts.insert(episodeId)
        return nil
      }
      factsByID[episodeId] = loaded
      return loaded
    }

    let now = self.now()
    guard var rows = try? await copies.copies() else { return }
    var set = (try? await copies.setState()) ?? RSSWatchCopySetState()
    guard coalescer.isCurrent(token) else { return }
    var changed = false

    // (a) A finished episode leaves the Watch, but only a finish recorded after the request. A
    // re-send bumps `requestedAt`, so a played episode can be deliberately sent again. The setting
    // is off for a listener who wants played episodes kept until they remove them.
    if removesPlayedEpisodes() {
      for row in rows
      where [.wanted, .waitingForWatch, .sending, .delivered].contains(row.state) {
        guard let episode = await facts(row.episodeId), episode.finished,
          let updatedAt = episode.stateUpdatedAt, updatedAt > row.requestedAt
        else { continue }
        _ = try? await copies.removeFromWatch(episodeId: row.episodeId, now: now)
        changed = true
      }
    }
    guard coalescer.isCurrent(token) else { return }

    // (b) Every state fix is done before the offer is read, so membership is a function of store
    // state and the generation the offer carries matches the membership it lists.
    if changed {
      if let reloaded = try? await copies.copies() { rows = reloaded }
      if let reloaded = try? await copies.setState() { set = reloaded }
      guard coalescer.isCurrent(token) else { return }
    }

    // (c) The offer is a pure read of that state: no file or download checks, newest request first.
    // A failed row stays a member at its current revision: the Watch ignores it until Try Again
    // requests a new revision, and dropping it would change membership without a new generation.
    var entries: [WatchEpisodeOfferEntry] = []
    for row in rows where row.state != .removed && row.state != .declined {
      guard let episode = await facts(row.episodeId),
        let selection = WatchEpisodeSendEligibility.selection(
          feedId: episode.feedId, identityKey: episode.identityKey),
        let entry = Self.offerEntry(
          episode: episode, selection: selection, revision: row.revision)
      else { continue }
      entries.append(entry)
    }
    guard coalescer.isCurrent(token) else { return }

    let offer = fittedOffer(
      generation: set.generation, installID: set.watchInstallID, entries: entries, now: now)
    sendIfNewer(offer, acknowledgedGeneration: set.acknowledgedGeneration)
  }

  /// The whole desired set as one offer, trimmed from the tail only by the wire caps. `fitting`
  /// throws when the set exceeds `maxOfferEntries`, so the entry cap is applied first.
  private func fittedOffer(
    generation: Int64, installID: String?, entries: [WatchEpisodeOfferEntry], now: Date
  ) -> WatchEpisodeSendOffer? {
    guard generation > 0 else { return nil }
    let bounded = Array(entries.prefix(WatchEpisodeSendLimits.maxOfferEntries))
    return try? WatchEpisodeSendOffer.fitting(
      generation: UInt64(clamping: generation), watchInstallID: installID, entries: bounded,
      sentAt: now
    ).offer
  }

  /// The Watch applies a generation at most once and ignores anything at or below it, so a
  /// same-generation resend only queues redundant user info. A new generation is still sent when it
  /// differs from the last one this process queued; the Watch must learn the new membership.
  private func sendIfNewer(
    _ offer: WatchEpisodeSendOffer?, acknowledgedGeneration: Int64
  ) {
    guard let offer, sender.isWatchInstalled(),
      offer.generation > UInt64(clamping: acknowledgedGeneration)
    else { return }
    if let lastSentOffer, lastSentOffer.generation == offer.generation,
      lastSentOffer.entries == offer.entries
    {
      return
    }
    guard let data = try? WatchWireCodec.encode(offer), sender.sendOffer(data) else { return }
    lastSentOffer = SentOffer(generation: offer.generation, entries: offer.entries)
  }

  // MARK: - Offer entries

  /// A wire offer entry, or `nil` when the row cannot be described. Membership comes from the store;
  /// the entry itself is entirely feed metadata, so a private feed or an enclosure the wire rejects
  /// keeps the episode out of the offer.
  static func offerEntry(
    episode: WatchEpisodeOfferFacts, selection: WatchNativeSelection, revision: Int64
  ) -> WatchEpisodeOfferEntry? {
    guard revision > 0, episode.isPrivateFeed == false, let enclosureURL = episode.enclosureURL
    else { return nil }
    let duration: Double? =
      episode.duration.flatMap {
        $0.isFinite && $0 > 0 && $0 <= WatchHandoffLimits.maxPositionSeconds ? $0 : nil
      }
    // A finished episode starts from the beginning, exactly as the phone's own Play does for a
    // finished title (`ItemDetailActionRow` passes `fromStart: true`). The stored position of a
    // finished episode sits at its end, so sending it as-is would start the Watch copy at the end;
    // A re-sent finished episode's position is also reset.
    let position =
      episode.finished
      ? 0
      : episode.position.isFinite
        ? min(max(episode.position, 0), WatchHandoffLimits.maxPositionSeconds) : 0
    return try? WatchEpisodeOfferEntry(
      selection: selection, revision: UInt64(revision),
      title: episode.title.isEmpty ? episode.showTitle : episode.title,
      showTitle: episode.showTitle.isEmpty ? episode.title : episode.showTitle,
      duration: duration,
      declaredBytes: Self.offerBytes(
        downloaded: episode.downloadedBytes, declared: episode.declaredBytes, duration: duration),
      enclosureURL: enclosureURL, mimeType: episode.mimeType, chapters: episode.chapters,
      position: position, lastListenedAt: episode.lastListenedAt)
  }

  /// An estimate's bitrate: 192 kbps, above the 64 to 128 kbps most spoken-word feeds publish, so
  /// the estimate errs large. The Watch replaces it with the response's length once the download
  /// starts, and a file larger than the estimate is still accepted.
  static let estimatedBytesPerSecond: Double = 24_000

  /// The size the Watch reserves for an episode. Without one the Watch reserves the per-episode
  /// ceiling (1 GiB), so two unsized episodes sent together overflow its 2 GB and the second is
  /// declined. In order: the phone's own copy, the feed's declared length, then the duration at
  /// `estimatedBytesPerSecond`.
  static func offerBytes(downloaded: Int64?, declared: Int64?, duration: Double?) -> Int64? {
    if let measured = declaredBytes(downloaded) { return measured }
    if let declared = declaredBytes(declared) { return declared }
    guard let duration, duration.isFinite, duration > 0 else { return nil }
    let estimate = (duration * estimatedBytesPerSecond).rounded(.up)
    guard estimate < Double(WatchEpisodeSendLimits.maxEpisodeBytes) else { return nil }
    return declaredBytes(Int64(estimate))
  }

  /// A declared length is a reservation estimate, so a zero, negative or over-cap value is simply
  /// unknown rather than an entry the wire refuses.
  static func declaredBytes(_ declared: Int64?) -> Int64? {
    guard let declared, declared > 0, declared <= WatchEpisodeSendLimits.maxEpisodeBytes else {
      return nil
    }
    return declared
  }
}
