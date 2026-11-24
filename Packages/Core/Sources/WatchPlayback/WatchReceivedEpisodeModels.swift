import Foundation
import PlayerCore
import WatchProtocol

/// One native-RSS episode the Watch has admitted, holds, is downloading, failed, declined or
/// removed. It carries its own title, show, duration and chapters so playback never reads the
/// phone's or the ABS download-label map, and its `revision` is the phone's send revision: a re-send
/// at a higher revision replaces the copy and resets the position.
///
/// A `receiving` entry is admitted and its bytes are reserved in the shared budget, but the
/// download has not started. There is no separate "offered" state: the Watch cannot observe an
/// incoming offer, so an entry exists only once the offer admitted it. The entry also carries the
/// enclosure URL the Watch downloads itself, because B has no file transport (ADR 0020).
public struct WatchReceivedEpisode: Codable, Sendable, Equatable {
  public enum State: String, Codable, Sendable, Equatable {
    /// Admitted and queued; the download has not started.
    case receiving
    case downloading
    case waitingForNetwork = "waiting_for_network"
    case ready
    case failed
    case declined
    case removed
  }

  public let selection: WatchNativeSelection
  public let revision: UInt64
  public var state: State
  public var declineReason: WatchEpisodeInventoryEntry.DeclineReason?
  /// Why the Watch's own download failed; present iff `state == .failed`.
  public var failureReason: WatchEpisodeInventoryEntry.FailureReason?
  /// The download's completion fraction; present iff `state == .downloading` and its length is known.
  public var progress: Double?
  public var title: String
  public var showTitle: String
  public var duration: Double?
  /// Where the download comes from. Optional only on the persisted model: a copy committed before
  /// B has no URL, and the wire never carries an entry without one.
  public let enclosureURL: URL?
  /// The offer's length, an estimate for the reservation only, until the download's response states
  /// its own length and replaces it (`resize(toResponseBytes:)`).
  public private(set) var declaredBytes: Int64?
  /// The budget this entry claims while it is queued, downloading or waiting for its network. A
  /// `ready` entry claims its measured bytes instead, and a `failed` one claims nothing.
  public private(set) var reservedBytes: Int64
  public let mimeType: String
  /// The chapters the offer carried; they no longer arrive with a file.
  public var chapters: [WatchEpisodeChapter]
  /// The phone's position and last-listen time from the offer. A Watch listen updates neither; they
  /// stay the phone's values until the next offer (or a re-send) replaces them.
  public var phonePosition: Double
  public var phoneLastListenedAt: Date?
  /// The measured size of the installed file. Present iff `state == .ready`.
  public var committedBytes: Int64?
  /// The digest-only destination under the store's vault. It is fixed at admission from the
  /// offer's MIME, and the download writes there, so the persisted path always matches the
  /// persisted `mimeType`.
  public let relativePath: String
  public let offeredAt: Date
  public var updatedAt: Date

  public init(
    selection: WatchNativeSelection,
    revision: UInt64,
    state: State,
    declineReason: WatchEpisodeInventoryEntry.DeclineReason? = nil,
    failureReason: WatchEpisodeInventoryEntry.FailureReason? = nil,
    progress: Double? = nil,
    title: String,
    showTitle: String,
    duration: Double?,
    enclosureURL: URL?,
    declaredBytes: Int64?,
    mimeType: String,
    chapters: [WatchEpisodeChapter] = [],
    phonePosition: Double,
    phoneLastListenedAt: Date?,
    committedBytes: Int64? = nil,
    relativePath: String,
    offeredAt: Date,
    updatedAt: Date
  ) {
    self.selection = selection
    self.revision = revision
    self.state = state
    self.declineReason = declineReason
    self.failureReason = failureReason
    self.progress = progress
    self.title = title
    self.showTitle = showTitle
    self.duration = duration
    self.enclosureURL = enclosureURL
    self.declaredBytes = declaredBytes
    self.reservedBytes = WatchEnclosureAdmission.reservationBytes(declaredBytes: declaredBytes)
    self.mimeType = mimeType
    self.chapters = chapters
    self.phonePosition = phonePosition
    self.phoneLastListenedAt = phoneLastListenedAt
    self.committedBytes = committedBytes
    self.relativePath = relativePath
    self.offeredAt = offeredAt
    self.updatedAt = updatedAt
  }

  /// Rows from A carry `expectedBytes` and no `enclosureURL`. A row that a B store cannot act on
  /// throws here, and the store's lossy payload decoding drops just that row and its file rather
  /// than discarding every copy the listener already has.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let state = try container.decode(State.self, forKey: .state)
    let enclosureURL = try container.decodeIfPresent(URL.self, forKey: .enclosureURL)
    let committedBytes = try container.decodeIfPresent(Int64.self, forKey: .committedBytes)
    if enclosureURL == nil {
      switch state {
      case .ready:
        // An installed copy plays without a URL; the phone's next offer supplies one.
        guard committedBytes != nil else { throw WatchReceivedEpisodeStoreError.invalidEntry }
      case .declined, .removed:
        break
      case .receiving, .downloading, .waitingForNetwork, .failed:
        // These all describe a download this store would have to resume or report, and A's row has
        // no URL to do either with. The phone re-offers the episode.
        throw WatchReceivedEpisodeStoreError.invalidEntry
      }
    }
    self.init(
      selection: try container.decode(WatchNativeSelection.self, forKey: .selection),
      revision: try container.decode(UInt64.self, forKey: .revision),
      state: state,
      declineReason: try container.decodeIfPresent(
        WatchEpisodeInventoryEntry.DeclineReason.self, forKey: .declineReason),
      failureReason: try container.decodeIfPresent(
        WatchEpisodeInventoryEntry.FailureReason.self, forKey: .failureReason),
      progress: try container.decodeIfPresent(Double.self, forKey: .progress),
      title: try container.decode(String.self, forKey: .title),
      showTitle: try container.decode(String.self, forKey: .showTitle),
      duration: try container.decodeIfPresent(Double.self, forKey: .duration),
      enclosureURL: enclosureURL,
      declaredBytes: try container.decodeIfPresent(Int64.self, forKey: .declaredBytes),
      mimeType: try container.decode(String.self, forKey: .mimeType),
      chapters: try container.decodeIfPresent([WatchEpisodeChapter].self, forKey: .chapters) ?? [],
      phonePosition: try container.decode(Double.self, forKey: .phonePosition),
      phoneLastListenedAt: try container.decodeIfPresent(Date.self, forKey: .phoneLastListenedAt),
      committedBytes: committedBytes,
      relativePath: try container.decode(String.self, forKey: .relativePath),
      offeredAt: try container.decode(Date.self, forKey: .offeredAt),
      updatedAt: try container.decode(Date.self, forKey: .updatedAt))
  }

  /// Takes the response's stated length as the entry's size, so an unsized offer's 1 GiB reservation
  /// shrinks to the file's own once its download starts. Returns `false`, changing nothing, for a
  /// length that is unusable or already the entry's.
  mutating func resize(toResponseBytes bytes: Int64) -> Bool {
    guard bytes > 0, bytes <= WatchEpisodeSendLimits.maxEpisodeBytes, bytes != declaredBytes else {
      return false
    }
    declaredBytes = bytes
    reservedBytes = WatchEnclosureAdmission.reservationBytes(declaredBytes: bytes)
    return true
  }

  /// Chapters ready for `PlayerCore`: an open-ended chapter ends at the next chapter's start, and
  /// the last one ends at the episode duration. A last open chapter with no known duration uses the
  /// wire's position ceiling, which keeps the chapter seekable instead of dropping it.
  public var playbackChapters: [PlaybackChapter] {
    chapters.enumerated().compactMap { index, chapter in
      let end =
        chapter.end ?? (index + 1 < chapters.count ? chapters[index + 1].start : nil)
        ?? duration ?? WatchHandoffLimits.maxPositionSeconds
      guard end > chapter.start else { return nil }
      return PlaybackChapter(id: nil, title: chapter.title, start: chapter.start, end: end)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case selection, revision, state, declineReason, failureReason, progress, title, showTitle,
      duration, enclosureURL, declaredBytes, reservedBytes, mimeType, chapters, phonePosition,
      phoneLastListenedAt, committedBytes, relativePath, offeredAt, updatedAt
  }
}

/// The result of applying the phone's desired set. `dropped` names selections whose local playable
/// copy was deleted, so the caller can stop playback of one; a re-admitted selection appears in
/// both `admitted` and `dropped` when its previous revision was ready.
public enum WatchEpisodeOfferOutcome: Sendable, Equatable {
  public enum IgnoredReason: String, Sendable, Equatable {
    case foreignInstall
    case staleGeneration
  }

  case ignored(IgnoredReason)
  case applied(admitted: [WatchNativeSelection], declined: [WatchNativeSelection], dropped: [WatchNativeSelection])

  public var admitted: [WatchNativeSelection] {
    if case .applied(let admitted, _, _) = self { return admitted }
    return []
  }

  public var declined: [WatchNativeSelection] {
    if case .applied(_, let declined, _) = self { return declined }
    return []
  }

  public var dropped: [WatchNativeSelection] {
    if case .applied(_, _, let dropped) = self { return dropped }
    return []
  }
}

/// Why a downloaded file was thrown away. Every outcome consumes the file: it is installed or
/// deleted before the call returns, because the download session's temporary file belongs to this
/// app and nothing else will remove it.
public enum WatchReceivedFileOutcome: Sendable, Equatable {
  public enum DiscardReason: String, Sendable, Equatable {
    case unknown
    case staleRevision
    case removed
    case declined
    case duplicate
    /// The file on disk is not the byte count the response was validated against.
    case sizeMismatch
  }

  case committed(WatchReceivedEpisode)
  /// The entry is now `declined(.invalid)`; its reservation was released.
  case declined(WatchEpisodeInventoryEntry.DeclineReason)
  case discarded(DiscardReason)
}

public enum WatchReceivedEpisodeStoreError: Error, Sendable, Equatable {
  case invalidInstallIdentity
  /// A persisted row did not describe a file this store could own.
  case invalidEntry
  case notFound
  case notPlayable
  case storageFailure
}
