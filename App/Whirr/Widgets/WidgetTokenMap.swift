import AppModel
import Foundation
import Persistence
import WidgetProtocol

/// Resolves a widget row's opaque token back to the title it names. It lives in the
/// app's own container, never the App Group, so no server identifier is readable by the
/// extension, Siri, or an intent's parameters. The publisher rewrites it with every snapshot, and
/// an intent that cold-launches the app reads it before any publisher has run.
nonisolated struct WidgetTokenMap: Codable, Sendable, Equatable {
  /// Version 2 added `listID`. A version 1 file is not read, so the first publication after the
  /// upgrade writes a new one; until then a tap or play resolves to nothing, as for a stale token.
  static let currentVersion = 2
  /// Eight shelf rows and at most 200 list rows, each a short identifier pair; anything larger is
  /// not this file.
  static let maxEncodedBytes = 64 * 1024

  struct Entry: Codable, Sendable, Equatable {
    let itemID: String
    let episodeID: String?
    /// The smart list a list row belongs to; `nil` for a shelf row.
    var listID: Int64? = nil
  }

  /// A list row: the episode, and the list whose run its play button starts.
  struct ListSelection: Sendable, Equatable {
    let listID: Int64
    let selection: CompanionSelection
  }

  let version: Int
  let accountIdentityHash: String
  let serverIdentityHash: String
  /// The salt the tokens were derived with, kept so a relaunch for the same account reuses it
  /// and an unchanged shelf rewrites nothing.
  let salt: String
  let entries: [String: Entry]

  init(
    stamp: WidgetAccountStamp, salt: String, selections: [String: CompanionSelection],
    listSelections: [String: ListSelection] = [:]
  ) {
    version = Self.currentVersion
    accountIdentityHash = stamp.accountIdentityHash
    serverIdentityHash = stamp.serverIdentityHash
    self.salt = salt
    var entries = selections.mapValues { Entry(itemID: $0.itemID, episodeID: $0.episodeID) }
    for (token, row) in listSelections {
      entries[token] = Entry(
        itemID: row.selection.itemID, episodeID: row.selection.episodeID, listID: row.listID)
    }
    self.entries = entries
  }

  func belongs(to stamp: WidgetAccountStamp) -> Bool {
    accountIdentityHash == stamp.accountIdentityHash && serverIdentityHash == stamp.serverIdentityHash
  }

  /// A shelf row's title. A list row's token is not one: its play button starts a run, which a
  /// shelf's does not.
  func selection(for token: String) -> CompanionSelection? {
    guard let entry = entries[token], entry.listID == nil else { return nil }
    return Self.selection(entry)
  }

  /// A list row's episode and list; `nil` for a shelf row's token.
  func listSelection(for token: String) -> ListSelection? {
    guard let entry = entries[token], let listID = entry.listID, let selection = Self.selection(entry),
      selection.episodeID != nil
    else { return nil }
    return ListSelection(listID: listID, selection: selection)
  }

  /// Every list row's entry, so a relaunch keeps resolving the rows the extension still draws.
  var listSelections: [String: ListSelection] {
    entries.keys.reduce(into: [:]) { result, token in
      if let row = listSelection(for: token) { result[token] = row }
    }
  }

  private static func selection(_ entry: Entry) -> CompanionSelection? {
    guard let source = PodcastSourceIdentity(itemId: entry.itemID) else { return nil }
    return CompanionSelection(source: source, episodeID: entry.episodeID)
  }

  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(self)
  }

  static func decode(_ data: Data) -> WidgetTokenMap? {
    guard data.count <= maxEncodedBytes,
      let map = try? JSONDecoder().decode(WidgetTokenMap.self, from: data),
      map.version == currentVersion
    else { return nil }
    return map
  }
}
