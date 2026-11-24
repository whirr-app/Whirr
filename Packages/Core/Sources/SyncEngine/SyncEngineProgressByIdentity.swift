import ABSApi
import Foundation
import Persistence

struct ProgressByIdentity {
  var itemByID: [String: MediaProgress] = [:]
  var episodeByShowID: [String: [String: MediaProgress]] = [:]
  var rows: [MediaProgress] = []
  /// Every row id per identity, duplicates included, for reset evidence.
  var itemRowIDs: [String: [String?]] = [:]
  var episodeRowIDsByShowID: [String: [String: [String?]]] = [:]
  /// True only for a snapshot fetched in this run with every row decoded. The empty value a
  /// failed or backed-off fetch returns is never complete, so absence proves nothing.
  let isComplete: Bool

  init(rows: [MediaProgress] = [], isComplete: Bool = false) {
    self.rows = rows
    self.isComplete = isComplete
    var itemCandidates: [String: [ProgressMergePolicy.DuplicateServerRow]] = [:]
    var episodeCandidates: [String: [String: [ProgressMergePolicy.DuplicateServerRow]]] = [:]
    for row in rows {
      let candidate = ProgressMergePolicy.DuplicateServerRow(row)
      if let episodeID = row.episodeID {
        episodeRowIDsByShowID[row.libraryItemID, default: [:]][episodeID, default: []].append(
          row.serverProgressID)
        episodeCandidates[row.libraryItemID, default: [:]][episodeID, default: []].append(candidate)
      } else {
        itemRowIDs[row.libraryItemID, default: []].append(row.serverProgressID)
        itemCandidates[row.libraryItemID, default: []].append(candidate)
      }
    }
    // The winner rule is `ProgressMergePolicy`'s, shared with the show-refresh path: duplicate
    // rows must not resolve by the order the server happened to send them in.
    let policy = ProgressMergePolicy()
    for (itemID, candidates) in itemCandidates {
      if let winner = policy.resolveDuplicateServerRows(candidates) {
        itemByID[itemID] = winner.row
      }
    }
    for (showID, byEpisode) in episodeCandidates {
      for (episodeID, candidates) in byEpisode {
        if let winner = policy.resolveDuplicateServerRows(candidates) {
          episodeByShowID[showID, default: [:]][episodeID] = winner.row
        }
      }
    }
  }
}
