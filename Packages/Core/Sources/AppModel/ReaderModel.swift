import Foundation
import Observation
import Persistence
import ReaderCore
import SyncEngine

/// The cross-device restore target owned by the persistence/sync composition.
public enum ReaderRestoreTarget: Sendable, Equatable {
  case position(ReadingPosition)
  case totalProgression(Double)
}

@MainActor
@Observable
public final class ReaderModel {
  public enum State: Sendable, Equatable {
    case idle
    case downloading(progress: Double)
    /// Parked, not failed, and not terminal: the reader keeps observing so a hold that clears
    /// (Wi-Fi arrives, the user resumes) opens the book without leaving the screen.
    case downloadHeld(reason: ReaderDownloadHold)
    case opening
    case reading
    case unavailable
    case drmProtected
    case recoverableError
    case unopenable
    case publicationServerFailure
  }

  private enum UnavailableReason: Sendable {
    case noEpubAdvertised
    case advertisedButUnavailable
    case ebookIdentityNotFetched
  }

  /// Why the reader is on `.recoverableError`. Mirrors `UnavailableReason`'s shape rather than
  /// splitting the state: the retry affordance is identical (after a server-side fix a rejected
  /// download is worth requesting again) and only the copy differs.
  private enum RecoverableErrorReason: Sendable {
    case downloadFailed
    case downloadRejected
  }

  /// Traced here rather than at each assignment so no branch can change state unseen. Labels
  /// ignore progress, so a ticking bar is one transition, not a hundred.
  public private(set) var state: State = .idle {
    didSet {
      let label = ReaderTraceLabel.label(for: state)
      if label != ReaderTraceLabel.label(for: oldValue) {
        ReaderTrace.emit("model", ["item": itemID, "value": label])
      }
      if state == .opening, oldValue != .opening {
        startOpeningIndicatorDelay()
      } else if state != .opening {
        cancelOpeningIndicator()
      }
    }
  }
  /// Whether the delayed opening spinner should be shown. The page cover remains immediate while
  /// this flag stays false during the short, normal open path.
  public private(set) var isOpeningIndicatorVisible = false
  /// Whether the reader's page surface belongs in the view hierarchy. True from `.opening` onward,
  /// before `.reading`.
  ///
  /// Readium completes a navigation only when the navigator's web view reports it finished, and a
  /// web view whose controller is not in a window never lays out. Mounting on `.reading` would
  /// deadlock: the restore that must finish first would wait on the view `.reading` mounts.
  /// Mounting from `.opening` also puts the host controller in the window before the navigator is
  /// installed.
  public private(set) var isPageMounted = false

  /// Whether the page must be covered. The mounted page shows the opening spread until the restore
  /// lands, so between `.opening` and `.reading` it is laid out but hidden, or the reader would
  /// watch page 1 appear then jump. The cover must be an opaque layer over the surface: hiding or
  /// fading the surface itself stops it laying out, the deadlock `isPageMounted` avoids.
  public var isPageObscured: Bool { state != .reading }

  public private(set) var isChromeVisible = true
  public private(set) var isFinishOfferVisible = false
  public private(set) var currentPosition: ReadingPosition?
  /// Where reading was before the last jump, offered back until it is taken, dismissed, or times
  /// out. See `ReaderModel+ReturnPoint.swift`.
  public internal(set) var returnPoint: ReaderReturnPoint?
  var jumpCount = 0
  public private(set) var preferences = ReaderPreferences()
  public private(set) var reflowControlsEnabled = true
  public private(set) var progressDisplay = ReaderProgressDisplay(
    text: ReaderCopy.progressPercent(0),
    pageText: nil,
    percentText: ReaderCopy.progressPercent(0),
    percentage: 0,
    chapterTitle: nil,
    page: nil,
    pageCount: nil,
    chapterTimeRemainingText: nil,
    bookTimeRemainingText: nil)

  public var canRetryDownload: Bool {
    state == .recoverableError || state == .unopenable
  }

  /// Only a user-paused row. The scheduler would re-hold a Wi-Fi hold on its next pass, and an
  /// auth hold only exits through re-authentication, so resume would do nothing for either.
  public var canResumeDownload: Bool {
    state == .downloadHeld(reason: .paused)
  }

  public var errorMessage: String? {
    switch state {
    case .recoverableError:
      switch lastRecoverableErrorReason {
      case .downloadFailed: ReaderCopy.downloadFailed
      case .downloadRejected: ReaderCopy.downloadRejected
      }
    case .unopenable: ReaderCopy.unopenable
    case .drmProtected: ReaderCopy.drmProtected
    case .publicationServerFailure: ReaderCopy.publicationServerFailure
    case .downloadHeld(let reason): ReaderCopy.downloadHeld(reason)
    case .unavailable:
      switch lastUnavailableReason {
      case .noEpubAdvertised: ReaderCopy.noEpub
      case .advertisedButUnavailable: ReaderCopy.advertisedButUnavailable
      case .ebookIdentityNotFetched: ReaderCopy.ebookIdentityNotFetched
      }
    case .idle, .downloading, .opening, .reading: nil
    }
  }

  private let itemID: String
  private let restoreBudget: Duration
  private let openingIndicatorThreshold: Duration
  private let category: ItemMediaCategory
  private let stateReading: any ReaderStateReading
  private let progress: any ReaderProgressAccessing
  private let extrasAccess: any ItemDetailExtrasAccess
  let preferencesStore: any ReaderPreferencesStoring
  private let downloadIntents: any DownloadIntents
  let renderer: any EPUBRendering
  private let tracker: ReadingSessionTracker
  private let restoreBox: ReaderRestoreBox
  private let closeCoordinator: ReaderCloseCoordinator
  private let finishOfferer: ReaderFinishOfferer
  private let playbackInterlock: any ReaderPlaybackInterlock
  private(set) var publication: OpenedEPUBPublication?
  private var positionContinuation: AsyncStream<ReadingPosition>.Continuation?
  @ObservationIgnored private var positionRelayTask: Task<Void, Never>?
  @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
  @ObservationIgnored private var openingIndicatorTask: Task<Void, Never>?
  private var lastUnavailableReason: UnavailableReason = .noEpubAdvertised
  private var lastRecoverableErrorReason: RecoverableErrorReason = .downloadFailed
  private var didClose = false
  /// The tracker has a session to flush. SwiftUI builds and discards extra `ReaderModel`s that
  /// never open; they must not begin a background task or request a drain on every background.
  private var didOpenTracker = false
  private let appLifecycle: any AppLifecycle

  public init(
    itemID: String,
    category: ItemMediaCategory,
    stateReading: any ReaderStateReading,
    progress: any ReaderProgressAccessing = NoOpReaderProgressAccess(),
    extrasAccess: any ItemDetailExtrasAccess = NoOpItemDetailExtrasAccess(),
    preferencesStore: any ReaderPreferencesStoring,
    downloadIntents: any DownloadIntents,
    renderer: any EPUBRendering,
    appLifecycle: any AppLifecycle,
    playbackInterlock: any ReaderPlaybackInterlock = NoOpReaderPlaybackInterlock(),
    clock: any ReadingSessionClock = SystemReadingSessionClock(),
    restoreBudget: Duration = .seconds(5),
    openingIndicatorThreshold: Duration = .milliseconds(500)
  ) {
    self.itemID = itemID
    self.restoreBudget = restoreBudget
    self.openingIndicatorThreshold = openingIndicatorThreshold
    self.category = category
    self.stateReading = stateReading
    self.progress = progress
    self.extrasAccess = extrasAccess
    self.preferencesStore = preferencesStore
    self.downloadIntents = downloadIntents
    self.renderer = renderer
    self.appLifecycle = appLifecycle
    self.playbackInterlock = playbackInterlock
    restoreBox = ReaderRestoreBox()
    finishOfferer = ReaderFinishOfferer()
    tracker = ReadingSessionTracker(
      restoreTargetProvider: ReaderRestoreProvider(box: restoreBox),
      intentEmitter: ReaderIntentEmitter(itemID: itemID, progress: progress),
      finishOfferer: finishOfferer,
      clock: clock)
    closeCoordinator = ReaderCloseCoordinator(tracker: tracker, renderer: renderer)

    lifecycleTask = Task { [weak self] in
      for await transition in appLifecycle.transitions {
        guard let self, Task.isCancelled == false else { return }
        if transition == .background {
          await self.background()
        }
      }
    }
    finishOfferer.handler = { [weak self] in
      await self?.receiveFinishOffer()
    }
  }

  /// Flushes this instance's own reading session only. The renderer is shared and injected, and
  /// SwiftUI builds a `ReaderModel` per re-evaluation of the presenting view, discarding all but
  /// the first, so closing the renderer here would take the live publication down with a discarded
  /// instance, leaving a blank page under chrome. That is the presented model's explicit `close()`.
  /// A tracker never opened flushes nothing.
  deinit {
    lifecycleTask?.cancel()
    positionRelayTask?.cancel()
    openingIndicatorTask?.cancel()
    let closeCoordinator = closeCoordinator
    Task { await closeCoordinator.closeSession() }
  }

  private func startOpeningIndicatorDelay() {
    openingIndicatorTask?.cancel()
    isOpeningIndicatorVisible = false
    let threshold = openingIndicatorThreshold
    openingIndicatorTask = Task { [weak self] in
      do {
        try await Task.sleep(for: threshold)
      } catch {
        return
      }
      guard Task.isCancelled == false, let self, self.state == .opening else { return }
      self.isOpeningIndicatorVisible = true
    }
  }

  private func cancelOpeningIndicator() {
    openingIndicatorTask?.cancel()
    openingIndicatorTask = nil
    isOpeningIndicatorVisible = false
  }

  public func toggleChrome() {
    isChromeVisible.toggle()
  }

  public func turnPage(_ direction: ReaderPageDirection) async {
    _ = await renderer.turnPage(direction)
  }

  /// The reader dragged the page. The navigator turns or scrolls it on its own, so this only
  /// gets the chrome out of the way.
  public func pageSwiped() {
    isChromeVisible = false
  }

  /// A page turn asked for by tapping the page itself. While the chrome is up the tap only
  /// dismisses it, so a reader reaching for the page does not lose their place by accident.
  public func turnPage(fromTap direction: ReaderPageDirection) async {
    guard isChromeVisible == false else {
      isChromeVisible = false
      return
    }
    await turnPage(direction)
  }

  /// `initialTarget` is where the caller wants the reader to land, such as a tapped contents
  /// entry. It outranks the saved reading position but does not replace it in the tracker's seed:
  /// arriving elsewhere is a real move, and seeding the tracker with the destination would
  /// suppress the write that records it.
  /// `initialTarget` is where the caller wants the reader to land, such as a tapped contents
  /// entry. It outranks the saved reading position but does not replace it in the tracker's seed:
  /// arriving elsewhere is a real move, and seeding the tracker with the destination would
  /// suppress the write that records it.
  public func open(initialTarget: ReaderRestoreTarget? = nil) async {
    guard state == .idle else { return }
    ReaderTrace.emit("open", ["item": itemID])
    guard await startRenderer() else { return }

    guard let fileURL = await waitForDownloadedFile() else {
      if state == .idle { state = .unavailable }
      return
    }

    state = .opening
    isPageMounted = true
    ReaderTrace.emit("file", ["item": itemID, "name": ReaderTrace.fileValue(fileURL)])
    await openPublication(at: fileURL, initialTarget: initialTarget)
  }

  /// Starts the shared renderer, installing the failure state when it cannot start.
  private func startRenderer() async -> Bool {
    do {
      try await renderer.start()
      return true
    } catch {
      ReaderTrace.emit("startfail", ["item": itemID, "error": String(describing: error)])
      state = .publicationServerFailure
      return false
    }
  }

  /// Follows the ebook's state projection until a downloaded file arrives, setting the state each
  /// refusal, hold or failure produces. Nil means no file arrived; the state already says why.
  private func waitForDownloadedFile() async -> URL? {
    var fileURL: URL?
    var didRequestDownload = false
    var didAttemptExtrasRefresh = false
    let states = stateReading.observeReaderState(itemId: itemID)
    for await readerState in states {
      // The projection's own value, not the model state it produces: "not-downloaded" and
      // "download-failed" reach the same screen by different routes, and only this says which.
      ReaderTrace.emit(
        "state", ["item": itemID, "value": ReaderTraceLabel.label(for: readerState)])
      switch readerState {
      case .noEpubAdvertised:
        lastUnavailableReason = .noEpubAdvertised
        state = .unavailable
        return nil
      case .advertisedButUnavailable, .ebookIdentityNotFetched:
        if didAttemptExtrasRefresh {
          lastUnavailableReason = .advertisedButUnavailable
          state = .unavailable
          return nil
        }
        didAttemptExtrasRefresh = true
        lastUnavailableReason =
          readerState == .ebookIdentityNotFetched
          ? .ebookIdentityNotFetched
          : .advertisedButUnavailable
        state = .unavailable
        guard await extrasAccess.itemDetailExtras(itemId: itemID) != nil else {
          lastUnavailableReason = .advertisedButUnavailable
          state = .unavailable
          return nil
        }
      case .availableNotDownloaded:
        state = .downloading(progress: 0)
        if didRequestDownload == false {
          didRequestDownload = true
          do {
            try await downloadIntents.requestEbookDownload(itemID: itemID)
          } catch {
            lastRecoverableErrorReason = .downloadFailed
            state = .recoverableError
            return nil
          }
        }
      case .downloading(let progress):
        state = .downloading(progress: progress)
      case .downloadHeld(let reason, _):
        // No `return`: the hold can clear on its own, and this observation delivers that.
        state = .downloadHeld(reason: reason)
      case .downloadedButFileMissing, .downloadFailed:
        lastRecoverableErrorReason = .downloadFailed
        state = .recoverableError
        return nil
      case .downloadRejected:
        lastRecoverableErrorReason = .downloadRejected
        state = .recoverableError
        return nil
      case .downloadedReady(let readyURL):
        fileURL = readyURL
      }
      if fileURL != nil { break }
    }
    return fileURL
  }

  /// Opens the downloaded file, restores the reader's target and begins the reading session.
  private func openPublication(
    at fileURL: URL, initialTarget: ReaderRestoreTarget?
  ) async {
    do {
      guard let inputs = try await openingInputs(initialTarget: initialTarget) else { return }
      let request = EPUBOpenRequest(
        localFileURL: fileURL, preferences: inputs.preferences,
        initialLocation: Self.initialLocation(for: inputs.target))
      let opened = try await renderer.open(request)
      // A close that landed mid-open ran the renderer's close against no publication, so close
      // the one that just opened or it lingers until the next open.
      guard didClose == false else {
        await renderer.close()
        return
      }
      ReaderTrace.emit("tail", ["item": itemID, "stage": "opened"])
      try await install(opened, preferences: inputs.preferences)
      await beginReadingSession(
        restoreTarget: inputs.restoreTarget, landingTarget: inputs.target)
    } catch let failure as EPUBRenderingOpenFailure {
      ReaderTrace.emit(
        "openfail", ["item": itemID, "kind": String(describing: failure)])
      await handleOpenFailure(failure)
    } catch {
      ReaderTrace.emit(
        "openfail", ["item": itemID, "kind": "other", "error": String(describing: error)])
      lastRecoverableErrorReason = .downloadFailed
      state = .recoverableError
    }
  }

  /// The preferences and the restore target an open lands with. Nil when a close landed while they
  /// were being read.
  private func openingInputs(
    initialTarget: ReaderRestoreTarget?
  ) async throws -> (
    preferences: ReaderPreferences, restoreTarget: ReaderRestoreTarget?,
    target: ReaderRestoreTarget?
  )? {
    async let loadedPreferences = loadPreferences()
    async let fetchedRestoreTarget = try? await progress.fetchRestoreTarget(itemID: itemID)
    let resolvedPreferences = try await loadedPreferences
    let restoreTarget = await fetchedRestoreTarget
    guard didClose == false else { return nil }

    preferences = resolvedPreferences
    return (resolvedPreferences, restoreTarget, initialTarget ?? restoreTarget)
  }

  /// Publishes the opened publication and submits the capabilities its reflow decides.
  private func install(_ opened: OpenedEPUBPublication, preferences resolved: ReaderPreferences)
    async throws
  {
    publication = opened
    reflowControlsEnabled = opened.reflowable
    let adjustedPreferences = preferencesWithCapability(
      resolved, reflowable: opened.reflowable)
    preferences = adjustedPreferences
    if adjustedPreferences != resolved {
      try await renderer.submit(preferences: adjustedPreferences)
    }
    ReaderTrace.emit("tail", ["item": itemID, "stage": "preferences"])
  }

  /// Seeds the tracker with the fetched target, restores the landing target and starts the
  /// position relay: the reader is `.reading` only once the restore has settled.
  private func beginReadingSession(
    restoreTarget: ReaderRestoreTarget?, landingTarget: ReaderRestoreTarget?
  ) async {
    ReaderTrace.emit(
      "tail",
      ["item": itemID, "stage": "restore-target", "value": Self.label(for: restoreTarget)])
    await restoreBox.set(restoreTarget)
    let (trackerStream, trackerContinuation) = AsyncStream<ReadingPosition>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    positionContinuation = trackerContinuation
    await tracker.open(positions: trackerStream)
    didOpenTracker = true
    ReaderTrace.emit("tail", ["item": itemID, "stage": "tracker"])
    if let landingTarget {
      await restore(to: landingTarget)
    }
    guard didClose == false else { return }
    startPositionRelay(source: renderer.positionUpdates)
    state = .reading
  }

  /// Discards the failed row before asking for the file again, then re-enters `open()`.
  ///
  /// Both halves are needed. Re-requesting alone is suppressed by the very row being retried, and
  /// `open()` has already left the observation loop, so even an enqueued row has no listener,
  /// leaving a 0% download bar that never clears. Purging also fixes the common cause: the
  /// replacement request re-reads the server's current file identity and size, which a transfer
  /// that failed validation against a stale library scan needs.
  public func retryDownload() async {
    guard canRetryDownload else { return }
    state = .downloading(progress: 0)
    do {
      try await downloadIntents.purgeEbookDownload(itemID: itemID, source: .readerEbook)
    } catch {
      lastRecoverableErrorReason = .downloadFailed
      state = .recoverableError
      return
    }
    state = .idle
    await open()
  }

  /// Releases a user-paused ebook row. The reader stays on its observation, so the resumed transfer
  /// arrives through the same path an unheld download would have taken.
  public func resumeDownload() async {
    guard canResumeDownload else { return }
    do {
      try await downloadIntents.resumeEbookDownload(itemID: itemID)
    } catch {
      lastRecoverableErrorReason = .downloadFailed
      state = .recoverableError
    }
  }

  public func updatePreferences(_ requested: ReaderPreferences) async {
    guard state == .reading else { return }
    let next = preferencesWithCapability(
      requested, reflowable: preferences.reflowable, preservingReflowControls: true)
    guard next != preferences else { return }
    do {
      let json = try Self.encode(next)
      try await preferencesStore.writePreferencesJSON(json)
      preferences = next
      try await renderer.submit(preferences: next)
    } catch {
      // A failed preference write leaves both the persisted and renderer values unchanged.
    }
  }

  /// The footer is drawn by the app over the page, so this choice is persisted but not submitted:
  /// resubmitting unchanged preferences would make Readium lay the page out again.
  public func selectFooterReadout(_ readout: ReaderFooterReadout) async {
    guard state == .reading, readout != preferences.footerReadout else { return }
    var next = preferences
    next.footerReadout = readout
    do {
      try await preferencesStore.writePreferencesJSON(Self.encode(next))
      preferences = next
    } catch {
      // A failed write leaves the footer on the readout it was already showing.
    }
  }

  public func selectTOC(_ entry: TOCEntry) async {
    guard let publication else { return }
    let target: ReadingPosition?
    if let position = entry.position {
      // Positions are one-based (Readium's `Locator.position`), so the array index is one less.
      let positions = publication.positions ?? []
      target =
        positions.first(where: { $0.position == position })
        ?? (positions.indices.contains(position - 1) ? positions[position - 1] : nil)
    } else if let href = entry.href {
      target = publication.positions?.first(where: { $0.href == href })
    } else {
      target = nil
    }
    guard let target else { return }
    await jump(to: target) { try await $0.go(to: target) }
  }

  /// Returns the page label for a TOC entry backed by this publication's positions list.
  public func pageLabel(for entry: TOCEntry) -> String? {
    guard publication?.positions != nil, let position = entry.position else { return nil }
    return ReaderCopy.pageLabel(forPosition: position)
  }

  public func markFinished() async {
    guard category == .ebook, isFinishOfferVisible else { return }
    // The ebook finish sets the same item-wide `isFinished` the audio bookmark joins, and a live
    // session's own tick writes that flag unconditionally. So the book's audio stops first, and
    // the continuation waits until the write has landed, exactly as the podcast interlocks do.
    let generation = await playbackInterlock.stopIfActive(itemID: itemID)
    do {
      try await progress.markEbookAsFinished(itemID: itemID)
      isFinishOfferVisible = false
      if let generation {
        await playbackInterlock.prepareContinuation(after: itemID, generation: generation)
      }
    } catch {
      lastRecoverableErrorReason = .downloadFailed
      state = .recoverableError
    }
  }

  /// Flushes the position, then waits for the drain that sends it, under one bounded background
  /// task so suspension does not cut the send off.
  public func background() async {
    guard didOpenTracker, didClose == false else { return }
    let tracker = self.tracker
    let progress = self.progress
    await appLifecycle.runBoundedBackgroundTask {
      await tracker.background()
      await progress.requestSync()
    }
  }

  public func close() async {
    guard didClose == false else { return }
    didClose = true
    isPageMounted = false
    cancelOpeningIndicator()
    positionRelayTask?.cancel()
    positionRelayTask = nil
    positionContinuation?.finish()
    positionContinuation = nil
    await closeCoordinator.close()
  }

  /// Sends the reader to its restore target, giving up after `restoreBudget`.
  ///
  /// Readium resolves `go(to:)` only when the navigator's web view reports the navigation finished,
  /// so a locator that never resolves in this publication hangs the await forever, with the book
  /// rendered but hidden behind "Opening book…". Restoring is best-effort (a throw is discarded and
  /// reading continues), so the tolerance must cover a restore that never returns.
  ///
  /// Not a task group: a group awaits its children, so a hung child would re-block what is being
  /// bounded. Whichever task reports first wins; a losing navigation is cancelled and left behind.
  private func restore(to target: ReaderRestoreTarget) async {
    let (outcomes, report) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let renderer = self.renderer
    let navigation = Task { @MainActor in
      while Task.isCancelled == false {
        do {
          switch target {
          case .position(let position):
            try await renderer.go(to: position)
          case .totalProgression(let totalProgression):
            try await renderer.go(toTotalProgression: totalProgression)
          }
          report.yield(true)
          return
        } catch {
          guard Task.isCancelled == false else { return }
          do {
            try await Task.sleep(for: .milliseconds(50))
          } catch {
            return
          }
        }
      }
    }
    let budget = Task { [restoreBudget] in
      try? await Task.sleep(for: restoreBudget)
      report.yield(false)
    }

    var outcome = outcomes.makeAsyncIterator()
    let landed = await outcome.next() ?? false
    budget.cancel()
    if landed == false { navigation.cancel() }
    ReaderTrace.emit(
      "tail", ["item": itemID, "stage": "restored", "landed": landed ? "1" : "0"])
  }

  /// Carries the value, not just the kind: a misbehaving restore is usually a specific locator.
  private static func label(for target: ReaderRestoreTarget?) -> String {
    switch target {
    case .position(let position): "position:\(position.href)@\(position.totalProgression)"
    case .totalProgression(let progression): "progression:\(progression)"
    case nil: "none"
    }
  }

  private static func initialLocation(for target: ReaderRestoreTarget?) -> EPUBInitialLocation? {
    switch target {
    case .position(let position): .position(position)
    case .totalProgression(let progression): .totalProgression(progression)
    case nil: nil
    }
  }

  private func startPositionRelay(source: AsyncStream<ReadingPosition>) {
    let continuation = positionContinuation
    positionRelayTask = Task { [weak self] in
      for await position in source {
        guard let self else { return }
        self.currentPosition = position
        self.refreshProgressDisplay()
        continuation?.yield(position)
      }
    }
  }

  private func handleOpenFailure(_ failure: EPUBRenderingOpenFailure) async {
    switch failure {
    case .noEbook:
      lastUnavailableReason = .noEpubAdvertised
      state = .unavailable
    case .drmProtected:
      state = .drmProtected
    case .unopenable:
      try? await downloadIntents.purgeEbookDownload(itemID: itemID, source: .readerEbook)
      state = .unopenable
    case .serverFailure:
      state = .publicationServerFailure
    }
  }

  private func refreshProgressDisplay() {
    progressDisplay = makeProgressDisplay()
  }

  private func receiveFinishOffer() {
    if category == .ebook {
      isFinishOfferVisible = true
    }
  }
}
