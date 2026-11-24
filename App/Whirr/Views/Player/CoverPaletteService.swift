import ABSApi
import DesignSystem
import Foundation
import Observation
import Persistence
import SyncEngine

/// The one owner of every cover's colour. A request tries memory, the row, cached bytes, then (if
/// visible) the display fetch, then extraction under the shared admission, then the row write; one
/// derivation per identity is shared by all callers. Unanswered requests follow one batched row
/// observation, so a colour another writer saves reaches every surface.
@MainActor
@Observable
final class CoverPaletteService {
  /// One identity's shared derivation.
  private struct InFlight {
    var task: Task<CoverPalette?, Never>
    /// Tells this derivation from a later one for the same identity, after a cancellation.
    let token: UUID
    var subscribers: Set<UUID>
    /// Visible once any visible request has joined: it may then wait for the display fetch and
    /// extracts ahead of background work.
    var requestClass: CoverPaletteWriter.RequestClass
    /// The latest visible request's bytes, else the first request's.
    var bytes: CoverBytes
    /// False once any request that is not coverable has joined, which un-parks it.
    var isCoverable: Bool
    /// A visible surface's derivation is unstructured and outlives its caller: the mini-player's
    /// task is cancelled when the expanded player covers it, and abandoning the derivation then
    /// would leave both neutral. Home's and background work end when their last caller leaves.
    var outlivesCallers: Bool
    /// False while only background writers have asked: their answer goes to the row, and to
    /// memory only for an identity a surface is following.
    var fillsMemory: Bool
  }

  private enum Attempt {
    case answered(CoverPalette)
    case unanswered
    /// The shell was covered at a checkpoint. Start again from memory and the row, because another
    /// writer may have saved the answer meanwhile.
    case parked
  }

  private enum Extracted {
    case samples(CoverPaletteSamples)
    case failed
    case parked
  }

  private struct WeakObserver {
    weak var observer: (any CoverPaletteServiceObserver)?
  }

  /// Level-triggered by the shell from every covering presentation. Covered, coverable work
  /// starts nothing new, and an extraction already inside Core Image finishes but publishes only
  /// once the cover lifts.
  private(set) var isCovered = false

  /// The scope of a card that names no artwork source of its own: the account's server.
  let accountScope: ArtworkAccountScope

  /// Observed through its own registrar, so a view reading a palette in `body` follows it.
  @ObservationIgnored private let memory: CoverPaletteMemory
  @ObservationIgnored private var inFlight: [CoverPaletteIdentity: InFlight] = [:]
  /// Bumped by every clear. A read that straddles one is discarded.
  @ObservationIgnored private var generation: UInt64 = 0
  /// Parked derivations and covered-shell waiters. A nil identity waits for the cover alone.
  @ObservationIgnored private var parked:
    [UUID: (identity: CoverPaletteIdentity?, continuation: CheckedContinuation<Void, Never>)] = [:]
  @ObservationIgnored private var paletteWaiters:
    [UUID: (identity: CoverPaletteIdentity, continuation: CheckedContinuation<Void, Never>)] = [:]
  @ObservationIgnored private var subscriberWaiters:
    [(identity: CoverPaletteIdentity, minimum: Int, continuation: CheckedContinuation<Void, Never>)] =
      []
  /// Identities a request left without a palette, followed until each is answered or the
  /// service is cleared.
  @ObservationIgnored private let follower: CoverPaletteFollower
  /// Answers for observers, held while the shell is covered.
  @ObservationIgnored private var pendingAnswers: [CoverPaletteIdentity: CoverPalette] = [:]
  @ObservationIgnored private var observers: [WeakObserver] = []

  @ObservationIgnored private let extraction: Extraction
  @ObservationIgnored private let admission: CoverDecodeAdmission
  @ObservationIgnored private let recordStore: (any CoverPaletteRecordStoring)?
  @ObservationIgnored let artwork: Artwork?

  init(
    accountScope: ArtworkAccountScope = ArtworkAccountScope("artwork:none"),
    artwork: Artwork? = nil,
    extraction: Extraction = .production,
    admission: CoverDecodeAdmission = CoverDecodeAdmission(maximumConcurrent: 1),
    recordStore: (any CoverPaletteRecordStoring)? = nil,
    cacheLimit: Int = 256
  ) {
    self.accountScope = accountScope
    self.artwork = artwork
    self.extraction = extraction
    self.admission = admission
    self.recordStore = recordStore
    memory = CoverPaletteMemory(limit: cacheLimit)
    follower = CoverPaletteFollower(recordStore: recordStore)
    follower.onRecords = { [weak self] records in self?.answer(from: records) }
  }

  /// The shell's service: cards read cover bytes through `coverClient` and join its display fetch.
  convenience init(
    recordStore: any CoverPaletteRecordStoring,
    coverClient: any ArtworkServing,
    pipeline: ArtworkImagePipeline = .shared,
    extraction: Extraction = .production,
    admission: CoverDecodeAdmission = CoverDecodeAdmission(maximumConcurrent: 1)
  ) {
    self.init(
      accountScope: coverClient.defaultSource?.cacheScope ?? ArtworkAccountScope("artwork:none"),
      artwork: Artwork(coverClient: coverClient, pipeline: pipeline),
      extraction: extraction, admission: admission, recordStore: recordStore)
  }

  // MARK: - Reading

  /// The resolved palette for `identity`, from memory only, so a view can read it in `body`.
  func palette(for identity: CoverPaletteIdentity) -> CoverPalette? {
    memory.palette(for: identity)
  }

  /// The palette for the identity `itemID`'s player or detail surfaces last asked for. One
  /// surface reads another's answer while its own identity is still provisional: the expanded
  /// player opens on the mini-player's colour while its item loads, rather than on neutral.
  func palette(forItem itemID: String) -> CoverPalette? {
    memory.palette(forItem: itemID)
  }

  /// Memory, then the saved rows in one read. Never waits for bytes or extracts, so a page's first
  /// paint can ask. A miss is absent.
  func cachedPalettes(
    _ identities: [CoverPaletteIdentity]
  ) async -> [CoverPaletteIdentity: CoverPalette] {
    var result: [CoverPaletteIdentity: CoverPalette] = [:]
    var missing: [CoverPaletteIdentity] = []
    for identity in Self.unique(identities) {
      if let palette = palette(for: identity) {
        result[identity] = palette
      } else {
        missing.append(identity)
      }
    }
    guard missing.isEmpty == false, let recordStore, Task.isCancelled == false else { return result }
    let generation = generation
    let rowIDs = Array(Set(missing.map(\.rowID)))
    let records = (try? await recordStore.fetch(itemIds: rowIDs)) ?? []
    // Rows read before a clear describe artwork the clear discarded.
    guard generation == self.generation, Task.isCancelled == false else { return [:] }
    let byRowID = Dictionary(records.map { ($0.itemId, $0) }, uniquingKeysWith: { first, _ in first })
    for identity in missing {
      guard let record = byRowID[identity.rowID], identity.isAnswered(by: record),
        let palette = CoverPaletteWriter.palette(from: record)
      else { continue }
      publish(palette, for: identity)
      result[identity] = palette
    }
    return result
  }

  /// The identities whose saved row does not answer them, in order: missing, written for another
  /// identity, or from before the page-evidence columns. Rows only; memory is not consulted and
  /// nothing is built. A failed read counts every identity as unsaved.
  func unsaved(_ identities: [CoverPaletteIdentity]) async -> [CoverPaletteIdentity] {
    guard let recordStore, identities.isEmpty == false else { return identities }
    let records = (try? await recordStore.fetch(itemIds: Array(Set(identities.map(\.rowID))))) ?? []
    let byRowID = Dictionary(records.map { ($0.itemId, $0) }, uniquingKeysWith: { first, _ in first })
    return identities.filter { $0.isAnswered(by: byRowID[$0.rowID]) == false }
  }

  /// A background writer's ask (`CoverPaletteBackfill`, `FollowedShowArtworkWarmPass`): bring the
  /// row for the cover `key` draws up to date from cached bytes. It shares any surface's
  /// derivation for the same cover, but it is not followed, and it fills memory only for an
  /// identity a surface is following, so a pass over the library neither observes every item nor
  /// evicts the palettes on screen.
  func save(_ key: ArtworkKey) async {
    let bytes = artwork?.bytes(displayed: key) ?? CoverBytes(cached: { nil }, awaitArrival: {})
    _ = await request([
      CoverPaletteRequest(
        identity: CoverPaletteIdentity(key), bytes: bytes, requestClass: .background,
        isSaveOnly: true)
    ])
  }

  /// A palette that is neither saved nor kept, for a cover no row may describe: the directory
  /// page's preview of a feed not yet followed (ADR 0004). Queues on the shared admission like any
  /// visible request.
  func unsavedPalette(from data: Data) async -> CoverPalette? {
    let samples = await CoverPaletteWriter.samples(
      from: data, requestClass: .visible, admission: admission, extract: extraction.samples)
    return samples.map(CoverAmbientPalette.palette(from:))
  }

  // MARK: - Requests

  /// A player's or item detail's ask: shows `identity` for its item (`palette(forItem:)`), then
  /// resolves it as `request` does.
  func show(_ identity: CoverPaletteIdentity, bytes: CoverBytes) async {
    show(identity)
    _ = await request([CoverPaletteRequest(identity: identity, bytes: bytes)])
  }

  /// Resolves `requests` and returns what it resolved. Everything it did not resolve is followed,
  /// so a later answer reaches memory, and observers, without the caller asking again.
  func request(_ requests: [CoverPaletteRequest]) async -> [CoverPaletteIdentity: CoverPalette] {
    guard Task.isCancelled == false else { return [:] }
    let subscriberID = UUID()
    let generation = generation
    var resolved: [CoverPaletteIdentity: CoverPalette] = [:]
    var missedWhileCovered: [CoverPaletteIdentity] = []
    var tasks: [(CoverPaletteIdentity, Task<CoverPalette?, Never>)] = []
    var savesOnly: Set<CoverPaletteIdentity> = []

    for request in Self.unique(requests) {
      let identity = request.identity
      if let palette = palette(for: identity) {
        resolved[identity] = palette
        continue
      }
      // A covered visible card is answered from memory or its row, or left neutral: it neither
      // waits nor starts work.
      if isCovered, request.isCoverable, request.requestClass == .visible {
        if let palette = await savedPalette(for: identity), generation == self.generation,
          Task.isCancelled == false
        {
          publish(palette, for: identity)
          resolved[identity] = palette
        } else {
          missedWhileCovered.append(identity)
        }
        continue
      }
      if request.isSaveOnly { savesOnly.insert(identity) }
      tasks.append((identity, subscribe(subscriberID, to: request)))
    }

    let subscribed = tasks.map(\.0)
    let results = await withTaskCancellationHandler {
      var results = resolved
      for (identity, task) in tasks {
        if let palette = await task.value ?? memory.peek(identity) {
          results[identity] = palette
        }
      }
      return results
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.leave(subscriberID, identities: subscribed)
      }
    }

    leave(subscriberID, identities: subscribed)
    if Task.isCancelled == false, generation == self.generation {
      follow(
        (subscribed + missedWhileCovered).filter { results[$0] == nil && savesOnly.contains($0) == false })
    }
    return results
  }

  /// The first-frame path before a navigation: a saved row is awaited (one local read, and losing
  /// that race flashes neutral then accent), but extraction runs only from bytes already on disk
  /// and is held to `deadline`.
  func prepare(_ request: CoverPaletteRequest, deadline: Duration = .milliseconds(16)) async {
    let identity = request.identity
    show(identity)
    guard palette(for: identity) == nil else { return }
    let generation = generation
    if let palette = await savedPalette(for: identity) {
      guard generation == self.generation, Task.isCancelled == false else { return }
      publish(palette, for: identity)
      return
    }
    guard memory.contains(identity) == false, identity.isProvisional == false,
      await request.bytes.cached() != nil
    else { return }
    let cachedOnly = CoverPaletteRequest(
      identity: identity, bytes: CoverBytes(cached: request.bytes.cached, awaitArrival: {}),
      requestClass: .visible, isCoverable: false)
    let (outcomes, report) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    Task { [weak self, cachedOnly] in
      _ = await self?.request([cachedOnly])
      report.yield(())
    }
    let timeout = Task {
      try? await Task.sleep(for: deadline)
      guard Task.isCancelled == false else { return }
      report.yield(())
    }
    var outcome = outcomes.makeAsyncIterator()
    await withTaskCancellationHandler {
      _ = await outcome.next()
    } onCancel: {
      report.yield(())
    }
    timeout.cancel()
  }

  /// Returns once `identity` has a palette, the caller is cancelled, or the service is cleared,
  /// following its row meanwhile. Returns at once when a palette is already resolved.
  func waitForPalette(_ identity: CoverPaletteIdentity) async {
    guard memory.contains(identity) == false, follower.canFollow, Task.isCancelled == false else {
      return
    }
    follow([identity])
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard memory.contains(identity) == false, Task.isCancelled == false else {
          continuation.resume()
          return
        }
        paletteWaiters[id] = (identity, continuation)
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.paletteWaiters.removeValue(forKey: id)?.continuation.resume()
      }
    }
  }

  // MARK: - Lifecycle

  /// Protects `identity` from eviction, replacing any earlier pin: the playing cover keeps its
  /// colour through browsing, and the pin moves with its revision.
  func pin(_ identity: CoverPaletteIdentity?) {
    memory.pin(identity)
  }

  /// Pins whichever identity `itemID`'s surfaces ask for, now and as it changes: the active
  /// player's item, so a replaced cover's new colour is the one kept.
  func pin(itemID: String) {
    memory.pin(itemID: itemID)
  }

  /// Makes `identity` the one `palette(forItem:)` reads for its item. A player or detail surface
  /// calls this as it asks; Home and the background writers never do.
  func show(_ identity: CoverPaletteIdentity) {
    memory.show(identity)
  }

  /// Cancels `itemID`'s in-flight work when its artwork source changes, so nothing started under
  /// the old source lands afterwards. Its resolved palettes stay: a different source is a
  /// different identity whenever its scope differs.
  func sourceChanged(for itemID: String) {
    for (identity, entry) in inFlight where identity.itemID == itemID {
      entry.task.cancel()
      inFlight[identity] = nil
      resumeParked(identity)
      resumeSubscriberWaiters(for: identity)
    }
  }

  /// Sets the covered level. Lifting it resumes parked work and delivers held notices.
  func setCovered(_ covered: Bool) {
    guard isCovered != covered else { return }
    isCovered = covered
    guard covered == false else { return }
    let waiters = parked.values.map(\.continuation)
    parked.removeAll()
    for waiter in waiters { waiter.resume() }
    deliverAnswers()
  }

  /// Waits only for the cover to lift, or for cancellation.
  func waitUntilUncovered() async {
    guard isCovered, Task.isCancelled == false else { return }
    await wait(parkedAs: nil) { [weak self] in self?.isCovered == true }
  }

  /// Drops every palette, cancels work and stops following, so nothing from before the clear
  /// reappears. Cancelled derivations are not drained: a joined display fetch runs regardless of
  /// the joiner's cancellation, and waiting would hold the Settings clear open for a live
  /// transfer. Every publication is behind a liveness check, so a straggler publishes nothing.
  func clear() {
    stopWork()
    memory.removeAll()
    observers.removeAll { $0.observer == nil }
    for observer in observers { observer.observer?.paletteServiceDidClear() }
  }

  /// The artwork clear, after the cover bytes are gone. Work stops first, so nothing read from the
  /// cleared bytes writes a row once the rows are removed. Memory goes last: clearing it makes
  /// every live screen ask again, and that must not find a row this clear is still removing.
  func clearCachedArtwork() async {
    stopWork()
    try? await recordStore?.removeAll()
    clear()
  }

  /// Cancels work and stops following without touching memory. A derivation that outlived its
  /// cancellation finds its generation gone and writes nothing.
  private func stopWork() {
    generation &+= 1
    for entry in inFlight.values { entry.task.cancel() }
    inFlight.removeAll()
    follower.stop()
    pendingAnswers.removeAll()
    let waiters =
      parked.values.map(\.continuation) + paletteWaiters.values.map(\.continuation)
      + subscriberWaiters.map(\.continuation)
    parked.removeAll()
    paletteWaiters.removeAll()
    subscriberWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  func addObserver(_ observer: any CoverPaletteServiceObserver) {
    observers.removeAll { $0.observer == nil }
    observers.append(WeakObserver(observer: observer))
  }

  /// Test seam: waits until `identity`'s derivation has at least `minimum` callers.
  func waitForSubscriberCount(_ identity: CoverPaletteIdentity, minimum: Int) async {
    guard (inFlight[identity]?.subscribers.count ?? 0) < minimum else { return }
    await withCheckedContinuation { continuation in
      subscriberWaiters.append((identity, minimum, continuation))
    }
  }

  // MARK: - Derivation

  private func subscribe(
    _ subscriberID: UUID, to request: CoverPaletteRequest
  ) -> Task<CoverPalette?, Never> {
    let identity = request.identity
    let outlivesCallers = request.requestClass == .visible && request.isCoverable == false
    if var entry = inFlight[identity] {
      entry.subscribers.insert(subscriberID)
      if request.requestClass == .visible {
        entry.requestClass = .visible
        entry.bytes = request.bytes
      }
      entry.isCoverable = entry.isCoverable && request.isCoverable
      entry.outlivesCallers = entry.outlivesCallers || outlivesCallers
      entry.fillsMemory = entry.fillsMemory || request.isSaveOnly == false
      inFlight[identity] = entry
      // A visible surface opened over parked work for its own cover takes that work over.
      if entry.isCoverable == false { resumeParked(identity) }
      resumeSubscriberWaiters(for: identity)
      return entry.task
    }
    let token = UUID()
    let task = Task { [weak self] () -> CoverPalette? in
      await self?.derive(identity, token: token)
    }
    inFlight[identity] = InFlight(
      task: task, token: token, subscribers: [subscriberID], requestClass: request.requestClass,
      bytes: request.bytes, isCoverable: request.isCoverable, outlivesCallers: outlivesCallers,
      fillsMemory: request.isSaveOnly == false)
    resumeSubscriberWaiters(for: identity)
    return task
  }

  private func leave(_ subscriberID: UUID, identities: [CoverPaletteIdentity]) {
    for identity in identities {
      guard var entry = inFlight[identity], entry.subscribers.remove(subscriberID) != nil else {
        continue
      }
      if entry.subscribers.isEmpty, entry.outlivesCallers == false {
        entry.task.cancel()
        inFlight[identity] = nil
        resumeParked(identity)
      } else {
        inFlight[identity] = entry
      }
      resumeSubscriberWaiters(for: identity)
    }
  }

  private func derive(_ identity: CoverPaletteIdentity, token: UUID) async -> CoverPalette? {
    defer {
      if inFlight[identity]?.token == token { inFlight[identity] = nil }
    }
    while isLive(identity, token) {
      switch await attempt(identity, token: token) {
      case .answered(let palette): return palette
      case .unanswered: return nil
      case .parked: continue
      }
    }
    return nil
  }

  private func attempt(_ identity: CoverPaletteIdentity, token: UUID) async -> Attempt {
    if await park(identity, token: token) { return .parked }
    if let palette = memory.peek(identity) { return .answered(palette) }

    if let palette = await savedPalette(for: identity) {
      // Covered while reading: publish nothing until it lifts, then look again.
      if await park(identity, token: token) { return .parked }
      guard isLive(identity, token) else { return .unanswered }
      if isWanted(identity) { publish(palette, for: identity) }
      return .answered(palette)
    }
    guard identity.isProvisional == false, let entry = inFlight[identity], entry.token == token
    else { return .unanswered }

    var data = await entry.bytes.cached()
    if data == nil {
      guard let entry = inFlight[identity], entry.token == token, entry.requestClass == .visible
      else { return .unanswered }
      if await park(identity, token: token) { return .parked }
      guard isLive(identity, token) else { return .unanswered }
      let bytes = inFlight[identity]?.bytes ?? entry.bytes
      await bytes.awaitArrival()
      guard isLive(identity, token) else { return .unanswered }
      data = await bytes.cached()
    }
    guard let data, isLive(identity, token) else { return .unanswered }

    let samples: CoverPaletteSamples
    switch await extract(data, identity: identity, token: token) {
    case .samples(let extracted): samples = extracted
    case .failed: return .unanswered
    case .parked: return .parked
    }
    let palette = CoverAmbientPalette.palette(from: samples)
    // Extraction may have finished just as the shell was covered: hold the result until it lifts.
    _ = await park(identity, token: token)
    guard isLive(identity, token) else { return .unanswered }
    // Another writer saved this cover meanwhile; its answer stands and is not written again.
    if let existing = memory.peek(identity) { return .answered(existing) }
    if isWanted(identity) { publish(palette, for: identity) }
    if let recordStore {
      try? await recordStore.upsert(
        CoverPaletteWriter.record(itemID: identity.rowID, identity: identity.recordKey, palette: palette))
    }
    return .answered(palette)
  }

  /// Extracts under the shared admission at the derivation's current class. The covered check sits
  /// right beside the Core Image call: the cover may have arrived while waiting for the permit, and
  /// no parked work may start after it.
  private func extract(
    _ data: Data, identity: CoverPaletteIdentity, token: UUID
  ) async -> Extracted {
    let priority = (inFlight[identity]?.requestClass ?? .background).priority
    do {
      try await admission.acquire(priority: priority)
    } catch {
      return .failed
    }
    if needsParking(identity, token: token) {
      await admission.release(priority: priority)
      return .parked
    }
    guard isLive(identity, token) else {
      await admission.release(priority: priority)
      return .failed
    }
    let samples = await extraction.samples(data)
    await admission.release(priority: priority)
    return samples.map(Extracted.samples) ?? .failed
  }

  /// Whether an answer belongs in memory: some surface asked, or is following the identity.
  private func isWanted(_ identity: CoverPaletteIdentity) -> Bool {
    inFlight[identity]?.fillsMemory == true || follower.contains(identity)
  }

  private func isLive(_ identity: CoverPaletteIdentity, _ token: UUID) -> Bool {
    Task.isCancelled == false && inFlight[identity]?.token == token
  }

  private func needsParking(_ identity: CoverPaletteIdentity, token: UUID) -> Bool {
    guard isCovered, let entry = inFlight[identity], entry.token == token else { return false }
    return entry.isCoverable
  }

  /// Waits while this derivation is coverable and the shell covered. Reports whether it waited.
  private func park(_ identity: CoverPaletteIdentity, token: UUID) async -> Bool {
    guard needsParking(identity, token: token), Task.isCancelled == false else { return false }
    await wait(parkedAs: identity) { [weak self] in
      self?.needsParking(identity, token: token) == true
    }
    return true
  }

  private func wait(
    parkedAs identity: CoverPaletteIdentity?, while condition: @escaping () -> Bool
  ) async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard condition(), Task.isCancelled == false else {
          continuation.resume()
          return
        }
        parked[id] = (identity, continuation)
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.parked.removeValue(forKey: id)?.continuation.resume()
      }
    }
  }

  private func resumeParked(_ identity: CoverPaletteIdentity) {
    let ids = parked.filter { $0.value.identity == identity }.map(\.key)
    for id in ids { parked.removeValue(forKey: id)?.continuation.resume() }
  }

  private func resumeSubscriberWaiters(for identity: CoverPaletteIdentity) {
    let count = inFlight[identity]?.subscribers.count ?? 0
    let ready = subscriberWaiters.filter { $0.identity == identity && count >= $0.minimum }
    subscriberWaiters.removeAll { $0.identity == identity && count >= $0.minimum }
    for waiter in ready { waiter.continuation.resume() }
  }

  // MARK: - Rows

  private func savedPalette(for identity: CoverPaletteIdentity) async -> CoverPalette? {
    guard let recordStore else { return nil }
    let record = (try? await recordStore.fetch(itemId: identity.rowID)) ?? nil
    guard identity.isAnswered(by: record), let record else { return nil }
    return CoverPaletteWriter.palette(from: record)
  }

  // MARK: - Publication and following

  /// Puts `palette` in memory and wakes everything waiting on `identity`. An answer for an
  /// identity a request left unanswered goes to observers, at once unless `deliver` is false
  /// because the caller is publishing a batch.
  private func publish(
    _ palette: CoverPalette, for identity: CoverPaletteIdentity, deliver: Bool = true
  ) {
    memory.insert(palette, for: identity)
    if follower.answered(identity) {
      pendingAnswers[identity] = palette
      if deliver { deliverAnswers() }
    }
    let ready = paletteWaiters.filter { $0.value.identity == identity }.map(\.key)
    for id in ready { paletteWaiters.removeValue(forKey: id)?.continuation.resume() }
  }

  private func deliverAnswers() {
    guard isCovered == false, pendingAnswers.isEmpty == false else { return }
    let answers = pendingAnswers
    pendingAnswers.removeAll()
    observers.removeAll { $0.observer == nil }
    for observer in observers { observer.observer?.paletteServiceDidAnswer(answers) }
  }

  /// Follows `identities`' rows until each is answered.
  private func follow(_ identities: [CoverPaletteIdentity]) {
    follower.follow(identities.filter { memory.contains($0) == false })
  }

  /// Adopts every unanswered identity `records` now answers. The observation is table-wide and
  /// item IDs are not account-scoped, so a row must still match the identity's scope, which
  /// `isAnswered` checks.
  private func answer(from records: [CoverPaletteRecord]) {
    let byRowID = Dictionary(records.map { ($0.itemId, $0) }, uniquingKeysWith: { first, _ in first })
    for identity in follower.unanswered where memory.contains(identity) == false {
      guard let record = byRowID[identity.rowID], identity.isAnswered(by: record),
        let palette = CoverPaletteWriter.palette(from: record)
      else { continue }
      publish(palette, for: identity, deliver: false)
    }
    deliverAnswers()
    follower.restart()
  }

  private static func unique(_ identities: [CoverPaletteIdentity]) -> [CoverPaletteIdentity] {
    var seen = Set<CoverPaletteIdentity>()
    return identities.filter { seen.insert($0).inserted }
  }

  private static func unique(_ requests: [CoverPaletteRequest]) -> [CoverPaletteRequest] {
    var seen = Set<CoverPaletteIdentity>()
    return requests.filter { seen.insert($0.identity).inserted }
  }

  isolated deinit {
    for entry in inFlight.values { entry.task.cancel() }
  }
}

/// The Settings artwork clear reaches the palettes through `clearCachedArtwork`. Declared beside
/// the class because a `Sendable` conformance must be in the type's own file.
extension CoverPaletteService: ArtworkCacheClearing {}
