import AppModel
import Foundation
import Observation
import Persistence
import PlayerCore
import WatchProtocol

/// Account changes, the publication floor, and assembling and emitting the catalogue. The values
/// it assembles come from the readers in `WatchCataloguePublisher+Readers.swift` and the playback
/// model in `+Playback.swift`.
extension WatchCataloguePublisher {
  func accountDidChange(_ next: AccountIdentity?) {
    guard started else { return }
    if let next, let scopeIdentity, next != scopeIdentity {
      // Projection readers belong to the original account graph. A new account needs a new
      // publisher from RootComposition, not old rows relabelled with a different stamp.
      stopAndPublishSignedOut()
      return
    }
    if scopeIdentity == nil { scopeIdentity = next }
    guard next != identity || hasObservedAccount == false else { return }
    hasObservedAccount = true
    publicationEpoch &+= 1
    cancelReaderTasks()
    publicationTask?.cancel()
    publicationTask = nil
    assemblyTask?.cancel()
    assemblyTask = nil
    assemblyPending = false
    identity = next
    clearProjection()

    guard next != nil else {
      browseModel.unbind()
      watchAccountStamp = nil
      publishSignedOut()
      return
    }
    if let stamp = try? WatchAccountStamp(
      accountIdentityHash: CompanionCatalogueBuilder.identityHashes(for: next!).account,
      serverIdentityHash: CompanionCatalogueBuilder.identityHashes(for: next!).server)
    {
      watchAccountStamp = stamp
      browseModel.bind(accountStamp: stamp)
    } else {
      // Identity hashes should be fixed-size, but fail closed if construction rejects them so a
      // prior account's browse stamp is not left live.
      watchAccountStamp = nil
      browseModel.unbind()
      publishSignedOut()
      return
    }
    let currentPublicationEpoch = publicationEpoch
    startReaderTasks(publicationEpoch: currentPublicationEpoch)
    observePlayback(publicationEpoch: currentPublicationEpoch)
    schedulePublication(publicationEpoch: currentPublicationEpoch)
  }

  func schedulePublication(publicationEpoch: UInt64, interval: Duration? = nil) {
    publicationTask?.cancel()
    // While a catalogue assembles, the floor starts from its emission, which has not happened
    // yet. A delay measured now would run from when assembly began and let the next publication
    // follow a slow one closely, so the emission schedules it.
    guard assemblyTask == nil else {
      publicationTask = nil
      assemblyPending = true
      return
    }
    let delay = publicationDelayNanoseconds(interval: interval ?? minimumPublicationInterval)
    publicationTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: delay)
      } catch {
        return
      }
      // A sleep that has already finished ignores cancellation, so a task superseded while
      // waiting to resume must check for itself. Publishing here would land just ahead of its
      // replacement, whose delay predates this publication, and break the floor.
      guard !Task.isCancelled else { return }
      guard let self, self.started, self.publicationEpoch == publicationEpoch, self.identity != nil else {
        return
      }
      self.publicationTask = nil
      self.publishCurrent()
    }
  }

  /// How long the next publication waits: the debounce after a quiet period, otherwise however
  /// much of `minimumPublicationInterval` is left to run. The debounce stays the floor so a Watch
  /// command's confirming publication is prompt when nothing published just before it.
  func publicationDelayNanoseconds(interval: Duration) -> UInt64 {
    guard let lastPublishedAt else { return Self.publicationDebounceNanoseconds }
    let elapsed = ContinuousClock.now - lastPublishedAt
    guard elapsed < interval else { return Self.publicationDebounceNanoseconds }
    // Bounded by `interval` via the guard above, so this cannot overflow.
    let remaining = interval - elapsed
    let remainingNanoseconds =
      UInt64(clamping: remaining.components.seconds) &* 1_000_000_000
      &+ UInt64(clamping: remaining.components.attoseconds / 1_000_000_000)
    return max(Self.publicationDebounceNanoseconds, remainingNanoseconds)
  }

  /// Requests a latest-only publication after a playback command or player state transition.
  /// Persisted reader changes continue to schedule themselves independently.
  func refresh() {
    guard started, identity != nil else { return }
    schedulePublication(publicationEpoch: publicationEpoch)
  }

  /// Captures the projection on the main actor and assembles the catalogue off it. The result is
  /// published only if nothing has superseded it in the meantime: no sign-out, no stop, and no
  /// account change, all of which the epoch and sequence below record.
  func publishCurrent() {
    guard assemblyTask == nil else {
      assemblyPending = true
      return
    }
    lastPublishedAt = .now
    guard let identity else { return }
    let state = currentPlaybackState()
    let generatedAt = nextGeneratedAt()
    let progress = playback?.companionPlaybackProgress
    let playhead = progress.map {
      PublishedPlayhead(
        position: $0.position, at: generatedAt, rate: state == .playing ? playback?.playbackRate ?? 1 : 0)
    }
    let assembly = WatchCatalogueAssembly(
      identity: identity,
      nativeEnabled: nativeEnabled,
      absContinue: absContinue,
      nativeContinueItems: nativeContinueItems,
      bookmark: effectiveBookmark(),
      recentBooks: recentBooks,
      absLatest: absLatest,
      nativeLatestEpisodes: nativeLatestEpisodes,
      absDownloads: absDownloads,
      nativeDownloadFeeds: nativeDownloadFeeds,
      generatedAt: generatedAt,
      playbackState: state,
      playbackRate: state.phoneHasSession ? playback?.playbackRate : nil,
      skipBackwardSeconds: backwardSkipSeconds,
      skipForwardSeconds: forwardSkipSeconds,
      playbackRatePresets: ratePresets,
      removePlayedNativeEpisodes: removePlayedNativeEpisodes,
      playbackProgress: progress,
      phoneLastListenedAt: playback?.companionLastListenedAt)
    assemblySequence &+= 1
    let sequence = assemblySequence
    let epoch = publicationEpoch
    let assemble = assemble
    assemblyTask = Task { [weak self] in
      let snapshot = await Task.detached(priority: .userInitiated) { assemble(assembly) }.value
      guard let self, !Task.isCancelled, self.started, self.publicationEpoch == epoch,
        self.assemblySequence == sequence
      else { return }
      self.assemblyTask = nil
      if let snapshot, self.identity != nil {
        self.publish(snapshot)
        self.publishedPlayhead = playhead
        // Stamped again at emission: assembly duration varies, and the floor is about the gap
        // the Watch sees, not when the work began.
        self.lastPublishedAt = .now
      }
      if self.assemblyPending {
        self.assemblyPending = false
        self.schedulePublication(publicationEpoch: epoch)
      }
    }
  }

  func publishSignedOut() {
    lastPublishedAt = .now
    // A catalogue still assembling for the account being signed out must not land after this.
    assemblySequence &+= 1
    assemblyTask?.cancel()
    assemblyTask = nil
    assemblyPending = false
    guard
      let snapshot = try? WatchCatalogueSnapshot(
        accountStamp: nil,
        generatedAt: nextGeneratedAt(),
        items: [],
        playbackState: .idle)
    else { return }
    publish(snapshot)
  }

  func clearProjection() {
    lastPlaybackFingerprint = nil
    publishedPlayhead = nil
    nativeEnabled = false
    absContinue = []
    nativeContinueItems = []
    bookmark = nil
    recentBooks = []
    absLatest = nil
    nativeLatestEpisodes = []
    absDownloads = []
    nativeDownloadFeeds = []
  }

  func nextGeneratedAt() -> Date {
    let candidate = now()
    let generated: Date
    if let lastGeneratedAt, candidate <= lastGeneratedAt {
      generated = lastGeneratedAt.addingTimeInterval(0.001)
    } else {
      generated = candidate
    }
    lastGeneratedAt = generated
    return generated
  }
}
