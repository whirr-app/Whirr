import Foundation

/// The account's playback bookmark: what was last played. Mirrors `HomeReading`'s boundary: the
/// mini player observes a `PlaybackBookmark` projection, never `PlaybackBookmarkRecord` or
/// `MediaProgressRecord`.
public protocol PlaybackBookmarkStoring: Sendable {
  /// The bookmark's live projection, or `nil` when there is none, including when the item it
  /// points at is soft-deleted or gone (see `DefaultPlaybackBookmarkStoring`). Re-emitted when
  /// the bookmark moves and when the item's saved progress changes, since the position is joined
  /// rather than stored.
  func observeBookmark() -> AsyncStream<PlaybackBookmark?>

  /// Reads the current account's projection once. Voice and other out-of-process entry points use
  /// this snapshot rather than waiting for an observation task to publish, so an action arriving
  /// immediately after launch is still scoped to the account row that exists at action time.
  func fetchBookmark() async -> PlaybackBookmark?

  /// Points the bookmark at `itemID` (the server item id, the same identity
  /// `NavigationModel.Route.itemDetail` carries), replacing any previous one.
  func setBookmark(itemID: String) async throws

  /// Points the bookmark at the full show/episode identity. Item-level callers use
  /// `setBookmark(itemID:)`; the default forwards to it.
  func setBookmark(itemID: String, episodeID: String?) async throws
}

extension PlaybackBookmarkStoring {
  public func setBookmark(itemID: String, episodeID: String?) async throws {
    try await setBookmark(itemID: itemID)
  }
}

/// The default no-op `PlaybackBookmarkStoring` conformance: the stream finishes immediately
/// without yielding, the snapshot is `nil`, and `setBookmark` does nothing.
public struct NoOpPlaybackBookmarkStoring: PlaybackBookmarkStoring, Sendable {
  public init() {}
  public func observeBookmark() -> AsyncStream<PlaybackBookmark?> {
    AsyncStream { $0.finish() }
  }
  public func fetchBookmark() async -> PlaybackBookmark? { nil }
  public func setBookmark(itemID: String) async throws {}
}

/// Bounded, account-scoped, privacy-safe local diagnostics (ARCHITECTURE.md §3).
///
/// Records a structured `DiagnosticsEvent` (category, timing, status class, and an optional
/// endpoint template only; never a payload, token, or user content). Destroyed by the
/// account-removal sequence. Distinct from the in-memory `RedactingHTTPLogger`.
public protocol DiagnosticsRecording: Sendable {
  func record(_ event: DiagnosticsEvent, accountId: Int64) async
}

/// Schema-level account removal: removing an account leaves no account-owned rows, and a crash
/// mid-removal leaves a resumable, non-partial store. The full logout ordering (sessions,
/// downloads, diagnostics files, Keychain) lives elsewhere; this protocol is the seam SyncEngine's
/// production `AccountLifecycle` conformance reaches through for the DB half.
public protocol AccountRemoving: Sendable {
  func removeAccount(accountId: Int64) throws
}
