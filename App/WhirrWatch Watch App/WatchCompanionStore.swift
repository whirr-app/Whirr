import Foundation
import Observation
import WatchConnectivity
import WatchPlayback
import WatchProtocol

@MainActor
@Observable
final class WatchCompanionStore {
  static let cacheKey = "whirr.watch.catalogue.cache.v1"
  static let transportKey = WatchTransportKey.payload
  static let commandTimeout: Duration = .seconds(8)
  static let browseTimeout: Duration = .seconds(10)

  private(set) var cache: WatchCatalogueCache
  private(set) var pendingCommandID: UUID?
  private(set) var lastOutcome: WatchCommandOutcome?
  private(set) var lastCommandEvent: WatchCommandOutcome.Event?

  /// A position-only snapshot rewrites the cache no more often than this; anything else at once.
  static let positionOnlyPersistInterval: TimeInterval = 30

  private struct PersistenceFingerprint: Equatable {
    struct Row: Equatable {
      let id: String
      let selection: WatchSelection
      let section: WatchCatalogueSection
      let title: String
      let subtitle: String?
      let durationSeconds: Double?
      let isCurrentPlayback: Bool
      let capabilities: WatchSelectionCapabilities
      let artworkRevision: String?
    }
    let expectedAccountStamp: WatchAccountStamp?
    let accountStamp: WatchAccountStamp?
    let authenticatedAccountStamp: WatchAccountStamp?
    let playbackState: WatchPlaybackState?
    let playbackRate: Double?
    let skipBackwardSeconds: Int?
    let skipForwardSeconds: Int?
    let playbackRatePresets: [Double]?
    let followedPodcastsEnabled: Bool?
    let rows: [Row]
  }

  private var lastPersistedFingerprint: PersistenceFingerprint?
  private var lastPersistedAt: Date?

  private let store: WatchProtectedFileStore
  private let session: WCSession
  private var pendingRequest: CompanionRequest?
  private var pendingBrowseRequestID: UUID?
  private var pendingBrowseRequest: CompanionRequest?

  init(
    session: WCSession = .default,
    store: WatchProtectedFileStore = .production
  ) {
    self.session = session
    self.store = store
    self.phoneIsReachable = session.activationState == .activated && session.isReachable
    let read = store.read(key: Self.cacheKey) {
      try WatchWireCodec.decode(WatchCatalogueCache.self, from: $0)
    }
    cache = read.value ?? (try! WatchCatalogueCache())
    // Only bytes that were read and failed to decode are discarded; an unreadable file stays until
    // the phone's next push replaces it, since the phone owns the catalogue and can re-send it.
    if case .undecodable = read { try? store.clear(key: Self.cacheKey) }
  }

  /// Sign-out removes the saved titles from the Watch. What is in memory stays, since the phone's
  /// own catalogue is unaffected by the Watch disconnecting; the phone's next push saves it again.
  func clearCache() {
    try? store.clear(key: Self.cacheKey)
    lastPersistedFingerprint = nil
    lastPersistedAt = nil
  }

  isolated deinit {
    pendingRequest?.cancel()
    pendingBrowseRequest?.cancel()
  }

  var snapshot: WatchCatalogueSnapshot? { cache.snapshot }
  /// Tracked rather than read live, so the Now Playing projection re-renders when it changes.
  /// The background delegate reports both directions.
  private(set) var phoneIsReachable: Bool
  /// The last command failed to reach the phone. Cleared by the next reply or a regained reach.
  /// One failed command says little about the next: the latch lapses on its own, because an
  /// idle phone sends nothing that would clear it.
  private(set) var lastCommandUnreachable = false {
    didSet {
      unreachableLapse?.cancel()
      guard lastCommandUnreachable else { return }
      unreachableLapse = Task { [weak self] in
        try? await Task.sleep(for: .seconds(10))
        guard !Task.isCancelled else { return }
        self?.lastCommandUnreachable = false
      }
    }
  }
  @ObservationIgnored private var unreachableLapse: Task<Void, Never>?
  /// Whether remote transport can reach the phone now. Snapshot age plays no part.
  var phoneCanBeReached: Bool { phoneIsReachable && !lastCommandUnreachable }

  /// The phone reports playing a current title. A stale `playing` reads as paused.
  var phoneReportsPlaying: Bool {
    currentItem != nil && WatchNowPlayingProjection.phoneState(snapshot, isStale: snapshotIsStale) == .playing
  }

  var currentItem: WatchCatalogueItem? {
    WatchNowPlayingProjection.phonePlayerItem(snapshot: snapshot)
  }

  func reachabilityChanged(_ reachable: Bool) {
    phoneIsReachable = reachable
    if reachable { lastCommandUnreachable = false }
  }

  var snapshotAge: TimeInterval? {
    guard let generatedAt = cache.snapshot?.generatedAt else { return nil }
    return max(0, Date().timeIntervalSince(generatedAt))
  }

  var snapshotIsStale: Bool {
    (snapshotAge ?? 0) > 5 * 60
  }

  func acceptLiveApplicationContext(_ context: [String: Any]) {
    guard !context.isEmpty else { return }
    guard let data = context[Self.transportKey] as? Data else {
      lastOutcome = .unresolved
      return
    }
    acceptLiveSnapshot(data)
  }

  func consumeReceivedApplicationContext(_ context: [String: Any]) {
    acceptLiveApplicationContext(context)
  }

  func receiveLivePayload(_ data: Data?, malformed: Bool) {
    guard let data else {
      if malformed { lastOutcome = .unresolved }
      return
    }
    acceptLiveSnapshot(data)
  }

  private func acceptLiveSnapshot(_ data: Data) {
    guard let snapshot = try? WatchWireCodec.decode(WatchCatalogueSnapshot.self, from: data) else {
      lastOutcome = .unresolved
      return
    }

    let update: WatchCatalogueCacheUpdate
    if let incoming = snapshot.accountStamp,
      let expected = cache.expectedAccountStamp,
      incoming != expected
    {
      // A live application context is authoritative for a coalesced logout/login. Erase old
      // rows before accepting the newly stamped account so they cannot flash on the Watch.
      update = cache.resetAndApplyAuthoritative(snapshot)
    } else if snapshot.accountStamp != nil, cache.expectedAccountStamp == nil {
      update = cache.resetAndApplyAuthoritative(snapshot)
    } else {
      update = cache.applying(snapshot)
    }

    switch update {
    case .accepted(let next), .cleared(let next):
      if next.expectedAccountStamp != cache.expectedAccountStamp {
        cancelPendingCommand()
        cancelPendingBrowse()
      }
      cache = next
      lastCommandUnreachable = false
      persistUnlessPositionOnly(next)
      if next.snapshot == nil {
        cancelPendingCommand()
        cancelPendingBrowse()
      }
    case .rejected:
      // A duplicate or stale snapshot is a normal race, not a failure to report.
      break
    }
  }

  func send(
    selection: WatchSelection,
    action: WatchCommandAction = .play,
    value: Double? = nil
  ) async -> WatchCommandOutcome {
    switch admission(for: selection, action: action, value: value) {
    case .refused(let outcome): return outcome
    case .admitted(let stamp, let command): return await transmit(command, stamp: stamp)
    }
  }

  private enum CommandAdmission {
    case refused(WatchCommandOutcome)
    case admitted(stamp: WatchAccountStamp, command: WatchCommand)
  }

  /// The refusals here publish their outcome and leave no pending state. Only a command that gets
  /// as far as the transport can leave a pending marker behind.
  private func admission(
    for selection: WatchSelection, action: WatchCommandAction, value: Double?
  ) -> CommandAdmission {
    guard pendingCommandID == nil else {
      publishCommandOutcome(.busy)
      return .refused(.busy)
    }
    guard let stamp = cache.expectedAccountStamp, cache.snapshot != nil else {
      publishCommandOutcome(.phoneUnavailable)
      return .refused(.phoneUnavailable)
    }
    guard session.isReachable else {
      publishCommandOutcome(.phoneUnavailable)
      return .refused(.phoneUnavailable)
    }
    do {
      let command = try WatchCommand(
        accountStamp: stamp, selection: selection, action: action, value: value)
      return .admitted(stamp: stamp, command: command)
    } catch {
      publishCommandOutcome(.rejected(.invalidCommand))
      return .refused(.rejected(.invalidCommand))
    }
  }

  /// A stale fence after the transport leaves the pending markers set and publishes no outcome:
  /// the reply arrived, but not for this command's account or id.
  private func transmit(_ command: WatchCommand, stamp: WatchAccountStamp) async -> WatchCommandOutcome {
    pendingCommandID = command.id
    lastOutcome = nil
    let request = CompanionRequest()
    pendingRequest = request

    guard let payload = encodedPayload(for: command, request: request) else {
      return .rejected(.invalidCommand)
    }

    let transport = await request.send(
      payload, key: Self.transportKey, replyKey: Self.transportKey,
      limit: WatchProtocolVersion.maxCommandBytes, timeout: Self.commandTimeout, in: session)
    guard pendingCommandID == command.id, cache.expectedAccountStamp == stamp else {
      return .unresolved
    }
    pendingRequest = nil
    pendingCommandID = nil

    let outcome = interpret(transport, for: command)
    publishCommandOutcome(outcome)
    return outcome
  }

  private func encodedPayload(for command: WatchCommand, request: CompanionRequest) -> Data? {
    do {
      return try WatchWireCodec.encode(command)
    } catch {
      request.cancel()
      pendingRequest = nil
      pendingCommandID = nil
      publishCommandOutcome(.rejected(.invalidCommand))
      return nil
    }
  }

  private func interpret(
    _ transport: CompanionRequest.Outcome, for command: WatchCommand
  ) -> WatchCommandOutcome {
    let outcome: WatchCommandOutcome
    switch transport {
    case .reply(let data):
      guard let reply = try? WatchWireCodec.decode(WatchReply.self, from: data),
        reply.matches(command)
      else {
        outcome = .unresolved
        break
      }
      lastCommandUnreachable = false
      if reply.status == .accepted {
        // Accepted means the command reached the iPhone's account bridge; it does not mean that
        // audio activation or PlayerCore `.playing` has occurred.
        outcome = .sent
      } else if reply.errorCode == .ambiguousTransport {
        outcome = .unresolved
      } else {
        outcome = .rejected(reply.errorCode ?? .rejected)
      }
    case .failed, .timedOut:
      // The operation may have begun on the phone. Never retry with a new id or authorize Watch
      // fallback after an uncertain delivery.
      lastCommandUnreachable = true
      outcome = .unresolved
    }
    return outcome
  }

  private func publishCommandOutcome(_ outcome: WatchCommandOutcome) {
    lastOutcome = outcome
    lastCommandEvent = WatchCommandOutcome.Event(outcome: outcome)
  }

  /// Optional thumbnails have no command outcome or playback fallback side effects.
  func artwork(_ request: WatchArtworkRequest) async -> Data? {
    guard session.isReachable, cache.expectedAccountStamp == request.accountStamp,
      let payload = try? WatchWireCodec.encode(request)
    else { return nil }
    let transport = await CompanionRequest(cancelsOnTaskCancellation: true).send(
      payload, key: WatchTransportKey.artworkRequest, replyKey: WatchTransportKey.artworkReply,
      limit: WatchArtworkReply.maxWireBytes, timeout: .seconds(8), in: session)
    guard !Task.isCancelled, cache.expectedAccountStamp == request.accountStamp,
      case .reply(let data) = transport,
      let reply = try? WatchWireCodec.decode(WatchArtworkReply.self, from: data), reply.matches(request)
    else { return nil }
    return reply.imageData
  }

  /// Requests a complete phone-owned browse page. Browse delivery is independently fenced from
  /// playback commands: a timeout is unresolved and never authorizes Watch-local fallback.
  func browse(_ request: WatchBrowseRequest) async -> WatchBrowseResult {
    guard pendingBrowseRequestID == nil else {
      let error = try! WatchBrowseError(
        code: .retryable, message: "Another browse request is still loading.", retryable: true, retryAfterSeconds: 1)
      return .failure(error)
    }
    guard let stamp = cache.expectedAccountStamp, cache.snapshot != nil, request.accountStamp == stamp else {
      let error = try! WatchBrowseError(
        code: .accountUnavailable, message: "The phone account is unavailable.", retryable: false)
      return .failure(error)
    }
    guard session.isReachable else {
      let error = try! WatchBrowseError(
        code: .phoneUnavailable, message: "Connect to the phone to browse podcasts.", retryable: true,
        retryAfterSeconds: 2)
      return .failure(error)
    }
    guard let payload = try? WatchWireCodec.encode(request) else {
      let error = try! WatchBrowseError(
        code: .invalidRequest, message: "This browse request is invalid.", retryable: false)
      return .failure(error)
    }
    let id = request.id
    pendingBrowseRequestID = id
    let pending = CompanionRequest()
    pendingBrowseRequest = pending

    let result = await pending.send(
      payload, key: WatchBrowseTransportKey.request, replyKey: WatchBrowseTransportKey.reply,
      limit: WatchBrowseLimits.maxWireBytes, timeout: Self.browseTimeout, in: session)
    guard pendingBrowseRequestID == id, cache.expectedAccountStamp == stamp else {
      return .failure(
        try! WatchBrowseError(
          code: .accountUnavailable, message: "The phone account changed. Open Podcasts again.", retryable: false))
    }
    pendingBrowseRequest = nil
    pendingBrowseRequestID = nil
    switch result {
    case .reply(let data):
      guard let reply = try? WatchWireCodec.decode(WatchBrowseReply.self, from: data), reply.requestID == id,
        reply.accountStamp == stamp
      else {
        let error = try! WatchBrowseError(
          code: .retryable, message: "The phone returned an invalid browse response. Try again.", retryable: true,
          retryAfterSeconds: 2)
        return .failure(error)
      }
      if let page = reply.page, reply.status == .accepted { return .page(page) }
      if let error = reply.error { return .failure(error) }
      return .failure(
        try! WatchBrowseError(
          code: .retryable, message: "The phone could not load podcasts. Try again.", retryable: true,
          retryAfterSeconds: 2))
    case .failed, .timedOut:
      return .failure(
        try! WatchBrowseError(
          code: .phoneUnavailable, message: "The phone did not answer. Try again when it is nearby.", retryable: true,
          retryAfterSeconds: 2))
    }
  }

  func browse(
    scope: WatchBrowseScope, source: WatchBrowseSource? = nil, page: Int = 0,
    pageSize: Int = WatchBrowseLimits.maxPageSize,
    episodeSort: WatchBrowseEpisodeSort = .newest, played: WatchBrowsePlayedFilter = .all,
    generation: UInt64? = nil
  ) async -> WatchBrowseResult {
    guard let stamp = cache.expectedAccountStamp,
      let request = try? WatchBrowseRequest(
        accountStamp: stamp, scope: scope, page: page, pageSize: pageSize,
        episodeSort: episodeSort, played: played, generation: generation, source: source)
    else {
      return .failure(
        try! WatchBrowseError(code: .invalidRequest, message: "This browse request is invalid.", retryable: false))
    }
    return await browse(request)
  }

  func cancelPendingCommand() {
    lastOutcome = nil
    pendingRequest?.cancel()
    pendingRequest = nil
    pendingCommandID = nil
  }

  private func cancelPendingBrowse() {
    pendingBrowseRequest?.cancel()
    pendingBrowseRequest = nil
    pendingBrowseRequestID = nil
  }

  /// The phone republishes while audio plays, changing only the playhead; rewriting the whole
  /// cache for each would cost battery for a position the next snapshot replaces.
  private func persistUnlessPositionOnly(_ next: WatchCatalogueCache) {
    let snapshot = next.snapshot
    let fingerprint = PersistenceFingerprint(
      expectedAccountStamp: next.expectedAccountStamp, accountStamp: snapshot?.accountStamp,
      authenticatedAccountStamp: snapshot?.authenticatedAccountStamp, playbackState: snapshot?.playbackState,
      playbackRate: snapshot?.playbackRate, skipBackwardSeconds: snapshot?.skipBackwardSeconds,
      skipForwardSeconds: snapshot?.skipForwardSeconds, playbackRatePresets: snapshot?.playbackRatePresets,
      followedPodcastsEnabled: snapshot?.followedPodcastsEnabled,
      rows: (snapshot?.items ?? []).map {
        PersistenceFingerprint.Row(
          id: $0.id, selection: $0.selection, section: $0.section, title: $0.title, subtitle: $0.subtitle,
          durationSeconds: $0.durationSeconds, isCurrentPlayback: $0.isCurrentPlayback,
          capabilities: $0.capabilities, artworkRevision: $0.artworkRevision)
      })
    let now = Date()
    if fingerprint == lastPersistedFingerprint, let lastPersistedAt,
      now.timeIntervalSince(lastPersistedAt) < Self.positionOnlyPersistInterval
    {
      return
    }
    lastPersistedFingerprint = fingerprint
    lastPersistedAt = now
    persist()
  }

  private func persist() {
    guard let data = try? WatchWireCodec.encode(cache) else {
      try? store.clear(key: Self.cacheKey)
      return
    }
    do {
      try store.save(data, key: Self.cacheKey)
    } catch {
      // Before first unlock the write fails; the next push persists again.
      lastPersistedFingerprint = nil
    }
  }
}
