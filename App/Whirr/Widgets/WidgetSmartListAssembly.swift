import ABSApi
import AppModel
import Foundation
import Persistence
import WidgetProtocol

/// A smart list as the publisher holds it: its identity and name, in display order.
nonisolated struct WidgetSmartListName: Sendable, Equatable {
  let id: Int64
  let name: String
}

/// A list's first rows and how many episodes match, read from `SmartListEpisodesReading`.
nonisolated struct WidgetSmartListContent: Sendable, Equatable {
  struct Episode: Sendable, Equatable {
    let episode: HomePodcastEpisode
    let isDownloaded: Bool
  }

  let episodes: [Episode]
  let matchCount: Int?

  init(episodes: [Episode], matchCount: Int?) {
    self.episodes = episodes
    self.matchCount = matchCount
  }

  init(_ snapshot: SmartListSnapshot) {
    episodes = snapshot.episodes.prefix(WidgetSmartListLimits.maxItemsPerList).map {
      Episode(episode: $0.homeEpisode, isDownloaded: $0.isDownloaded)
    }
    matchCount = snapshot.matchCount
  }
}

/// The list file's half of a publication: what the extension draws, the list rows the token map
/// must resolve, and the covers configured lists would draw.
nonisolated struct WidgetSmartListPublication: Sendable, Equatable {
  let lists: WidgetSmartLists
  let selections: [String: WidgetTokenMap.ListSelection]
  let coverRequests: [WidgetCoverRequest]
}

/// Builds the list file from the lists, their read content and the player. Pure, like
/// `WidgetSnapshotAssembly`, whose row mapping, text rules and digests it shares.
nonisolated struct WidgetSmartListAssembly: Sendable {
  var accountStamp: WidgetAccountStamp
  var tokenSalt: String
  var lists: [WidgetSmartListName]
  var contents: [Int64: WidgetSmartListContent]
  /// Lists a placed widget shows, as last read from WidgetKit: they take the cover budget first.
  var shownListIDs: Set<Int64>
  var loaded: CompanionSelection?
  var isPlaying: Bool
  var generatedAt: Date
  var absArtworkSource: ArtworkSource?
  var coverPixelWidth: Int
  /// How many distinct cover files the lists may request, after the shelf's own.
  var coverBudget: Int
  var exportedCovers: Set<String>

  /// `nil` while a list's content has not been read yet: publishing then would draw a list as
  /// empty, so the previous file stays until every list is known.
  ///
  /// Every list gets covers while the budget lasts, shown lists first. WidgetKit's configurations
  /// are read only at launch and on foreground or background, so a list picked in Edit Widget
  /// while the app is running is not yet known to be shown; covering the others too means it
  /// draws with covers at once rather than after the app next comes forward.
  func makePublication() -> WidgetSmartListPublication? {
    struct PendingRow {
      let row: WidgetSnapshotAssembly.Row
      let token: String
    }
    let candidates = Array(lists.prefix(WidgetSmartListLimits.maxLists))
    var rowsByList: [Int64: [PendingRow]] = [:]
    for list in candidates {
      guard let content = contents[list.id] else { return nil }
      // A list whose name cannot be drawn is not published, so it requests no covers either.
      guard WidgetSnapshotAssembly.drawableText(list.name) != nil else { continue }
      rowsByList[list.id] = content.episodes.prefix(WidgetSmartListLimits.maxItemsPerList).compactMap { entry in
        guard
          let row = WidgetSnapshotAssembly.row(
            episode: entry.episode, isDownloaded: entry.isDownloaded,
            absArtworkSource: absArtworkSource, coverPixelWidth: coverPixelWidth),
          row.selection.episodeID != nil
        else { return nil }
        return PendingRow(row: row, token: Self.token(listID: list.id, selection: row.selection, salt: tokenSalt))
      }
    }

    var coverRequests: [WidgetCoverRequest] = []
    var drawnCovers: [String: String] = [:]
    let coverOrder =
      candidates.filter { shownListIDs.contains($0.id) } + candidates.filter { !shownListIDs.contains($0.id) }
    for list in coverOrder {
      for pending in rowsByList[list.id] ?? [] {
        guard let key = pending.row.cover else { continue }
        let fileName = WidgetSnapshotAssembly.coverFileName(for: key, salt: tokenSalt)
        if !coverRequests.contains(where: { $0.fileName == fileName }) {
          guard coverRequests.count < coverBudget else { continue }
          coverRequests.append(WidgetCoverRequest(fileName: fileName, key: key))
        }
        if exportedCovers.contains(fileName) { drawnCovers[pending.token] = fileName }
      }
    }

    var selections: [String: WidgetTokenMap.ListSelection] = [:]
    var published: [WidgetSmartList] = []
    for list in candidates {
      guard let name = WidgetSnapshotAssembly.drawableText(list.name), let content = contents[list.id] else {
        continue
      }
      var items: [WidgetItem] = []
      var loadedToken: String?
      for pending in rowsByList[list.id] ?? [] {
        guard
          let item = WidgetSnapshotAssembly.item(
            pending.row, token: pending.token, coverFileName: drawnCovers[pending.token])
        else { continue }
        items.append(item)
        selections[pending.token] = WidgetTokenMap.ListSelection(listID: list.id, selection: pending.row.selection)
        if pending.row.selection == loaded { loadedToken = pending.token }
      }
      let matchCount = content.matchCount.map { max($0, items.count) }
      guard
        let value = try? WidgetSmartList(
          id: list.id, name: name, matchCount: matchCount, items: items, loadedToken: loadedToken)
      else { continue }
      published.append(value)
    }
    guard
      let file = try? WidgetSmartLists(
        generatedAt: generatedAt, accountStamp: accountStamp, isPlaying: isPlaying, lists: published)
    else { return nil }
    return WidgetSmartListPublication(lists: file, selections: selections, coverRequests: coverRequests)
  }

  /// Distinct from a shelf row's token for the same episode, because a list row's map entry also
  /// names its list.
  static func token(listID: Int64, selection: CompanionSelection, salt: String) -> String {
    WidgetSnapshotAssembly.digest([
      "list-token", salt, WidgetSmartListID.string(listID), selection.itemID, selection.episodeID ?? "",
    ])
  }
}

/// Where the publisher reads smart lists. The production source wraps `SmartListServices`; a test
/// supplies lists and content directly.
protocol WidgetSmartListSource: Sendable {
  func observeLists() -> AsyncStream<[WidgetSmartListName]>
  func observeContent(listID: Int64, nativeEnabled: Bool) -> AsyncStream<WidgetSmartListContent>
  /// `nil` when the read failed; the list keeps its previous content.
  func fetchContent(listID: Int64, nativeEnabled: Bool) async -> WidgetSmartListContent?
}

nonisolated struct SmartListServicesWidgetSource: WidgetSmartListSource {
  let services: SmartListServices

  func observeLists() -> AsyncStream<[WidgetSmartListName]> {
    let lists = services.store.observeLists()
    return AsyncStream { continuation in
      let task = Task {
        for await value in lists {
          continuation.yield(value.map { WidgetSmartListName(id: $0.id, name: $0.name) })
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func observeContent(listID: Int64, nativeEnabled: Bool) -> AsyncStream<WidgetSmartListContent> {
    let snapshots = services.makeReading(nativeEnabled).observeEpisodes(
      listID: listID, limit: WidgetSmartListLimits.maxItemsPerList)
    return AsyncStream { continuation in
      let task = Task {
        var last: WidgetSmartListContent?
        for await snapshot in snapshots {
          let content = WidgetSmartListContent(snapshot)
          // The reading re-emits on progress writes; only a change to what is drawn passes.
          guard content != last else { continue }
          last = content
          continuation.yield(content)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func fetchContent(listID: Int64, nativeEnabled: Bool) async -> WidgetSmartListContent? {
    guard
      let snapshot = try? await services.makeReading(nativeEnabled).fetchSnapshot(
        listID: listID, limit: WidgetSmartListLimits.maxItemsPerList)
    else { return nil }
    return WidgetSmartListContent(snapshot)
  }
}
