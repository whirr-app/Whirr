import Foundation
import Observation
import Persistence

public enum SmartListsCopy {
  public static let listLimitReached =
    "You can have up to \(SmartListStore.maximumListCount) smart lists. Delete one to add another."
  public static let createFailed = "Couldn't create the smart list. Try again."
  public static let deleteFailed = "Couldn't delete the smart list. Try again."
  public static let reorderFailed = "Couldn't save the order of your smart lists. Try again."
}

public enum SmartListsError: Error, Sendable, Equatable {
  case listLimitReached
  case createFailed
  case deleteFailed
  case reorderFailed

  public var message: String {
    switch self {
    case .listLimitReached: SmartListsCopy.listLimitReached
    case .createFailed: SmartListsCopy.createFailed
    case .deleteFailed: SmartListsCopy.deleteFailed
    case .reorderFailed: SmartListsCopy.reorderFailed
    }
  }
}

/// One row of the Podcasts tab's Smart Lists section.
public struct SmartListSummary: Sendable, Equatable, Identifiable {
  public let id: Int64
  public let name: String
  public let rules: SmartListRules
  /// Nil until the list's first reading arrives.
  public let matchCount: Int?
  public let nextEpisodeTitle: String?
  public let nextShowTitle: String?
  /// This list is the one with an active run.
  public let isActive: Bool
  /// The episodes whose show covers stand for the list: its leading ones, one per show.
  public let coverEpisodes: [SmartListEpisode]

  public static let maximumCoverCount = 4

  public init(
    id: Int64, name: String, rules: SmartListRules, matchCount: Int?,
    nextEpisodeTitle: String?, nextShowTitle: String?, isActive: Bool,
    coverEpisodes: [SmartListEpisode] = []
  ) {
    self.id = id
    self.name = name
    self.rules = rules
    self.matchCount = matchCount
    self.nextEpisodeTitle = nextEpisodeTitle
    self.nextShowTitle = nextShowTitle
    self.isActive = isActive
    self.coverEpisodes = coverEpisodes
  }

  /// The first episode of each show, in list order, up to `maximumCoverCount`.
  static func coverEpisodes(from episodes: [SmartListEpisode]) -> [SmartListEpisode] {
    var seen = Set<String>()
    var result: [SmartListEpisode] = []
    for episode in episodes where seen.insert(episode.itemID).inserted {
      result.append(episode)
      if result.count == maximumCoverCount { break }
    }
    return result
  }
}

/// The collection of smart lists: their match counts, next episodes and active run, plus create,
/// delete and reorder.
///
/// The lists are observed (`SmartListStore.observeLists`), as is each list's match count and next
/// episode, so a create, rename, reorder or rule edit anywhere reaches it. `reload()` re-reads the
/// active run, which has no observation unless composition injects one.
@MainActor
@Observable
public final class SmartListsModel {
  public enum State: Sendable, Equatable {
    case loading
    /// Neither native subscriptions nor an account: the feature is not shown.
    case unavailable
    case loaded
  }

  /// How many episodes each list observes: enough to find the first unfinished one.
  static let previewLimit = 10

  public private(set) var state: State = .loading
  public private(set) var lists: [SmartListSummary] = []
  public private(set) var error: SmartListsError?
  public private(set) var sources: SmartListSourceState?

  public var isAvailable: Bool { state == .loaded }
  public var canCreate: Bool { lists.count < SmartListStore.maximumListCount }
  public var activeListID: Int64? { activeListIDValue }

  private struct Progress {
    var matchCount: Int?
    var nextTitle: String?
    var nextShowTitle: String?
    var covers: [SmartListEpisode] = []
  }

  private let services: SmartListServices
  private var stored: [SmartList] = []
  private var progress: [Int64: Progress] = [:]
  private var activeListIDValue: Int64?
  @ObservationIgnored private var reading: SmartListEpisodesReading?
  @ObservationIgnored private var sourceTask: Task<Void, Never>?
  @ObservationIgnored private var listsTask: Task<Void, Never>?
  @ObservationIgnored private var needsResubscribe = false
  @ObservationIgnored private var runTask: Task<Void, Never>?
  @ObservationIgnored private var listTasks: [Int64: Task<Void, Never>] = [:]
  @ObservationIgnored private var generation = GenerationFence()

  public init(services: SmartListServices) {
    self.services = services
    let stream = services.observeSources()
    sourceTask = Task { [weak self] in
      for await sources in stream {
        guard let self else { return }
        await self.apply(sources)
      }
    }
    if let observation = services.observeActiveRunListID {
      let stream = observation()
      runTask = Task { [weak self] in
        for await listID in stream {
          guard let self else { return }
          self.setActive(listID)
        }
      }
    }
  }

  deinit {
    sourceTask?.cancel()
    runTask?.cancel()
    listsTask?.cancel()
    for task in listTasks.values { task.cancel() }
  }

  // MARK: - Reading

  /// Re-reads the lists and the active run. The lists are observed, so this is needed only after
  /// a change the models cannot see, such as a run that playback began.
  public func reload() async {
    guard sources?.isAvailable == true else { return }
    guard let lists = try? await services.store.lists() else { return }
    await handle(lists)
  }

  private func apply(_ sources: SmartListSourceState) async {
    let previous = self.sources
    self.sources = sources
    guard sources.isAvailable else {
      generation.advance()
      listsTask?.cancel()
      listsTask = nil
      for task in listTasks.values { task.cancel() }
      listTasks = [:]
      stored = []
      progress = [:]
      lists = []
      state = .unavailable
      return
    }
    if previous?.nativeEnabled != sources.nativeEnabled || reading == nil {
      reading = services.makeReading(sources.nativeEnabled)
      progress = [:]
      needsResubscribe = true
    }
    if listsTask == nil || needsResubscribe {
      listsTask?.cancel()
      let stream = services.store.observeLists()
      listsTask = Task { [weak self] in
        for await lists in stream {
          guard let self else { return }
          await self.handle(lists)
        }
      }
    }
  }

  private func handle(_ lists: [SmartList]) async {
    guard sources?.isAvailable == true else { return }
    let changed =
      lists.map { Key(id: $0.id, rules: $0.rules) }
      != stored.map {
        Key(id: $0.id, rules: $0.rules)
      }
    stored = lists
    await refreshActiveRun()
    if changed || needsResubscribe || listTasks.count != lists.count {
      needsResubscribe = false
      resubscribe()
    }
    publish()
    state = .loaded
  }

  private struct Key: Equatable {
    let id: Int64
    let rules: SmartListRules
  }

  private func resubscribe() {
    let generation = generation.advance()
    for task in listTasks.values { task.cancel() }
    listTasks = [:]
    guard let reading else { return }
    let ids = Set(stored.map(\.id))
    progress = progress.filter { ids.contains($0.key) }
    for list in stored {
      let id = list.id
      let stream = reading.observeEpisodes(listID: id, limit: Self.previewLimit)
      listTasks[id] = Task { [weak self] in
        for await snapshot in stream {
          guard let self, self.generation.isCurrent(generation) else { return }
          self.record(snapshot, for: id)
          if self.services.observeActiveRunListID == nil { await self.refreshActiveRun() }
        }
      }
    }
  }

  private func record(_ snapshot: SmartListSnapshot, for id: Int64) {
    let next = snapshot.episodes.first { $0.isFinished == false }
    progress[id] = Progress(
      matchCount: snapshot.matchCount, nextTitle: next?.title, nextShowTitle: next?.showTitle,
      covers: SmartListSummary.coverEpisodes(from: snapshot.episodes))
    publish()
  }

  /// The episode Play starts for a list: its first unfinished one, priority first. Nil when the
  /// list has nothing left to play.
  public func firstPlayable(listID: Int64) async -> SmartListCandidate? {
    guard let reading else { return nil }
    return try? await reading.topEpisodes(listID: listID, count: 1).first
  }

  private func refreshActiveRun() async {
    let listID = try? await services.runs.current()?.listId
    setActive(listID)
  }

  private func setActive(_ listID: Int64?) {
    guard activeListIDValue != listID else { return }
    activeListIDValue = listID
    publish()
  }

  private func publish() {
    lists = stored.map { list in
      let known = progress[list.id]
      return SmartListSummary(
        id: list.id, name: list.name, rules: list.rules, matchCount: known?.matchCount,
        nextEpisodeTitle: known?.nextTitle, nextShowTitle: known?.nextShowTitle,
        isActive: list.id == activeListIDValue, coverEpisodes: known?.covers ?? [])
    }
  }

  // MARK: - Mutations

  /// Appends a list and starts expanding its Audiobookshelf shows. The 50-list cap surfaces as
  /// `error == .listLimitReached` and a nil return.
  @discardableResult
  public func create(
    name: String, rules: SmartListRules = .default, shows: [SmartListShowSelection] = []
  ) async -> SmartList? {
    guard canCreate else {
      error = .listLimitReached
      return nil
    }
    do {
      let list = try await services.store.create(name: name, rules: rules, shows: shows)
      error = nil
      services.startExpansion(listID: list.id)
      await reload()
      return list
    } catch SmartListStoreError.listLimitReached {
      error = .listLimitReached
    } catch {
      self.error = .createFailed
    }
    return nil
  }

  public func delete(id: Int64) async {
    do {
      try await services.deleteList(id)
      error = nil
    } catch {
      self.error = .deleteFailed
    }
    await reload()
  }

  /// Stores this order, which must be every list once.
  public func reorder(ids: [Int64]) async {
    guard ids != stored.map(\.id) else { return }
    do {
      try await services.store.reorder(ids: ids)
      error = nil
    } catch {
      self.error = .reorderFailed
    }
    await reload()
  }

  /// Moves one list to `position`, clamped to the stored range.
  public func move(id: Int64, toPosition position: Int) async {
    do {
      try await services.store.move(id: id, toPosition: position)
      error = nil
    } catch {
      self.error = .reorderFailed
    }
    await reload()
  }

  public func clearError() {
    error = nil
  }
}
