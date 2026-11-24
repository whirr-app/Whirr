import ABSApi
import Foundation
import WatchProtocol

public struct WatchOfflineProgressSession: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let accountStamp: WatchAccountStamp
  public let selection: WatchSelection
  public let startedAt: Date
  public var updatedAt: Date
  public let startPosition: Double?
  public var currentPosition: Double
  /// Grows when the audio runs past what the manifest declared; it never shrinks.
  public var duration: Double?
  public var timeListening: Double
  public var isFinished: Bool
  /// The shared position observed before this Watch-owned session began. It is optional so
  /// sessions created without a reachable phone/server remain playable and old persisted rows
  /// continue to decode.
  public var lastKnownSharedPosition: Double?
  /// The observation time belonging to `lastKnownSharedPosition`, when one was available.
  public var lastKnownSharedObservedAt: Date?
  /// When this row last gained listening time or a user seek. `updatedAt` also moves on paused
  /// ticks and rewrites, so it cannot say which device was used last. `nil` until the first
  /// listen, and in rows persisted before this field existed.
  public var lastListenedAt: Date?

  /// The time this row's position was last chosen by the listener, for conflict decisions.
  public var effectiveLastListenedAt: Date { lastListenedAt ?? updatedAt }

  /// Whether the row says anything the server or the phone needs: listening, a finish, or a
  /// position the listener chose. A seek while paused has no listening time and still counts.
  public var hasProgressToSend: Bool { isFinished || timeListening > 0 || lastListenedAt != nil }

  public init(
    id: UUID,
    accountStamp: WatchAccountStamp,
    selection: WatchSelection,
    startedAt: Date,
    updatedAt: Date,
    startPosition: Double?,
    currentPosition: Double,
    duration: Double?,
    timeListening: Double,
    isFinished: Bool,
    lastKnownSharedPosition: Double? = nil,
    lastKnownSharedObservedAt: Date? = nil,
    lastListenedAt: Date? = nil
  ) {
    self.id = id
    self.accountStamp = accountStamp
    self.selection = selection
    self.startedAt = startedAt
    self.updatedAt = updatedAt
    self.startPosition = startPosition
    self.currentPosition = currentPosition
    self.duration = duration
    self.timeListening = timeListening
    self.isFinished = isFinished
    self.lastKnownSharedPosition = lastKnownSharedPosition
    self.lastKnownSharedObservedAt = lastKnownSharedObservedAt
    self.lastListenedAt = lastListenedAt
  }

  public func toUpload() -> LocalPlaybackSession {
    let item: String
    let episode: String?
    switch selection {
    case .audiobookshelf(let itemID, let episodeID):
      item = itemID
      episode = episodeID
    default:
      preconditionFailure("WatchOfflineProgressStore.validate rejects native selections")
    }
    return LocalPlaybackSession(
      id: id.uuidString.lowercased(), libraryItemID: item, episodeID: episode,
      duration: duration, startTime: startPosition, currentTime: currentPosition,
      timeListening: timeListening, startedAt: startedAt, updatedAt: updatedAt)
  }
}

public enum WatchOfflineProgressStoreError: Error, Sendable, Equatable {
  case nativeSelection
  case invalidSelection
  case accountMismatch
  case notFound(UUID)
  case duplicate(UUID)
  case invalidPosition
  case invalidDelta
  case invalidDuration
  case batchSizeExceeded
  case uploadAlreadyInFlight
  case storageFailure
}
