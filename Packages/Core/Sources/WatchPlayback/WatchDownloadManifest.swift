import ABSApi
import Foundation
import PlayerCore
import WatchProtocol

public enum WatchDownloadState: String, Codable, Sendable, Equatable {
  case queued
  case downloading
  case paused
  case failed
  case completed
}

public enum WatchDownloadFailureReason: String, Codable, Sendable, Equatable {
  case waitingForWiFi
  case interrupted
  case cancelled
  case transport
  case unauthorized
  case validation
  case storage
  case quota
}

public enum WatchDownloadNetworkPolicy: String, Codable, Sendable, Equatable {
  case wifiOnly
  case anyNetwork

  /// Whether the Watch should start a Wi-Fi-only transfer on its own, given what `NWPathMonitor`
  /// reports. Only a satisfied path on the Watch's own cellular radio holds.
  ///
  /// An unsatisfied path must admit: TN3135 restricts path monitoring on a real Watch outside an
  /// active audio session, so the monitor reports `.unsatisfied` while URLSession reaches the
  /// network through the paired iPhone, and treating that as offline parked every transfer at
  /// "Waiting for Wi-Fi". `allowsCellularAccess` on the background session enforces the policy.
  public static func admitsAutomaticTransfer(pathSatisfied: Bool, pathUsesCellular: Bool) -> Bool {
    !(pathSatisfied && pathUsesCellular)
  }
}

public struct WatchDownloadManifest: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let accountStamp: WatchAccountStamp
  public let selection: WatchSelection
  public let downloadGroupID: String
  public let expectedTrackCount: Int
  public let chapters: [PlayerCore.PlaybackChapter]
  public let fileID: String
  public let fileIndex: Int
  public let startOffset: Double
  public let duration: Double?
  public let expectedBytes: Int64?
  public let expectedMIMEType: String
  public let destinationRelativePath: String
  public var state: WatchDownloadState
  public var receivedBytes: Int64
  public var transferTaskIdentifier: String?
  public var failureReason: WatchDownloadFailureReason?
  public var createdAt: Date
  public var updatedAt: Date
  /// Who started the group this file belongs to (ADR 0021 Decision 3). A manifest written before
  /// phone sends existed is the wrist's own.
  public var origin: WatchABSOrigin
  /// The phone offer entry's revision when `origin` is `.phone`, and `nil` otherwise.
  public var phoneRevision: UInt64?

  public init(
    id: UUID,
    accountStamp: WatchAccountStamp,
    selection: WatchSelection,
    downloadGroupID: String = "",
    expectedTrackCount: Int = 1,
    fileID: String,
    fileIndex: Int,
    startOffset: Double,
    duration: Double?,
    expectedBytes: Int64?,
    expectedMIMEType: String,
    destinationRelativePath: String,
    state: WatchDownloadState = .queued,
    receivedBytes: Int64 = 0,
    transferTaskIdentifier: String? = nil,
    failureReason: WatchDownloadFailureReason? = nil,
    createdAt: Date,
    updatedAt: Date,
    chapters: [PlayerCore.PlaybackChapter] = [],
    origin: WatchABSOrigin = .watch,
    phoneRevision: UInt64? = nil
  ) {
    self.chapters = PlaybackChapterMap(chapters: chapters).chapters
    self.origin = origin
    self.phoneRevision = origin == .phone ? phoneRevision : nil
    self.id = id
    self.accountStamp = accountStamp
    self.selection = selection
    self.downloadGroupID = downloadGroupID
    self.expectedTrackCount = expectedTrackCount
    self.fileID = fileID
    self.fileIndex = fileIndex
    self.startOffset = startOffset
    self.duration = duration
    self.expectedBytes = expectedBytes
    self.expectedMIMEType = expectedMIMEType
    self.destinationRelativePath = destinationRelativePath
    self.state = state
    self.receivedBytes = receivedBytes
    self.transferTaskIdentifier = transferTaskIdentifier
    self.failureReason = failureReason
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let id = try values.decode(UUID.self, forKey: .id)
    self.id = id
    self.accountStamp = try values.decode(WatchAccountStamp.self, forKey: .accountStamp)
    self.selection = try values.decode(WatchSelection.self, forKey: .selection)
    self.downloadGroupID =
      try values.decodeIfPresent(String.self, forKey: .downloadGroupID)
      ?? id.uuidString.lowercased()
    self.expectedTrackCount = try values.decodeIfPresent(Int.self, forKey: .expectedTrackCount) ?? 1
    self.fileID = try values.decode(String.self, forKey: .fileID)
    self.fileIndex = try values.decode(Int.self, forKey: .fileIndex)
    self.startOffset = try values.decode(Double.self, forKey: .startOffset)
    self.duration = try values.decodeIfPresent(Double.self, forKey: .duration)
    self.expectedBytes = try values.decodeIfPresent(Int64.self, forKey: .expectedBytes)
    self.expectedMIMEType = try values.decode(String.self, forKey: .expectedMIMEType)
    self.destinationRelativePath = try values.decode(String.self, forKey: .destinationRelativePath)
    self.state = try values.decode(WatchDownloadState.self, forKey: .state)
    self.receivedBytes = try values.decodeIfPresent(Int64.self, forKey: .receivedBytes) ?? 0
    self.transferTaskIdentifier = try values.decodeIfPresent(String.self, forKey: .transferTaskIdentifier)
    self.failureReason = try values.decodeIfPresent(WatchDownloadFailureReason.self, forKey: .failureReason)
    self.createdAt = try values.decode(Date.self, forKey: .createdAt)
    self.updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    self.chapters =
      PlaybackChapterMap(
        chapters: try values.decodeIfPresent([PlayerCore.PlaybackChapter].self, forKey: .chapters) ?? []
      ).chapters
    // Tolerant: an origin this build does not know reads as the wrist's, which no offer removes.
    let rawOrigin = try? values.decodeIfPresent(String.self, forKey: .origin)
    let origin = rawOrigin.flatMap { WatchABSOrigin(rawValue: $0) } ?? .watch
    self.origin = origin
    self.phoneRevision = origin == .phone ? (try? values.decodeIfPresent(UInt64.self, forKey: .phoneRevision)) : nil
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(id, forKey: .id)
    try values.encode(accountStamp, forKey: .accountStamp)
    try values.encode(selection, forKey: .selection)
    try values.encode(downloadGroupID, forKey: .downloadGroupID)
    try values.encode(expectedTrackCount, forKey: .expectedTrackCount)
    try values.encode(fileID, forKey: .fileID)
    try values.encode(fileIndex, forKey: .fileIndex)
    try values.encode(startOffset, forKey: .startOffset)
    try values.encodeIfPresent(duration, forKey: .duration)
    try values.encodeIfPresent(expectedBytes, forKey: .expectedBytes)
    try values.encode(expectedMIMEType, forKey: .expectedMIMEType)
    try values.encode(destinationRelativePath, forKey: .destinationRelativePath)
    try values.encode(state, forKey: .state)
    try values.encode(receivedBytes, forKey: .receivedBytes)
    try values.encodeIfPresent(transferTaskIdentifier, forKey: .transferTaskIdentifier)
    try values.encodeIfPresent(failureReason, forKey: .failureReason)
    try values.encode(createdAt, forKey: .createdAt)
    try values.encode(updatedAt, forKey: .updatedAt)
    // Chapterless downloads retain the original manifest shape, and so do the wrist's own.
    if !chapters.isEmpty { try values.encode(chapters, forKey: .chapters) }
    if origin == .phone {
      try values.encode(origin, forKey: .origin)
      try values.encodeIfPresent(phoneRevision, forKey: .phoneRevision)
    }
  }

  private enum CodingKeys: String, CodingKey {
    case chapters, origin, phoneRevision
    case id, accountStamp, selection, downloadGroupID, expectedTrackCount, fileID, fileIndex
    case startOffset, duration, expectedBytes, expectedMIMEType, destinationRelativePath
    case state, receivedBytes, transferTaskIdentifier, failureReason, createdAt, updatedAt
  }

  public var isPlayable: Bool {
    state == .completed
  }

  /// The most files one download plan may hold.
  public static let maxPlanTracks = 128

  /// Whether `indices`, one per manifest in a group, account for every track of a plan that
  /// expected `expectedCount` files. The server numbers audio files from 1, so the base is not
  /// assumed: the rule is one distinct index per expected track, the same rule
  /// `WatchDownloadStore.isGroupComplete` applies before playback, so the row and the play path
  /// cannot disagree.
  public static func indicesCoverPlan(_ indices: [Int], expectedCount: Int) -> Bool {
    expectedCount > 0 && expectedCount <= maxPlanTracks && indices.count == expectedCount
      && Set(indices).count == expectedCount
  }
}

public struct WatchDownloadTransferUpdate: Sendable, Equatable {
  public let receivedBytes: Int64
  public let expectedBytes: Int64?

  public init(receivedBytes: Int64, expectedBytes: Int64?) {
    self.receivedBytes = receivedBytes
    self.expectedBytes = expectedBytes
  }
}

public enum WatchDownloadStoreError: Error, Sendable, Equatable {
  case nativeSelection
  case invalidSelection
  case invalidFileIdentity
  case invalidFileIndex
  case invalidPosition
  case invalidDuration
  case invalidExpectedBytes
  case invalidMIMEType
  case quotaExceeded
  case duplicateDownload
  case notFound(UUID)
  case accountMismatch
  case illegalTransition(WatchDownloadState, WatchDownloadState)
  case temporaryFileMissing
  case temporaryFileIsSymlink
  case fileSizeMismatch
  case completedFileMissing
  case completedFileIsSymlink
  case storageFailure
}

extension WatchDownloadManifest {
  /// How many bytes a transfer moves before its progress is written or shown again: a twentieth
  /// of the file, or of 20 MB when its size is unknown.
  public var progressStep: Int64 { max(1, (expectedBytes ?? 20_000_000) / 20) }
}
