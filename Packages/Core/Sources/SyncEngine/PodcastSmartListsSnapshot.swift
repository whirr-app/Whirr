import Foundation
import GRDB
import Persistence

/// The optional smart-lists section of a podcast backup.
///
/// Sits under snapshot version 1 as a key older builds ignore. It carries what a listener built:
/// each list's name, rules, show selections and hidden episodes, in position order. The run row and
/// download claims are device and playback state and never travel. A show is named by its portable
/// identity, never by a row id, so a list restores onto a device whose ids differ.
public struct PodcastSmartListsSnapshot: Codable, Sendable, Equatable {
  /// In position order.
  public let lists: [SmartListBackupSnapshot]

  public init(lists: [SmartListBackupSnapshot]) {
    self.lists = lists
  }

  /// A list this build cannot read (a rule value it does not know) is left out, so the other lists
  /// and the podcast state beside them still restore.
  public init(from decoder: any Decoder) throws {
    struct Lossy: Decodable {
      let list: SmartListBackupSnapshot?
      init(from decoder: any Decoder) throws { list = try? SmartListBackupSnapshot(from: decoder) }
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    lists = try container.decode([Lossy].self, forKey: .lists).compactMap(\.list)
  }
}

public struct SmartListBackupSnapshot: Codable, Sendable, Equatable {
  public let name: String
  public let rules: SmartListRules
  /// In the order they were chosen.
  public let shows: [SmartListShowBackupSnapshot]
  /// Ordered by source, then show, then episode, so the file does not depend on row order.
  public let hiddenEpisodes: [SmartListHiddenEpisodeBackupSnapshot]

  public init(
    name: String, rules: SmartListRules, shows: [SmartListShowBackupSnapshot],
    hiddenEpisodes: [SmartListHiddenEpisodeBackupSnapshot]
  ) {
    self.name = name
    self.rules = rules
    self.shows = shows
    self.hiddenEpisodes = hiddenEpisodes
  }
}

/// A native show carries `feedURL`; a server show carries `serverUserId` and `serverItemId`.
public struct SmartListShowBackupSnapshot: Codable, Sendable, Equatable {
  public let source: SmartListShowSource
  public let feedURL: String?
  public let serverUserId: String?
  public let serverItemId: String?
  public let role: SmartListShowRole
  public let titleSnapshot: String

  public init(
    source: SmartListShowSource, feedURL: String? = nil, serverUserId: String? = nil,
    serverItemId: String? = nil, role: SmartListShowRole, titleSnapshot: String
  ) {
    self.source = source
    self.feedURL = feedURL
    self.serverUserId = serverUserId
    self.serverItemId = serverItemId
    self.role = role
    self.titleSnapshot = titleSnapshot
  }
}

/// A native episode is named by its show's `feedURL` and its identity key (`episodeID`), because the
/// stored `rss:<feedId>` is a device-local row id. A server episode keeps its `itemID` and `episodeID`.
public struct SmartListHiddenEpisodeBackupSnapshot: Codable, Sendable, Equatable {
  public let source: SmartListShowSource
  public let feedURL: String?
  public let itemID: String?
  public let episodeID: String

  public init(source: SmartListShowSource, feedURL: String? = nil, itemID: String? = nil, episodeID: String) {
    self.source = source
    self.feedURL = feedURL
    self.itemID = itemID
    self.episodeID = episodeID
  }
}

public enum PodcastSmartListsSnapshotCodec {
  public static let maxLists = SmartListStore.maximumListCount
  public static let maxShowsPerList = 500
  public static let maxHiddenEpisodesPerList = 5_000

  public struct Export: Sendable, Equatable {
    /// Nil when the device has no list.
    public let snapshot: PodcastSmartListsSnapshot?
    /// Show rows left out: an address the file cannot carry (credentials, unusable scheme), a
    /// malformed server key, or past the per-list cap.
    public let showsDropped: Int
    /// Hidden episodes left out: their show is gone from the device, an address the file cannot
    /// carry, or past the per-list cap.
    public let hiddenEpisodesDropped: Int
  }

  public struct RestoreOutcome: Sendable, Equatable {
    public var listsAdded = 0
    /// A list whose name the device already has is left as it is.
    public var listsSkippedExisting = 0
    /// Past the 50-list cap.
    public var listsDroppedOverLimit = 0
    /// A name or rule set this build refuses.
    public var listsSkippedInvalid = 0
    public var showsRestored = 0
    /// Restored show rows whose show is not on this device: a native feed that is not followed
    /// ("Not followed") or a server show no account here has ("Not available on this server").
    /// The rows are kept.
    public var showsNotOnDevice = 0
    public var hiddenEpisodesRestored = 0
    /// Native hidden episodes whose feed is not followed on this device: with no `rss:<feedId>` to
    /// name, there is nothing to store.
    public var hiddenEpisodesDropped = 0

    public init() {}
  }

  // MARK: - Export

  /// The section for the device's lists. Native rows are written by their normalized feed address.
  public static func export(from database: AppDatabase) async throws -> Export {
    let lists = try await SmartListStore(database: database).lists()
    guard lists.isEmpty == false else { return Export(snapshot: nil, showsDropped: 0, hiddenEpisodesDropped: 0) }
    var addresses: [Int64: String] = [:]
    for feed in try await RSSFeedStore(database: database).fetchFeeds() {
      if let id = feed.id { addresses[id] = feed.feedURL }
    }
    let hiddenStore = SmartListHiddenEpisodeStore(database: database)
    let store = SmartListStore(database: database)
    var showsDropped = 0
    var hiddenDropped = 0
    var snapshots: [SmartListBackupSnapshot] = []
    for list in lists.prefix(maxLists) {
      var shows: [SmartListShowBackupSnapshot] = []
      for row in try await store.shows(listID: list.id) {
        guard let show = portable(show: row) else {
          showsDropped += 1
          continue
        }
        shows.append(show)
      }
      if shows.count > maxShowsPerList {
        showsDropped += shows.count - maxShowsPerList
        shows = Array(shows.prefix(maxShowsPerList))
      }
      var hidden: [SmartListHiddenEpisodeBackupSnapshot] = []
      for row in try await hiddenStore.hiddenEpisodes(listID: list.id) {
        guard let episode = portable(hidden: row, addresses: addresses) else {
          hiddenDropped += 1
          continue
        }
        hidden.append(episode)
      }
      hidden.sort(by: hiddenLess)
      if hidden.count > maxHiddenEpisodesPerList {
        hiddenDropped += hidden.count - maxHiddenEpisodesPerList
        hidden = Array(hidden.prefix(maxHiddenEpisodesPerList))
      }
      snapshots.append(
        SmartListBackupSnapshot(name: list.name, rules: list.rules, shows: shows, hiddenEpisodes: hidden))
    }
    return Export(
      snapshot: PodcastSmartListsSnapshot(lists: snapshots), showsDropped: showsDropped,
      hiddenEpisodesDropped: hiddenDropped)
  }

  private static func portable(show row: SmartListShowRecord) -> SmartListShowBackupSnapshot? {
    guard row.titleSnapshot.utf8.count <= PodcastStateSnapshotCodec.maxStringBytes else { return nil }
    switch row.source {
    case .native:
      guard let address = portableAddress(row.showKey) else { return nil }
      return SmartListShowBackupSnapshot(
        source: .native, feedURL: address, role: row.role, titleSnapshot: row.titleSnapshot)
    case .server:
      guard let (user, item) = splitServerKey(row.showKey) else { return nil }
      return SmartListShowBackupSnapshot(
        source: .server, serverUserId: user, serverItemId: item, role: row.role,
        titleSnapshot: row.titleSnapshot)
    }
  }

  private static func portable(hidden row: SmartListHiddenEpisodeRecord, addresses: [Int64: String])
    -> SmartListHiddenEpisodeBackupSnapshot?
  {
    guard row.episodeID.isEmpty == false, row.episodeID.utf8.count <= PodcastStateSnapshotCodec.maxStringBytes,
      row.itemID.utf8.count <= PodcastStateSnapshotCodec.maxStringBytes
    else { return nil }
    if PodcastSourceIdentity.hasReservedPrefix(row.itemID) {
      guard let feedID = nativeFeedID(row.itemID), let stored = addresses[feedID],
        let address = portableAddress(stored)
      else { return nil }
      return SmartListHiddenEpisodeBackupSnapshot(source: .native, feedURL: address, episodeID: row.episodeID)
    }
    guard row.itemID.isEmpty == false else { return nil }
    return SmartListHiddenEpisodeBackupSnapshot(source: .server, itemID: row.itemID, episodeID: row.episodeID)
  }

  // MARK: - Restore

  /// Adds the file's lists after the device's own. A list whose name the device already has is
  /// left alone, so restoring twice adds nothing; lists past the cap are counted and dropped. A show
  /// row whose show is not on the device is kept. Native hidden episodes are re-pointed at the
  /// device's own feed rows, and dropped when the feed is not followed.
  public static func restore(_ section: PodcastSmartListsSnapshot?, into database: AppDatabase) async throws
    -> RestoreOutcome
  {
    var outcome = RestoreOutcome()
    guard let section else { return outcome }
    let store = SmartListStore(database: database)
    let hiddenStore = SmartListHiddenEpisodeStore(database: database)

    var storedByAddress: [String: (id: Int64, stored: String)] = [:]
    for feed in try await RSSFeedStore(database: database).fetchFeeds().sorted(by: { ($0.id ?? 0) > ($1.id ?? 0) }) {
      guard let id = feed.id else { continue }
      storedByAddress[PodcastCloudIdentity.normalizedFeedURL(feed.feedURL) ?? feed.feedURL] = (id, feed.feedURL)
      storedByAddress[feed.feedURL] = (id, feed.feedURL)
    }
    let serverKeys = Set(
      try await database.readAsync { db in
        try String.fetchAll(
          db,
          sql: """
            SELECT account.serverUserId || '|' || item.serverItemId
            FROM item JOIN account ON account.id = item.accountId
            WHERE item.mediaKind = 'podcast' AND item.softDeleted = 0
            """)
      })

    var names = Set(try await store.lists().map { $0.name.lowercased() })
    for list in section.lists {
      guard let name = SmartListRules.normalizedName(list.name), (try? list.rules.validate()) != nil else {
        outcome.listsSkippedInvalid += 1
        continue
      }
      guard names.contains(name.lowercased()) == false else {
        outcome.listsSkippedExisting += 1
        continue
      }
      var selections: [SmartListShowSelection] = []
      var seen: Set<SmartListShowRef> = []
      var absent = 0
      for show in list.shows {
        guard let ref = reference(for: show, storedByAddress: storedByAddress) else { continue }
        guard seen.insert(ref).inserted else { continue }
        let present: Bool
        switch ref.source {
        case .native: present = storedByAddress[show.feedURL ?? ""] != nil
        case .server: present = serverKeys.contains(ref.showKey)
        }
        if present == false { absent += 1 }
        selections.append(SmartListShowSelection(ref: ref, role: show.role, titleSnapshot: show.titleSnapshot))
      }
      let created: SmartList
      do {
        created = try await store.create(name: name, rules: list.rules, shows: selections)
      } catch SmartListStoreError.listLimitReached {
        outcome.listsDroppedOverLimit += 1
        continue
      } catch {
        outcome.listsSkippedInvalid += 1
        continue
      }
      names.insert(name.lowercased())
      outcome.listsAdded += 1
      outcome.showsRestored += selections.count
      outcome.showsNotOnDevice += absent
      for episode in list.hiddenEpisodes {
        switch episode.source {
        case .native:
          guard let address = episode.feedURL, let feed = storedByAddress[address] else {
            outcome.hiddenEpisodesDropped += 1
            continue
          }
          try await hiddenStore.hide(listID: created.id, itemID: "rss:\(feed.id)", episodeID: episode.episodeID)
        case .server:
          guard let itemID = episode.itemID else {
            outcome.hiddenEpisodesDropped += 1
            continue
          }
          try await hiddenStore.hide(listID: created.id, itemID: itemID, episodeID: episode.episodeID)
        }
        outcome.hiddenEpisodesRestored += 1
      }
    }
    return outcome
  }

  private static func reference(
    for show: SmartListShowBackupSnapshot, storedByAddress: [String: (id: Int64, stored: String)]
  ) -> SmartListShowRef? {
    switch show.source {
    case .native:
      guard let address = show.feedURL else { return nil }
      return .native(feedURL: storedByAddress[address]?.stored ?? address)
    case .server:
      guard let user = show.serverUserId, let item = show.serverItemId else { return nil }
      return .server(serverUserID: user, serverItemID: item)
    }
  }

  // MARK: - Validation

  static func validate(_ section: PodcastSmartListsSnapshot) throws {
    guard section.lists.count <= maxLists else { throw PodcastStateSnapshotCodecError.invalidValue }
    for list in section.lists {
      guard list.name.utf8.count <= SmartListRules.maximumNameLength * 4, list.shows.count <= maxShowsPerList,
        list.hiddenEpisodes.count <= maxHiddenEpisodesPerList
      else { throw PodcastStateSnapshotCodecError.invalidValue }
      for show in list.shows {
        guard show.titleSnapshot.utf8.count <= PodcastStateSnapshotCodec.maxStringBytes else {
          throw PodcastStateSnapshotCodecError.oversizedString
        }
        switch show.source {
        case .native:
          guard let address = show.feedURL, show.serverUserId == nil, show.serverItemId == nil else {
            throw PodcastStateSnapshotCodecError.invalidValue
          }
          try checkAddress(address)
        case .server:
          guard show.feedURL == nil, let user = show.serverUserId, let item = show.serverItemId,
            user.isEmpty == false, item.isEmpty == false, user.contains("|") == false
          else { throw PodcastStateSnapshotCodecError.invalidValue }
          guard user.utf8.count <= PodcastStateSnapshotCodec.maxStringBytes,
            item.utf8.count <= PodcastStateSnapshotCodec.maxStringBytes
          else { throw PodcastStateSnapshotCodecError.oversizedString }
        }
      }
      for episode in list.hiddenEpisodes {
        guard episode.episodeID.isEmpty == false else { throw PodcastStateSnapshotCodecError.invalidValue }
        guard episode.episodeID.utf8.count <= PodcastStateSnapshotCodec.maxStringBytes,
          (episode.itemID?.utf8.count ?? 0) <= PodcastStateSnapshotCodec.maxStringBytes
        else { throw PodcastStateSnapshotCodecError.oversizedString }
        switch episode.source {
        case .native:
          guard let address = episode.feedURL, episode.itemID == nil else {
            throw PodcastStateSnapshotCodecError.invalidValue
          }
          try checkAddress(address)
        case .server:
          guard episode.feedURL == nil, let item = episode.itemID, item.isEmpty == false else {
            throw PodcastStateSnapshotCodecError.invalidValue
          }
        }
      }
    }
  }

  private static func checkAddress(_ address: String) throws {
    guard address.utf8.count <= PodcastStateSnapshotCodec.maxStringBytes else {
      throw PodcastStateSnapshotCodecError.oversizedString
    }
    guard let url = URLComponents(string: address), let scheme = url.scheme?.lowercased(),
      ["https", "http"].contains(scheme), !(url.host ?? "").isEmpty
    else { throw PodcastStateSnapshotCodecError.invalidValue }
    guard url.user == nil, url.password == nil else { throw PodcastStateSnapshotCodecError.credentialedURL }
  }

  // MARK: - Helpers

  /// The normalized address when it has one, else the stored string, if the file can carry it.
  private static func portableAddress(_ stored: String) -> String? {
    let address = PodcastCloudIdentity.normalizedFeedURL(stored) ?? stored
    return (try? checkAddress(address)) == nil ? nil : address
  }

  /// `"<serverUserId>|<serverItemId>"`, split at the first bar.
  private static func splitServerKey(_ key: String) -> (String, String)? {
    guard let bar = key.firstIndex(of: "|") else { return nil }
    let user = String(key[..<bar])
    let item = String(key[key.index(after: bar)...])
    guard user.isEmpty == false, item.isEmpty == false,
      user.utf8.count <= PodcastStateSnapshotCodec.maxStringBytes,
      item.utf8.count <= PodcastStateSnapshotCodec.maxStringBytes
    else { return nil }
    return (user, item)
  }

  private static func nativeFeedID(_ itemID: String) -> Int64? {
    guard case .rss(let feedID)? = PodcastSourceIdentity(itemId: itemID)?.source else { return nil }
    return feedID
  }

  private static func hiddenLess(
    _ lhs: SmartListHiddenEpisodeBackupSnapshot, _ rhs: SmartListHiddenEpisodeBackupSnapshot
  ) -> Bool {
    func sortKey(_ value: SmartListHiddenEpisodeBackupSnapshot) -> [String] {
      [value.source.rawValue, value.feedURL ?? value.itemID ?? "", value.episodeID]
    }
    let (left, right) = (sortKey(lhs), sortKey(rhs))
    for (a, b) in zip(left, right) where a != b { return a.utf8.lexicographicallyPrecedes(b.utf8) }
    return false
  }
}
