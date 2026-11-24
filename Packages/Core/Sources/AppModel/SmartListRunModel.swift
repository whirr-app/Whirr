import Foundation
import Observation
import Persistence

/// The active smart list run as the Up Next sheet and the Play Next copy need it: which list, and
/// the next episodes it will play.
///
/// Nil `run` means nothing is running, **including** when a run row exists but its list has no
/// available source (native subscriptions off and signed out). That is the same rule as
/// `SmartListContinuation.currentRun()`: completion then plays Up Next, so the sheet must not
/// promise Up Next "after" a list that will not play.
///
/// Observed, not polled: the run row, the lists (a rename reaches the sheet), the source
/// availability and the list's episodes (a finished episode leaves the preview).
@MainActor
@Observable
public final class SmartListRunModel {
  /// How many upcoming episodes the sheet previews.
  public static let upcomingCount = 3
  /// Rows observed as the change signal for the preview: a finish or a new match near the top.
  static let signalLimit = 10

  public struct Upcoming: Sendable, Equatable, Identifiable {
    public let itemID: String
    public let episodeID: String
    public let title: String
    public let showTitle: String

    public var id: String { "\(itemID)/\(episodeID)" }

    public init(itemID: String, episodeID: String, title: String, showTitle: String) {
      self.itemID = itemID
      self.episodeID = episodeID
      self.title = title
      self.showTitle = showTitle
    }
  }

  public struct ActiveRun: Sendable, Equatable {
    public let listID: Int64
    public let listName: String
    /// Up to `upcomingCount` unfinished episodes after the anchor, never the anchor itself.
    public let upcoming: [Upcoming]

    public init(listID: Int64, listName: String, upcoming: [Upcoming]) {
      self.listID = listID
      self.listName = listName
      self.upcoming = upcoming
    }
  }

  public private(set) var run: ActiveRun?

  public var activeListName: String? { run?.listName }

  private let services: SmartListServices?
  private let continuation: (any PlaybackContinuationSource)?
  private var sources: SmartListSourceState?
  private var record: SmartListRunRecord?
  private var lists: [SmartList] = []
  @ObservationIgnored private var sourceTask: Task<Void, Never>?
  @ObservationIgnored private var runTask: Task<Void, Never>?
  @ObservationIgnored private var listsTask: Task<Void, Never>?
  @ObservationIgnored private var episodesTask: Task<Void, Never>?
  @ObservationIgnored private var fetchTask: Task<Void, Never>?
  @ObservationIgnored private var observedEpisodes: ObservedEpisodes?

  private struct ObservedEpisodes: Equatable {
    let listID: Int64
    let nativeEnabled: Bool
  }

  /// A model with no run, for compositions without Smart Lists.
  public init() {
    services = nil
    continuation = nil
  }

  public init(services: SmartListServices, continuation: any PlaybackContinuationSource) {
    self.services = services
    self.continuation = continuation
    let sourceStream = services.observeSources()
    sourceTask = Task { [weak self] in
      for await sources in sourceStream {
        guard let self else { return }
        self.sources = sources
        self.recompute()
      }
    }
    let runStream = services.runs.observeCurrent()
    runTask = Task { [weak self] in
      for await record in runStream {
        guard let self else { return }
        self.record = record
        self.recompute()
      }
    }
    let listStream = services.store.observeLists()
    listsTask = Task { [weak self] in
      for await lists in listStream {
        guard let self else { return }
        self.lists = lists
        self.recompute()
      }
    }
  }

  deinit {
    sourceTask?.cancel()
    runTask?.cancel()
    listsTask?.cancel()
    episodesTask?.cancel()
    fetchTask?.cancel()
  }

  /// Ends the run (`SmartListRunEndReason.stoppedByListener`); Up Next plays at the next completion.
  public func stop() async {
    await continuation?.endRun(reason: .stoppedByListener)
    run = nil
  }

  private func recompute() {
    fetchTask?.cancel()
    guard let services, let sources, sources.isAvailable, let record,
      let list = lists.first(where: { $0.id == record.listId })
    else {
      episodesTask?.cancel()
      episodesTask = nil
      observedEpisodes = nil
      run = nil
      return
    }
    let reading = services.makeReading(sources.nativeEnabled)
    observeEpisodes(
      ObservedEpisodes(listID: list.id, nativeEnabled: sources.nativeEnabled), reading: reading)
    let anchorKey = record.anchorSortKey.flatMap { SmartListSortKey(encoded: $0) }
    var excluded: [(itemID: String, episodeID: String)] = []
    if let itemID = record.anchorItemID, let episodeID = record.anchorEpisodeID {
      excluded.append((itemID, episodeID))
    }
    let name = list.name
    let listID = list.id
    let excluding = excluded
    fetchTask = Task { [weak self] in
      let candidates =
        (try? await reading.nextEpisodes(
          listID: listID, after: anchorKey, excluding: excluding, count: Self.upcomingCount)) ?? []
      guard !Task.isCancelled, let self else { return }
      self.run = ActiveRun(
        listID: listID, listName: name,
        upcoming: candidates.map {
          Upcoming(
            itemID: $0.itemID, episodeID: $0.episodeID, title: $0.episode.title,
            showTitle: $0.episode.showTitle)
        })
    }
  }

  /// The list's episodes are observed only as a change signal; the preview is `nextEpisodes`.
  private func observeEpisodes(_ target: ObservedEpisodes, reading: SmartListEpisodesReading) {
    guard observedEpisodes != target else { return }
    observedEpisodes = target
    episodesTask?.cancel()
    let stream = reading.observeEpisodes(listID: target.listID, limit: Self.signalLimit)
    episodesTask = Task { [weak self] in
      var isFirst = true
      for await _ in stream {
        guard let self else { return }
        if isFirst {
          isFirst = false
          continue
        }
        self.recompute()
      }
    }
  }
}
