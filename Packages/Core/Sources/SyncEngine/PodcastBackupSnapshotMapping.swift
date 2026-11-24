import Foundation
import Persistence

/// Maps the native backup contents to the portable snapshot a `.whirrpodcasts.json` file carries.
///
/// A device that has never synced has no accepted stamps and no record-name key, so every stamp
/// here is a seed stamp dated by the entity's own date. Restore does not order by these stamps
/// (it is a fill-in restore); they exist so the file satisfies the same codec as cloud records.
public enum PodcastBackupSnapshotMapping {
  public struct Result: Sendable, Equatable {
    public let snapshot: PodcastStateSnapshot
    /// Followed shows the file cannot carry: an address with no valid normalized form, one that
    /// embeds credentials, or a second address that normalizes to the same show.
    public let skippedFeeds: Int
    /// Episodes whose identity is too large for the file, or whose show was skipped.
    public let skippedEpisodes: Int
    /// Learned ads written without their audio print, and ones left out, to keep the file inside
    /// its size limit.
    public var learnedAdsWithoutPrint = 0
    public var learnedAdsDropped = 0
  }

  static let maxTitleBytes = 4096

  public static func snapshot(
    from contents: NativePodcastBackupContents, exportedAt: Date, appBuild: String? = nil,
    learnedAdPrintFormat: String = "", learnedAdByteBudget: Int = PodcastLearnedAdsSnapshotCodec.sectionByteBudget,
    smartLists: PodcastSmartListsSnapshot? = nil
  ) throws -> Result {
    var subscriptions: [SubscriptionSnapshot] = []
    var parents: [String: (uuid: UUID, generation: UUID)] = [:]
    var skippedFeeds = 0

    for feed in contents.feeds {
      guard let normalized = PodcastCloudIdentity.normalizedFeedURL(feed.feedURL),
        let uuid = PodcastCloudIdentity.subscriptionUUID(feedURL: normalized),
        portableURL(normalized) != nil,
        parents[normalized] == nil
      else {
        skippedFeeds += 1
        continue
      }
      let key = uuid.uuidString.lowercased()
      let generation =
        contents.followedGenerations[key].flatMap(UUID.init(uuidString:))
        ?? PodcastCloudIdentity.initialGenerationUUID(subscriptionUUID: uuid)
      parents[normalized] = (uuid, generation)
      parents[feed.feedURL] = (uuid, generation)

      let followStamp = try stamp(at: feed.subscribedAt, "sub", [key], "followed")
      subscriptions.append(
        SubscriptionSnapshot(
          subscriptionUUID: uuid, normalizedURL: normalized,
          title: clipped(feed.title ?? normalized), author: feed.author.map(clipped),
          subscribedAt: feed.subscribedAt,
          lifecycle: PodcastCloudFollowRegister(
            subscriptionUUID: uuid, generationUUID: generation, isFollowed: true, stamp: followStamp),
          feedSettings: try feed.settings.map { settings in
            FeedSettingsSnapshot(
              autoDownload: settings.autoDownload, keepLatest: settings.keepLatest,
              deleteAfterPlayed: settings.deleteAfterPlayed, rateStep: settings.rateStep,
              includeInLatest: settings.includeInLatest, notificationOverride: settings.notificationOverride,
              trimSilencesOverride: settings.trimSilencesOverride, voiceBoostOverride: settings.voiceBoostOverride,
              stamp: try stamp(at: feed.subscribedAt, "settings", [key], "settings"))
          },
          customOrder: try feed.customSortIndex.map {
            StampedCustomOrder(value: $0, stamp: try stamp(at: feed.subscribedAt, "order", [key], "\($0)"))
          }))
    }

    var identities: [EpisodeIdentitySnapshot] = []
    var episodes: [EpisodeSnapshot] = []
    var references: Set<String> = []
    var skippedEpisodes = 0

    for episode in contents.episodes {
      guard let parent = parents[episode.feedURL],
        episode.identityKey.isEmpty == false,
        episode.identityKey.utf8.count <= PodcastStateSnapshotCodec.maxStringBytes,
        (episode.alternateIdentityKey?.utf8.count ?? 0) <= PodcastStateSnapshotCodec.maxStringBytes,
        (episode.guid?.utf8.count ?? 0) <= PodcastStateSnapshotCodec.maxStringBytes
      else {
        skippedEpisodes += 1
        continue
      }
      let digest = PodcastCloudIdentity.episodeDigest(identityKey: episode.identityKey)
      let components = [parent.uuid.uuidString.lowercased(), parent.generation.uuidString.lowercased(), digest]
      guard references.insert(components.joined(separator: "|")).inserted else {
        skippedEpisodes += 1
        continue
      }
      let alternate = episode.alternateIdentityKey.flatMap {
        $0.isEmpty || $0 == episode.identityKey ? nil : $0
      }
      let enclosure = episode.enclosureURL.flatMap(portableURL)

      identities.append(
        EpisodeIdentitySnapshot(
          subscriptionUUID: parent.uuid, generationUUID: parent.generation, digest: digest,
          representativeDigest: digest, aliases: [episode.identityKey] + (alternate.map { [$0] } ?? []),
          guid: episode.guid, enclosureURL: enclosure))

      let state = try episode.state.map { state -> EpisodeStateSnapshot in
        let value = "\(state.position)|\(state.finished)|\(state.dismissed)"
        let written = try stamp(at: state.updatedAt, "state", components, value)
        return EpisodeStateSnapshot(
          state: try PodcastCloudEpisodeState(
            position: state.position, isFinished: state.finished, isDismissed: state.dismissed,
            explicitEpoch: state.finished || state.dismissed ? written : .bottom, writeStamp: written),
          updatedAt: state.updatedAt)
      }
      let saved = try episode.savedAt.map { savedAt in
        try PodcastCloudSavedRegister(
          isSaved: true, savedAt: savedAt, stamp: try stamp(at: savedAt, "saved", components, "saved"))
      }
      episodes.append(
        EpisodeSnapshot(
          subscriptionUUID: parent.uuid, generationUUID: parent.generation, representativeDigest: digest,
          identityKey: episode.identityKey, alternateIdentityKey: alternate, guid: episode.guid,
          enclosureURL: enclosure, title: clipped(episode.title ?? ""), publishedAt: episode.publishedAt,
          duration: episode.duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }, state: state, saved: saved,
          resolution: .resolved))
    }

    var lastPlayed: StampedBookmark?
    if let bookmark = contents.bookmark, let parent = parents[bookmark.feedURL] {
      let digest = PodcastCloudIdentity.episodeDigest(identityKey: bookmark.identityKey)
      let components = [parent.uuid.uuidString.lowercased(), parent.generation.uuidString.lowercased(), digest]
      if references.contains(components.joined(separator: "|")) {
        lastPlayed = StampedBookmark(
          reference: EpisodeReference(
            subscriptionUUID: parent.uuid, generationUUID: parent.generation, representativeDigest: digest),
          writeStamp: try stamp(at: bookmark.updatedAt, "bookmark", components, "bookmark"))
      }
    }

    let learnedAds = PodcastLearnedAdsSnapshotCodec.section(
      from: contents.learnedAds, printFormat: learnedAdPrintFormat, parents: parents.mapValues(\.uuid),
      byteBudget: learnedAdByteBudget)
    let globals = contents.globalSettings
    let snapshot = PodcastStateSnapshot(
      exportedAt: exportedAt, appBuild: appBuild,
      globalSettings: StampedGlobalSettings(
        autoDownloadEnabled: globals.autoDownloadEnabled, keepLatestCount: globals.keepLatestCount,
        deleteAfterPlayed: globals.deleteAfterPlayed, allowCellularAutoDownload: globals.allowCellularAutoDownload,
        enabledAt: globals.enabledAt, showOrderMode: contents.showOrderMode,
        writeStamp: try stamp(at: globals.enabledAt, "globals", [], contents.showOrderMode)),
      subscriptions: subscriptions, lastPlayed: lastPlayed, episodeIdentities: identities, episodes: episodes,
      learnedAds: learnedAds.snapshot, smartLists: smartLists)
    try PodcastStateSnapshotCodec.validate(snapshot)
    return Result(
      snapshot: snapshot, skippedFeeds: skippedFeeds, skippedEpisodes: skippedEpisodes,
      learnedAdsWithoutPrint: learnedAds.adsWithoutPrint, learnedAdsDropped: learnedAds.adsDropped)
  }

  /// The restore writer's input. A lifecycle that is not followed is left out: fill-in restore
  /// follows every show it is given.
  public static func contents(
    from snapshot: PodcastStateSnapshot, learnedAdPrintFormat: String = ""
  ) -> NativePodcastBackupContents {
    let followed = snapshot.subscriptions.filter(\.lifecycle.isFollowed)
    let addresses = Dictionary(
      uniqueKeysWithValues: followed.map { ($0.subscriptionUUID, ($0.normalizedURL, $0.lifecycle.generationUUID)) })

    let feeds = followed.map { subscription in
      NativePodcastBackupContents.Feed(
        feedURL: subscription.normalizedURL, title: subscription.title, author: subscription.author,
        subscribedAt: subscription.subscribedAt ?? snapshot.exportedAt,
        customSortIndex: subscription.customOrder?.value,
        settings: subscription.feedSettings.map { settings in
          NativePodcastBackupContents.FeedSettings(
            autoDownload: settings.autoDownload, keepLatest: settings.keepLatest,
            deleteAfterPlayed: settings.deleteAfterPlayed, rateStep: settings.rateStep,
            includeInLatest: settings.includeInLatest, notificationOverride: settings.notificationOverride,
            trimSilencesOverride: settings.trimSilencesOverride ?? TrimSilencesShowOverride.inherit.rawValue,
            voiceBoostOverride: settings.voiceBoostOverride ?? VoiceBoostShowOverride.inherit.rawValue)
        })
    }

    let bookmarked = snapshot.lastPlayed?.reference.map {
      key($0.subscriptionUUID, $0.generationUUID, $0.representativeDigest)
    }
    var identityKeys: [String: String] = [:]
    var episodes: [NativePodcastBackupContents.Episode] = []
    for episode in snapshot.episodes {
      guard let (address, generation) = addresses[episode.subscriptionUUID], generation == episode.generationUUID
      else { continue }
      let reference = key(episode.subscriptionUUID, episode.generationUUID, episode.representativeDigest)
      identityKeys[reference] = episode.identityKey
      let saved = episode.saved?.isSaved == true ? episode.saved?.savedAt : nil
      // A removal marker alone asks restore for nothing: restore never removes a save.
      guard episode.state != nil || saved != nil || reference == bookmarked else { continue }
      episodes.append(
        NativePodcastBackupContents.Episode(
          feedURL: address, identityKey: episode.identityKey, alternateIdentityKey: episode.alternateIdentityKey,
          guid: episode.guid, enclosureURL: episode.enclosureURL, title: episode.title,
          publishedAt: episode.publishedAt, duration: episode.duration,
          state: episode.state.map { state in
            NativePodcastBackupContents.EpisodeState(
              position: state.state.position, finished: state.state.isFinished, dismissed: state.state.isDismissed,
              updatedAt: state.updatedAt)
          },
          savedAt: saved))
    }

    var bookmark: NativePodcastBackupContents.Bookmark?
    if let lastPlayed = snapshot.lastPlayed, let reference = lastPlayed.reference,
      let (address, _) = addresses[reference.subscriptionUUID],
      let identityKey = identityKeys[
        key(reference.subscriptionUUID, reference.generationUUID, reference.representativeDigest)]
    {
      bookmark = NativePodcastBackupContents.Bookmark(
        feedURL: address, identityKey: identityKey,
        updatedAt: Date(timeIntervalSince1970: Double(lastPlayed.writeStamp.physicalMilliseconds) / 1000))
    }

    let globals = snapshot.globalSettings
    return NativePodcastBackupContents(
      globalSettings: NativePodcastSettingsRecord(
        autoDownloadEnabled: globals.autoDownloadEnabled, keepLatestCount: globals.keepLatestCount,
        deleteAfterPlayed: globals.deleteAfterPlayed, allowCellularAutoDownload: globals.allowCellularAutoDownload,
        enabledAt: globals.enabledAt),
      showOrderMode: globals.showOrderMode, feeds: feeds, episodes: episodes, bookmark: bookmark,
      followedGenerations: [:],
      learnedAds: snapshot.learnedAds.map {
        PodcastLearnedAdsSnapshotCodec.learnedAds(
          from: $0, printFormat: learnedAdPrintFormat, addresses: addresses.mapValues(\.0))
      } ?? [])
  }

  private static func key(_ subscription: UUID, _ generation: UUID, _ digest: String) -> String {
    "\(subscription.uuidString)|\(generation.uuidString)|\(digest)"
  }

  /// A seed stamp keyed by an unkeyed backup name: the file must be writable without CloudKit.
  private static func stamp(at date: Date?, _ kind: String, _ components: [String], _ value: String) throws
    -> PodcastCloudMutationStamp
  {
    try PodcastCloudLocalReconciler.seedStamp(
      at: date, recordName: (["backup", kind] + components).joined(separator: "."), value: value)
  }

  /// An enclosure the file can carry. One with embedded credentials or an unusable scheme is left
  /// out rather than failing the backup; the episode still matches by its identity keys.
  private static func portableURL(_ value: String) -> String? {
    guard value.utf8.count <= PodcastStateSnapshotCodec.maxStringBytes,
      let url = URLComponents(string: value), let scheme = url.scheme?.lowercased(),
      ["https", "http"].contains(scheme), !(url.host ?? "").isEmpty, url.user == nil, url.password == nil
    else { return nil }
    return value
  }

  /// Titles are descriptive only, so an oversized one is cut at a character boundary rather than
  /// failing the backup.
  private static func clipped(_ value: String) -> String {
    guard value.utf8.count > maxTitleBytes else { return value }
    var result = ""
    for character in value {
      guard result.utf8.count + character.utf8.count <= maxTitleBytes else { break }
      result.append(character)
    }
    return result
  }
}
