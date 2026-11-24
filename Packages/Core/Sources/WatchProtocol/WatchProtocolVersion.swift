import Foundation

enum WatchProtocolValidation {
  static func containsControlCharacter(_ value: String) -> Bool {
    value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
}

/// The integer wire format version understood by this target. After enforcing the byte limit,
/// `WatchWireCodec.decode` rejects a differing top-level version before decoding the full value.
/// Values without a version key proceed directly to full decoding and validation.
public enum WatchProtocolVersion {
  public static let current = 1
  public static let maxMetadataStringBytes = 512
  public static let maxRows = 100
  public static let maxSnapshotBytes = 60 * 1024
  public static let maxCommandBytes = 8 * 1024
  public static let minimumPlaybackRate = 0.25
  public static let maximumPlaybackRate = 4.0
  public static let commandAdmissionWindow: TimeInterval = WatchSetupLimits.window
  public static let commandFutureSkewTolerance: TimeInterval = 30
}

public enum WatchTransportKey {
  public static let payload = "whirr.watch.payload"
  public static let artworkRequest = "whirr.watch.artwork.request.v1"
  public static let artworkReply = "whirr.watch.artwork.reply.v1"
  public static let browseRequest = "whirr.watch.browse.request"
  public static let browseReply = "whirr.watch.browse.reply"
  public static let setupHello = "whirr.watch.setup.hello.v1"
  /// A read-only provisioning probe. It carries a `WatchSetupHello` and is answered with a
  /// `WatchSetupChallenge`, but never starts, replaces or expires a setup attempt.
  public static let setupStatus = "whirr.watch.setup.status.v1"
  public static let setupCredentials = "whirr.watch.setup.credentials.v1"
  public static let pendingProgressReport = "whirr.watch.pending-progress.report.v1"
  public static let pendingProgressQuery = "whirr.watch.pending-progress.query.v1"
  /// A pause-and-position request. A new key, so an older build never mistakes it for
  /// the retired lease handoff.
  public static let handoff = "whirr.watch.handoff.v2"
  /// The Watch's playing report, carried in its application context.
  public static let playingReport = "whirr.watch.playing-report.v1"
  /// The phone's desired set of native-RSS episodes, sent by `transferUserInfo`. Its own key, so
  /// an offer never queues behind an audio file (ADR 0019).
  public static let episodeSendOffer = "whirr.watch.episode.offer.v1"
  /// The Watch's authoritative report of the RSS copies it holds, sent by `transferUserInfo`.
  public static let episodeInventory = "whirr.watch.episode.inventory.v1"
  /// The Watch's native-RSS progress, sent by `transferUserInfo`.
  public static let nativeProgressReport = "whirr.watch.native-progress.report.v1"
  /// A pause-and-position request for a native-RSS episode, sent by `sendMessage` with a reply.
  public static let nativePauseRequest = "whirr.watch.native-pause.v1"
  /// The Watch's own link status, carried in the same application context as the playing report.
  public static let statusReport = "whirr.watch.status-report.v1"
  /// The phone's desired set of Audiobookshelf books and episodes, sent by `transferUserInfo`. Its
  /// own key, because an RSS offer entry decodes strictly and an older Watch would drop a mixed
  /// offer whole (ADR 0021 Decision 1). The Watch's inventory answers both offers.
  public static let absSendOffer = "whirr.watch.abs.offer.v1"
}
