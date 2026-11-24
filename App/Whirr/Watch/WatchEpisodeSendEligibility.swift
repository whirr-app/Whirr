import ABSApi
import WatchProtocol

/// Whether one native-RSS episode can be named on the episode-send wire at all.
///
/// A selection's feed and episode identifiers share one rule (`WatchSelection.validate`), so an
/// episode whose identity key is malformed or longer than
/// `WatchProtocolVersion.maxMetadataStringBytes` can never appear in an offer. The publisher skips
/// such a row; the episode menus use the same answer to hide the Watch actions rather than offer
/// one that cannot work.
enum WatchEpisodeSendEligibility {
  /// The wire selection for one episode row, or `nil` when the wire rejects its identifiers.
  /// A feed id is a positive `rssFeed` row id, so a non-positive value is never a real feed.
  static func selection(feedId: Int64, identityKey: String) -> WatchNativeSelection? {
    guard feedId > 0 else { return nil }
    return try? WatchNativeSelection(feedID: String(feedId), episodeID: identityKey)
  }

  /// ADR 0006's save-path rule, applied to the Watch wire: a feed with a device-held credential is
  /// private, and a private feed's episodes are never offered, so no feed credential or
  /// credential-bearing URL reaches the Watch (ADR 0020 Decision 2).
  ///
  /// A store that cannot answer counts as private. The wire fails closed: an unreadable credential
  /// is indistinguishable from a held one, and offering the URL is the mistake that cannot be
  /// undone. Nonisolated because the callers read the Keychain off the main actor; the store is
  /// `Sendable`.
  nonisolated static func isPrivateFeed(
    feedId: Int64, credentialStore: (any FeedCredentialStoring)?
  ) -> Bool {
    guard feedId > 0, let credentialStore else { return true }
    do {
      return try credentialStore.load(forFeedID: feedId) != nil
    } catch {
      return true
    }
  }
}
