import Foundation
import Observation
import Persistence

public enum SmartListCopy {
  public static let nothingToPlay = "There is nothing left to play in this list."
  public static let startFailed = "Couldn't start this episode. Try again."
  public static let hideFailed = "Couldn't hide this episode. Try again."
  public static let unhideFailed = "Couldn't show this episode again. Try again."
}

public enum SmartListError: Error, Sendable, Equatable {
  case nothingToPlay
  case startFailed
  case hideFailed
  case unhideFailed

  public var message: String {
    switch self {
    case .nothingToPlay: SmartListCopy.nothingToPlay
    case .startFailed: SmartListCopy.startFailed
    case .hideFailed: SmartListCopy.hideFailed
    case .unhideFailed: SmartListCopy.unhideFailed
    }
  }
}

/// One list's screen: its rows (first 200, growing on scroll to 1,000), hide and unhide, and Play.
///
/// Play and a row's play start through `SmartListPlaybackStarting`; the run is begun by playback
/// after a successful start, never written here.
@MainActor
@Observable
public final class SmartListModel {
  public enum State: Sendable, Equatable {
    case loading
    case unavailable
    /// The list no longer exists.
    case missing
    case loaded
  }

  public static let pageSize = SmartListEpisodesReading.defaultLimit
  public static let maximumRows = SmartListEpisodesReading.maximumLimit

  public let listID: Int64
  public private(set) var state: State = .loading
  public private(set) var list: SmartList?
  public private(set) var episodes: [SmartListEpisode] = []
  public private(set) var hasMore = false
  public private(set) var matchCount: Int?
  public private(set) var isRunActive = false
  public private(set) var isStarting = false
  public private(set) var error: SmartListError?
  /// The episode last hidden here, for an undo.
  public private(set) var lastHidden: SmartListHiddenEpisodeRecord?
  /// How many rows the observation currently asks for.
  public private(set) var limit = SmartListModel.pageSize

  private let services: SmartListServices
  private let playback: (any SmartListPlaybackStarting)?
  private var sources: SmartListSourceState?
  @ObservationIgnored private var reading: SmartListEpisodesReading?
  @ObservationIgnored private var sourceTask: Task<Void, Never>?
  @ObservationIgnored private var listTask: Task<Void, Never>?
  @ObservationIgnored private var snapshotTask: Task<Void, Never>?
  @ObservationIgnored private var generation = GenerationFence()

  public init(
    listID: Int64, services: SmartListServices, playback: (any SmartListPlaybackStarting)? = nil
  ) {
    self.listID = listID
    self.services = services
    self.playback = playback
    let stream = services.observeSources()
    sourceTask = Task { [weak self] in
      for await sources in stream {
        guard let self else { return }
        self.apply(sources)
      }
    }
    let listStream = services.store.observeLists()
    let id = listID
    listTask = Task { [weak self] in
      for await lists in listStream {
        guard let self else { return }
        self.receive(list: lists.first { $0.id == id })
      }
    }
  }

  deinit {
    sourceTask?.cancel()
    listTask?.cancel()
    snapshotTask?.cancel()
  }

  // MARK: - Reading

  private func receive(list: SmartList?) {
    self.list = list
    guard sources?.isAvailable == true else { return }
    if list == nil {
      state = .missing
    } else if state == .missing {
      state = .loaded
    }
  }

  /// Re-reads the list and whether it has the active run. The list itself is observed.
  public func reload() async {
    list = try? await services.store.list(id: listID)
    if sources?.isAvailable == true { state = list == nil ? .missing : .loaded }
    await refreshRun()
  }

  /// Asks for the next page, up to the maximum. The rows already shown stay until it arrives.
  public func loadMore() {
    guard hasMore, limit < Self.maximumRows else { return }
    limit = min(limit + Self.pageSize, Self.maximumRows)
    subscribe()
  }

  private func apply(_ sources: SmartListSourceState) {
    let previous = self.sources
    self.sources = sources
    guard sources.isAvailable else {
      generation.advance()
      snapshotTask?.cancel()
      reading = nil
      episodes = []
      hasMore = false
      matchCount = nil
      state = .unavailable
      return
    }
    guard previous?.nativeEnabled != sources.nativeEnabled || reading == nil else { return }
    reading = services.makeReading(sources.nativeEnabled)
    subscribe()
  }

  private func subscribe() {
    guard let reading else { return }
    snapshotTask?.cancel()
    let generation = generation.advance()
    let stream = reading.observeEpisodes(listID: listID, limit: limit)
    snapshotTask = Task { [weak self] in
      for await snapshot in stream {
        guard let self, self.generation.isCurrent(generation) else { return }
        await self.receive(snapshot)
      }
    }
  }

  private func receive(_ snapshot: SmartListSnapshot) async {
    list = try? await services.store.list(id: listID)
    guard list != nil else {
      episodes = []
      hasMore = false
      matchCount = 0
      state = .missing
      return
    }
    episodes = snapshot.episodes
    hasMore = snapshot.hasMore
    matchCount = snapshot.matchCount
    state = .loaded
    await refreshRun()
  }

  private func refreshRun() async {
    let active = try? await services.runs.current()?.listId
    isRunActive = active == listID
  }

  // MARK: - Hiding

  public func hide(_ episode: SmartListEpisode) async {
    do {
      try await services.hiddenEpisodes.hide(
        listID: listID, itemID: episode.itemID, episodeID: episode.episodeID)
      lastHidden = SmartListHiddenEpisodeRecord(
        listId: listID, itemID: episode.itemID, episodeID: episode.episodeID)
      error = nil
    } catch {
      self.error = .hideFailed
    }
  }

  public func unhide(itemID: String, episodeID: String) async {
    do {
      try await services.hiddenEpisodes.unhide(
        listID: listID, itemID: itemID, episodeID: episodeID)
      if lastHidden?.itemID == itemID, lastHidden?.episodeID == episodeID { lastHidden = nil }
      error = nil
    } catch {
      self.error = .unhideFailed
    }
  }

  // MARK: - Playing

  /// Starts the list's first unfinished episode (priority first) within the list. False when there
  /// is nothing to play or the start fails.
  @discardableResult
  public func play() async -> Bool {
    guard isStarting == false, let reading else { return false }
    isStarting = true
    defer { isStarting = false }
    let candidate = try? await reading.topEpisodes(listID: listID, count: 1).first
    guard let candidate else {
      error = .nothingToPlay
      return false
    }
    return await start(itemID: candidate.itemID, episodeID: candidate.episodeID)
  }

  /// Starts this row within the list: "play from here".
  @discardableResult
  public func play(_ episode: SmartListEpisode) async -> Bool {
    guard isStarting == false else { return false }
    isStarting = true
    defer { isStarting = false }
    return await start(itemID: episode.itemID, episodeID: episode.episodeID)
  }

  private func start(itemID: String, episodeID: String) async -> Bool {
    guard let playback else {
      error = .startFailed
      return false
    }
    let started = await playback.startFromList(
      listID: listID, itemID: itemID, episodeID: episodeID)
    error = started ? nil : .startFailed
    if started { await refreshRun() }
    return started
  }

  public func clearError() {
    error = nil
  }
}
