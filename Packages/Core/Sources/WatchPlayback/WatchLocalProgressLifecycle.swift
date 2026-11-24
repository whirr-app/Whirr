import Foundation
import WatchProtocol

/// Decides when a locally played title (downloaded or independent stream) opens, records, closes
/// and finishes progress rows. A row is open only while audio plays: an open row is excluded from
/// upload, so a paused title must hold none or its listening never reaches the server.
public actor WatchLocalProgressLifecycle {
  public enum Effect: Sendable, Equatable {
    case none
    /// A closed row holds progress that should be uploaded now.
    case upload
  }

  private let store: any WatchProgressJournaling
  private let selection: WatchSelection
  private var duration: Double?
  private var sharedPosition: Double?
  private var sharedObservedAt: Date?
  /// Listening whose write threw. The store applies nothing on a failed write, so it joins the
  /// next write instead of being lost.
  private var unsavedListened: Double = 0

  public private(set) var openRowID: UUID?

  public init(
    store: any WatchProgressJournaling, selection: WatchSelection, duration: Double?,
    sharedPosition: Double?, sharedObservedAt: Date?
  ) {
    self.store = store
    self.selection = selection
    self.duration = duration
    self.sharedPosition = sharedPosition
    self.sharedObservedAt = sharedObservedAt
  }

  /// Opens a row at `position` unless one is already open.
  public func play(at position: Double) async throws {
    guard openRowID == nil else { return }
    openRowID = try await open(at: position)
  }

  /// The audio ran past the declared duration. The open row and every later one take the
  /// grown duration; a shorter report is ignored.
  public func grow(to grown: Double) async throws {
    guard grown.isFinite, let duration, grown > duration else { return }
    self.duration = grown
    guard let id = openRowID else { return }
    try await store.growRowDuration(id: id, to: grown)
  }

  /// A periodic tick; ignored while paused, because a paused title has no open row.
  public func record(position: Double, listened: Double) async throws {
    guard let id = openRowID else { return }
    try await write(id, position: position, listened: listened)
  }

  public func pause(at position: Double, listened: Double) async throws -> Effect {
    guard let id = openRowID else { return .none }
    openRowID = nil
    let hasProgress = try await write(id, position: position, listened: listened)
    // A row with neither listening nor a user seek says nothing the server needs to hear.
    guard hasProgress else {
      try await store.deleteRow(id: id)
      return .none
    }
    return .upload
  }

  /// A user seek counts as a listen. While paused it is written to a short row of its own so the
  /// new position is uploaded without leaving a row open.
  public func seek(to position: Double) async throws -> Effect {
    if let id = openRowID {
      try await store.recordRow(
        id: id, currentPosition: position, listenedDelta: 0, isFinished: false, userSeek: true)
      return .none
    }
    let id = try await open(at: position)
    try await store.recordRow(
      id: id, currentPosition: position, listenedDelta: 0, isFinished: false, userSeek: true)
    return .upload
  }

  /// Closes the open row and reopens one at the same position, so a long listen reaches the
  /// server without a pause. The closed row's position becomes the last shared one, because it is
  /// what the server will hold once that row uploads.
  public func checkpoint(at position: Double, listened: Double, now: Date = Date()) async throws -> Effect {
    guard openRowID != nil else { return .none }
    let effect = try await pause(at: position, listened: listened)
    if effect == .upload {
      sharedPosition = duration.map { min(position, $0) } ?? position
      sharedObservedAt = now
    }
    openRowID = try await open(at: position)
    return effect
  }

  /// Ends local playback. A finish while paused opens a row so the finish is still recorded. A
  /// finished title is recorded at its end, wherever the audio was when it finished (a skip onto
  /// the end finishes from before it): the upload carries only a position, and the server reads
  /// "finished" from a position at the end.
  public func stop(at position: Double, listened: Double, finished: Bool) async throws -> Effect {
    guard finished else { return try await pause(at: position, listened: listened) }
    let position = duration ?? position
    let id: UUID
    if let openRowID {
      id = openRowID
    } else {
      id = try await open(at: position)
    }
    openRowID = nil
    try await write(id, position: position, listened: listened, isFinished: true)
    return .upload
  }

  @discardableResult
  private func write(_ id: UUID, position: Double, listened: Double, isFinished: Bool = false) async throws
    -> Bool
  {
    let total = unsavedListened + listened
    do {
      let hasProgress = try await store.recordRow(
        id: id, currentPosition: position, listenedDelta: total, isFinished: isFinished,
        userSeek: false)
      unsavedListened = 0
      return hasProgress
    } catch {
      if total.isFinite, total >= 0 { unsavedListened = total }
      throw error
    }
  }

  private func open(at position: Double) async throws -> UUID {
    // A bookmark or shared position can lie past the playable duration; the store rejects that.
    let start = duration.map { min(position, $0) } ?? position
    return try await store.openRow(
      selection: selection, startPosition: start, duration: duration,
      lastKnownSharedPosition: sharedPosition, lastKnownSharedObservedAt: sharedObservedAt
    )
  }
}
