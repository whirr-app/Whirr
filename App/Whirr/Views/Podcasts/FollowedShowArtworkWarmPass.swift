import ABSApi
import AppModel
import Foundation
import Persistence
import SyncEngine

/// Warms followed-show artwork without entering SyncEngine. The pass is a small
/// App-side observer: RSS follows and artwork URL changes both appear in the same show snapshot.
@MainActor
final class FollowedShowArtworkWarmPass {
  struct Candidate: Hashable, Sendable {
    let itemID: String
    let source: ArtworkSource
    /// The show's own revision, so the row is filed under the identity the player reads.
    let revision: ArtworkRevision
  }

  /// Pure state and decision rules for the pass. Transport, persistence, and lifecycle signals
  /// stay in `FollowedShowArtworkWarmPass`, which keeps snapshot-diff behavior testable without a
  /// network or a running URLCache.
  struct Policy: Sendable {
    enum Action: Sendable, Equatable {
      case skip
      case derive
      case fetch
      case fetchAndDerive
    }

    private(set) var seen: Set<Candidate> = []

    mutating func candidates(from snapshot: NativePodcastShowsSnapshot) -> [Candidate] {
      var newCandidates: [Candidate] = []
      for show in snapshot.shows {
        guard let source = show.providerArtworkSource else { continue }
        let candidate = Candidate(
          itemID: show.serverItemId, source: source, revision: show.artworkRevision)
        if seen.insert(candidate).inserted {
          newCandidates.append(candidate)
        }
      }
      return newCandidates
    }

    static func canTransfer(isForeground: Bool, isConstrainedOrCellular: Bool) -> Bool {
      isForeground && !isConstrainedOrCellular
    }

    static func action(bytesHeld: Bool, isSaved: Bool) -> Action {
      if isSaved {
        return bytesHeld ? .skip : .fetch
      }
      return bytesHeld ? .derive : .fetchAndDerive
    }
  }

  private let artworkClient: ProviderArtworkClient
  private let service: CoverPaletteService
  private let lifecycle: any AppLifecycle
  private var policy = Policy()
  private var pending: [Candidate] = []
  private var activeTask: Task<Void, Never>?
  private var isConstrainedOrCellular: Bool
  private var isSuspended: Bool
  private var showsTask: Task<Void, Never>?
  private var networkTask: Task<Void, Never>?
  private var lifecycleTask: Task<Void, Never>?

  init(
    reading: any NativePodcastShowsReading,
    artworkClient: ProviderArtworkClient,
    service: CoverPaletteService,
    networkConditions: any NetworkConditions,
    lifecycle: any AppLifecycle
  ) {
    self.artworkClient = artworkClient
    self.service = service
    self.lifecycle = lifecycle
    isConstrainedOrCellular = networkConditions.isConstrainedOrCellular
    isSuspended = !lifecycle.isForeground

    showsTask = Task { [weak self, reading] in
      for await snapshot in reading.observeShows() {
        guard Task.isCancelled == false else { return }
        self?.receive(snapshot)
      }
    }
    networkTask = Task { [weak self, networkConditions] in
      for await snapshot in networkConditions.changes {
        guard Task.isCancelled == false else { return }
        self?.networkChanged(isConstrainedOrCellular: snapshot.isConstrainedOrCellular)
      }
    }
    lifecycleTask = Task { [weak self, lifecycle] in
      for await transition in lifecycle.transitions {
        guard Task.isCancelled == false else { return }
        self?.lifecycleChanged(transition)
      }
    }
  }

  /// Exposes the policy's snapshot diff for tests and for callers that need to inspect a planned
  /// pass without starting I/O.
  func candidates(from snapshot: NativePodcastShowsSnapshot) -> [Candidate] {
    policy.candidates(from: snapshot)
  }

  /// Applies one observed snapshot and starts at most one transfer. The RSS client has two gate
  /// permits, but visible artwork must always retain one free permit; this pass therefore caps
  /// itself at one transfer even when more candidates are queued.
  func receive(_ snapshot: NativePodcastShowsSnapshot) {
    pending.append(contentsOf: policy.candidates(from: snapshot))
    pump()
  }

  func setSuspended(_ suspended: Bool) {
    guard isSuspended != suspended else { return }
    isSuspended = suspended
    if suspended {
      activeTask?.cancel()
    } else {
      pump()
    }
  }

  private func networkChanged(isConstrainedOrCellular: Bool) {
    let wasConstrained = self.isConstrainedOrCellular
    self.isConstrainedOrCellular = isConstrainedOrCellular
    if isConstrainedOrCellular {
      activeTask?.cancel()
    } else if wasConstrained {
      pump()
    }
  }

  private func lifecycleChanged(_ transition: AppLifecycleTransition) {
    setSuspended(transition == .background)
  }

  private func pump() {
    guard activeTask == nil,
      pending.isEmpty == false,
      Policy.canTransfer(
        isForeground: lifecycle.isForeground && !isSuspended,
        isConstrainedOrCellular: isConstrainedOrCellular)
    else { return }

    let candidate = pending.removeFirst()
    activeTask = Task { [weak self] in
      await self?.execute(candidate)
    }
  }

  /// The home card key every palette surface derives from (`CoverPaletteSource`), so the bytes this
  /// warms are the ones the player and Home read and the row lands under their identity.
  static func key(for candidate: Candidate) -> ArtworkKey {
    CoverPaletteSource.cardKey(
      source: candidate.source, itemID: candidate.itemID, revision: candidate.revision)
  }

  private func execute(_ candidate: Candidate) async {
    let key = Self.key(for: candidate)
    var completed = false
    do {
      let isSaved = await service.unsaved([CoverPaletteIdentity(key)]).isEmpty
      let bytesHeld = await artworkClient.data(for: key) != nil
      let action = Policy.action(bytesHeld: bytesHeld, isSaved: isSaved)
      switch action {
      case .skip:
        break
      case .derive:
        try Task.checkCancellation()
        await service.save(key)
        try Task.checkCancellation()
      case .fetch:
        try Task.checkCancellation()
        _ = try await artworkClient.fetch(key)
      case .fetchAndDerive:
        try Task.checkCancellation()
        _ = try await artworkClient.fetch(key)
        try Task.checkCancellation()
        await service.save(key)
        try Task.checkCancellation()
      }
      completed = true
    } catch {
      // A policy pause cancels the current operation and puts it back at the front below. Other
      // transport failures are consumed for this snapshot; a later artwork URL snapshot retries.
    }

    if !completed && Task.isCancelled {
      pending.insert(candidate, at: 0)
    }
    activeTask = nil
    pump()
  }

  deinit {
    showsTask?.cancel()
    networkTask?.cancel()
    lifecycleTask?.cancel()
    activeTask?.cancel()
  }
}
