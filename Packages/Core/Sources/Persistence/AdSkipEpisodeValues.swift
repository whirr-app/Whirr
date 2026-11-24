import Foundation

/// The ad-skip store's values: the episode identity a stored analysis is keyed by, the stage-1
/// plan and its alignments, a skip range, a listener mark, and what a save replaced.
///
/// An analysed file is keyed by the download identity (`EpisodeDownloadKey`) plus the ABS account
/// row id, which keeps two accounts' identical server ids apart. `accountId` is nil for RSS.
public struct AdSkipEpisodeIdentity: Hashable, Sendable {
  public var source: AdSkipEpisodeSource
  public var accountId: Int64?
  public var itemID: String
  public var episodeID: String

  public init(source: AdSkipEpisodeSource, accountId: Int64?, itemID: String, episodeID: String) {
    self.source = source
    self.accountId = accountId
    self.itemID = itemID
    self.episodeID = episodeID
  }
}

/// An episode's stored stage-1 plan.
public struct StoredStageOnePlan: Sendable, Equatable {
  /// The stage-1 transcription windows.
  public var windows: [StoredTimeSpan]
  /// Where the episode's audio aligns with other episodes.
  public var audioEdges: [StoredTimeSpan]
  /// The alignments with episodes of another show, each with the episode it aligns with.
  public var crossShow: [StoredCrossShowAlignment]
  /// Where the episode's audio aligns with other episodes of its own show, for the post-roll tail
  /// trigger.
  public var sameShowEdges: [StoredTimeSpan]

  public init(
    windows: [StoredTimeSpan], audioEdges: [StoredTimeSpan],
    crossShow: [StoredCrossShowAlignment] = [], sameShowEdges: [StoredTimeSpan] = []
  ) {
    self.windows = windows
    self.audioEdges = audioEdges
    self.crossShow = crossShow
    self.sameShowEdges = sameShowEdges
  }
}

/// Where an episode's audio aligns with an episode of another show.
public struct StoredCrossShowAlignment: Sendable, Equatable {
  public var start: Double
  public var end: Double
  /// The coordinator's opaque key of the episode aligned with, as a teacher's is stored.
  public var episodeKey: String

  public init(start: Double, end: Double, episodeKey: String) {
    self.start = start
    self.end = end
    self.episodeKey = episodeKey
  }
}

extension AdSkipEpisodeRecord {
  public var identity: AdSkipEpisodeIdentity {
    AdSkipEpisodeIdentity(
      source: source, accountId: accountId, itemID: itemID, episodeID: episodeID)
  }
}

/// A skip range without its row ids. The store reassigns them on every save and recompute, so
/// anything that needs a stable range identity derives one from the episode and the times.
public struct AdSkipRange: Sendable, Equatable {
  public var startTime: Double
  public var endTime: Double
  public var meanAdProbability: Double
  public var rulesRevision: Int
  public var fromStore: Bool
  public var endsItem: Bool
  /// The learned creative a store range matched, while it still exists.
  public var creativeId: Int64?
  /// The post-roll tail proposer made it, not repetition.
  public var fromTail: Bool
  /// The host-read pass made it, from the listener's transcript.
  public var fromHostRead: Bool
  /// The listener marked it. Served whole and laid over the rest, so it is cut from nothing.
  public var fromListener: Bool

  public init(
    startTime: Double, endTime: Double, meanAdProbability: Double, rulesRevision: Int,
    fromStore: Bool, endsItem: Bool, creativeId: Int64? = nil, fromTail: Bool = false,
    fromHostRead: Bool = false, fromListener: Bool = false
  ) {
    self.startTime = startTime
    self.endTime = endTime
    self.meanAdProbability = meanAdProbability
    self.rulesRevision = rulesRevision
    self.fromStore = fromStore
    self.endsItem = endsItem
    self.creativeId = creativeId
    self.fromTail = fromTail
    self.fromHostRead = fromHostRead
    self.fromListener = fromListener
  }

  init(_ record: AdSkipRangeRecord) {
    self.init(
      startTime: record.startTime, endTime: record.endTime,
      meanAdProbability: record.meanAdProbability, rulesRevision: record.rulesRevision,
      fromStore: record.fromStore, endsItem: record.endsItem, creativeId: record.creativeId,
      fromTail: record.fromTail, fromHostRead: record.fromHostRead,
      fromListener: record.fromListener)
  }

  func record(episodeId: Int64) -> AdSkipRangeRecord {
    AdSkipRangeRecord(
      episodeId: episodeId, startTime: startTime, endTime: endTime,
      meanAdProbability: meanAdProbability, rulesRevision: rulesRevision, fromStore: fromStore,
      endsItem: endsItem, creativeId: creativeId, fromTail: fromTail, fromHostRead: fromHostRead,
      fromListener: fromListener)
  }
}

/// A stretch the listener marked as an ad, with the confirmed creative it taught.
public struct AdSkipListenerMark: Sendable, Equatable {
  /// The teaching rules a mark is written under. 1 taught only spans of 15 s or more; 2 teaches
  /// spans of 4 s or more, which reach other episodes by their audio print alone. A mark below it
  /// is taught once more (`AdSkipEpisodeStore.marksAwaitingTeaching`).
  public static let teachingRevision = 2

  public var id: Int64
  public var startTime: Double
  public var endTime: Double
  public var creativeId: Int64?
  public var createdAt: Date
  public var teachingRevision: Int

  public init(
    id: Int64, startTime: Double, endTime: Double, creativeId: Int64?, createdAt: Date,
    teachingRevision: Int = AdSkipListenerMark.teachingRevision
  ) {
    self.id = id
    self.startTime = startTime
    self.endTime = endTime
    self.creativeId = creativeId
    self.createdAt = createdAt
    self.teachingRevision = teachingRevision
  }

  init?(_ record: AdSkipListenerMarkRecord) {
    guard let id = record.id else { return nil }
    self.init(
      id: id, startTime: record.startTime, endTime: record.endTime, creativeId: record.creativeId,
      createdAt: record.createdAt, teachingRevision: record.teachingRevision)
  }
}

public struct AdSkipSaveResult: Sendable, Equatable {
  /// The stored row, with its id.
  public var record: AdSkipEpisodeRecord
  /// The previous row's transcript file when the save no longer references it. The caller deletes
  /// the file; the store never touches the file system.
  public var replacedTranscriptFileName: String?
  /// The previous row's audio print file when the save no longer references it.
  public var replacedAudioPrintFileName: String?

  /// Both replaced files, for deletion.
  public var replacedFileNames: [String] {
    [replacedTranscriptFileName, replacedAudioPrintFileName].compactMap { $0 }
  }
}
