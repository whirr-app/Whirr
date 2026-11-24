import SyncEngine

/// `DownloadIntents`'s fake: every call is recorded (in order) and stubbable, in the same shape
/// as `FakePlaybackSyncing`, with no real `DownloadCoordinator`. The real conformance lives in
/// `Sources/SyncEngine/DownloadCoordinator.swift`.
public final class FakeDownloadIntents: DownloadIntents, @unchecked Sendable {
  public enum RecordedCall: Sendable, Equatable {
    case requestDownload(itemID: String)
    case requestEbookDownload(itemID: String)
    case requestSupplementDownload(itemID: String, fileIno: String)
    case requestEpisodeDownload(itemID: String, episodeID: String)
    case pauseEpisodeDownload(itemID: String, episodeID: String)
    case resumeEpisodeDownload(itemID: String, episodeID: String)
    case purgeEpisodeDownload(
      itemID: String, episodeID: String, source: DownloadPurgeSource)
    case pauseEbookDownload(itemID: String)
    case resumeEbookDownload(itemID: String)
    case purgeEbookDownload(itemID: String, source: DownloadPurgeSource)
    case pauseItemDownload(itemID: String)
    case resumeItemDownload(itemID: String)
    case purgeItemDownload(itemID: String, source: DownloadPurgeSource)
    case purgeAllDownloads(source: DownloadPurgeSource)
    case purgeTombstonedEpisodeDownloads(source: DownloadPurgeSource)
    case isQueuePausedForLowDisk
  }

  private let callsBox = Locked<[RecordedCall]>([])
  public var calls: [RecordedCall] { callsBox.value }

  private let queuePausedForLowDiskBox = Locked(false)
  public var queuePausedForLowDisk: Bool {
    get { queuePausedForLowDiskBox.value }
    set { queuePausedForLowDiskBox.value = newValue }
  }

  private let errorBox = Locked<Error?>(nil)
  public func stubNextCall(throwing error: Error?) {
    errorBox.value = error
  }

  public init() {}

  public func requestDownload(itemID: String) async throws {
    callsBox.withValue { $0.append(.requestDownload(itemID: itemID)) }
    if let error = errorBox.value { throw error }
  }

  public func requestEbookDownload(itemID: String) async throws {
    callsBox.withValue { $0.append(.requestEbookDownload(itemID: itemID)) }
    if let error = errorBox.value { throw error }
  }

  public func requestSupplementDownload(itemID: String, fileIno: String) async throws {
    callsBox.withValue { $0.append(.requestSupplementDownload(itemID: itemID, fileIno: fileIno)) }
    if let error = errorBox.value { throw error }
  }

  public func requestEpisodeDownload(itemID: String, episodeID: String) async throws {
    callsBox.withValue {
      $0.append(.requestEpisodeDownload(itemID: itemID, episodeID: episodeID))
    }
    if let error = errorBox.value { throw error }
  }

  public func pauseEpisodeDownload(itemID: String, episodeID: String) async throws {
    callsBox.withValue {
      $0.append(.pauseEpisodeDownload(itemID: itemID, episodeID: episodeID))
    }
    if let error = errorBox.value { throw error }
  }

  public func resumeEpisodeDownload(itemID: String, episodeID: String) async throws {
    callsBox.withValue {
      $0.append(.resumeEpisodeDownload(itemID: itemID, episodeID: episodeID))
    }
    if let error = errorBox.value { throw error }
  }

  public func purgeEpisodeDownload(
    itemID: String, episodeID: String, source: DownloadPurgeSource
  ) async throws {
    callsBox.withValue {
      $0.append(.purgeEpisodeDownload(itemID: itemID, episodeID: episodeID, source: source))
    }
    if let error = errorBox.value { throw error }
  }

  public func pauseEbookDownload(itemID: String) async throws {
    callsBox.withValue { $0.append(.pauseEbookDownload(itemID: itemID)) }
    if let error = errorBox.value { throw error }
  }

  public func resumeEbookDownload(itemID: String) async throws {
    callsBox.withValue { $0.append(.resumeEbookDownload(itemID: itemID)) }
    if let error = errorBox.value { throw error }
  }

  public func purgeEbookDownload(itemID: String, source: DownloadPurgeSource) async throws {
    callsBox.withValue { $0.append(.purgeEbookDownload(itemID: itemID, source: source)) }
    if let error = errorBox.value { throw error }
  }

  public func pauseItemDownload(itemID: String) async throws {
    callsBox.withValue { $0.append(.pauseItemDownload(itemID: itemID)) }
    if let error = errorBox.value { throw error }
  }

  public func resumeItemDownload(itemID: String) async throws {
    callsBox.withValue { $0.append(.resumeItemDownload(itemID: itemID)) }
    if let error = errorBox.value { throw error }
  }

  public func purgeItemDownload(itemID: String, source: DownloadPurgeSource) async throws {
    callsBox.withValue { $0.append(.purgeItemDownload(itemID: itemID, source: source)) }
    if let error = errorBox.value { throw error }
  }

  public func purgeAllDownloads(source: DownloadPurgeSource) async throws {
    callsBox.withValue { $0.append(.purgeAllDownloads(source: source)) }
    if let error = errorBox.value { throw error }
  }

  public func purgeTombstonedEpisodeDownloads(source: DownloadPurgeSource) async throws {
    callsBox.withValue { $0.append(.purgeTombstonedEpisodeDownloads(source: source)) }
    if let error = errorBox.value { throw error }
  }

  public func isQueuePausedForLowDisk() async -> Bool {
    callsBox.withValue { $0.append(.isQueuePausedForLowDisk) }
    return queuePausedForLowDiskBox.value
  }
}
