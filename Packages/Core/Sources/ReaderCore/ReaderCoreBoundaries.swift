import Foundation

/// The stable lifecycle states of an `EPUBRendering` engine.
public enum EPUBRenderingLifecycleState: Sendable, Equatable {
  /// No renderer engine is running. `start()` is the next operation.
  case stopped
  /// The renderer engine is running but there is no active publication.
  case ready
  /// One publication is active and may receive navigation and preference commands.
  case publicationOpen
}

/// Why a local EPUB could not be opened.
public enum EPUBRenderingOpenFailure: Error, Equatable, Sendable {
  /// The caller did not have a local EPUB to open. The renderer never resolves or downloads paths.
  case noEbook
  /// The publication is protected by a DRM scheme that this client does not support.
  case drmProtected
  /// The local file could not be parsed or rendered, including an unsupported or ambiguous format.
  case unopenable
  /// The publication server or rendering engine could not start. This is not a corrupt-file result.
  case serverFailure
}

/// Metadata Readium exposes after opening a publication and before navigation begins.
///
/// `positions == nil` means that the renderer did not expose a positions list. An empty, non-nil
/// array means that it did expose one and it was empty; callers must preserve that distinction
/// when deciding whether a percentage-only restore is available.
public struct OpenedEPUBPublication: Equatable, Sendable {
  public let toc: [TOCEntry]
  public let positions: [ReadingPosition]?
  public let reflowable: Bool

  /// The inverse of `reflowable`. Fixed-layout EPUBs open successfully.
  public var fixedLayout: Bool { reflowable == false }

  public init(
    toc: [TOCEntry] = [],
    positions: [ReadingPosition]? = nil,
    reflowable: Bool = true
  ) {
    self.toc = toc
    self.positions = positions
    self.reflowable = reflowable
  }
}

/// A screen-side page-turn command. The publication decides how a direction relates to reading
/// order, including for right-to-left publications.
public enum ReaderPageDirection: Sendable, Equatable {
  case left
  case right
}

/// The Foundation-only boundary around the UIKit-bound Readium EPUB navigator.
///
/// Isolated to `@MainActor`: the production adapter owns UIKit/Readium navigator objects, like
/// `PlayerCore.AudioEngine`. The payload types (`ReadingPosition`, `ReaderPreferences`,
/// `TOCEntry`, `OpenedEPUBPublication`) are `Sendable` values, so they cross into persistence and
/// other actors without importing UIKit or Readium into Core.
///
/// Lifecycle state machine:
///
/// - `stopped --start()--> ready` starts the renderer engine. A startup failure is reported as
///   `EPUBRenderingOpenFailure.serverFailure` and leaves the engine stopped.
/// - `ready --open(_:)--> publicationOpen` opens the downloaded local file. The renderer gets the
///   complete preferences and optional initial location up front, builds its navigator there, and
///   falls back to the publication start only when the location is absent or unresolvable.
///   `noEbook`, `drmProtected` and `unopenable` leave the state unchanged. A fixed-layout
///   publication is still `publicationOpen`, with `fixedLayout == true` on its capability.
/// - `publicationOpen --close()--> ready` closes the publication and finishes its position
///   stream. `close()` is idempotent when none is open.
/// - A second successful `open(_:)` while `publicationOpen` replaces the navigator, finishes the
///   old position stream and returns the new metadata. A failed second open leaves the current
///   publication and stream intact.
/// - `stop()` closes any publication, finishes its stream and transitions to `stopped`. It is
///   idempotent and the explicit shutdown; cleanup is not delegated to `deinit`.
///
/// `ReadingPosition` carries the optional locator CFI but does not turn Readium's partial CFI into
/// a genuine EPUB CFI. DRM is a distinct open failure, and ambiguous parser failures stay
/// `unopenable` with no automatic redownload. `OpenedEPUBPublication.reflowable` exposes fixed
/// layout before rendering. `start`/`stop` plus `open`/`close` model the Readium 3.11 navigator,
/// which needs no external HTTP server. Locator text context is absent, so book text cannot be
/// persisted or transmitted.
@MainActor
public protocol EPUBRendering: AnyObject, Sendable {
  var lifecycleState: EPUBRenderingLifecycleState { get }

  /// The current publication's live positions. Implementations use `bufferingNewest(1)` so a slow
  /// consumer gets the newest position, not a page-turn backlog. The stream finishes when
  /// `close()` or `stop()` closes the publication; a new successful `open` provides a new stream.
  var positionUpdates: AsyncStream<ReadingPosition> { get }

  /// Whether the open publication exposes a search service. False when no publication is open.
  var isSearchable: Bool { get }

  /// Searches the open publication, yielding each page of hits as the iterator produces it.
  /// Streams because a whole-book search walks every resource and the reader should act on the
  /// first hits meanwhile. Finishes normally at the end of the publication; throws
  /// `ReaderSearchFailure`. Starting a new search cancels any running one.
  func search(query: String) -> AsyncThrowingStream<[ReaderSearchHit], any Error>

  /// Cancels the running search and drops its retained locators. Idempotent.
  func cancelSearch() async

  /// Navigates to a hit from the most recent search. Throws when the id is not from that search.
  func go(toSearchHit id: String) async throws

  /// Highlights one hit from the most recent search, or clears the highlight when `id` is nil.
  /// Implementations no-op when the id is not from that search or the navigator cannot draw
  /// highlights.
  func highlightSearchHit(id: String?) async

  /// Turns the active publication toward a screen side. Returns `false` when the publication edge
  /// was reached: nothing navigated, no position will be emitted, and callers must not wait for
  /// one.
  func turnPage(_ direction: ReaderPageDirection) async -> Bool

  /// Starts the renderer engine. It does not resolve a file or open a publication.
  func start() async throws

  /// Opens exactly the supplied local file URL. Path resolution, downloading, authentication, and
  /// HTTP-server setup outside the renderer are not part of this boundary.
  func open(_ request: EPUBOpenRequest) async throws -> OpenedEPUBPublication

  /// Closes the active publication while keeping the renderer engine ready for another open.
  func close() async

  /// Stops the renderer engine, closing any active publication first.
  func stop() async

  /// Restores a locally stored locator. The resulting navigator position is emitted on
  /// `positionUpdates` when the underlying engine reports it.
  func go(to position: ReadingPosition) async throws

  /// Restores from Audiobookshelf's cross-device `ebookProgress` fraction. The argument is the
  /// inverse direction of `ebookProgress(for:)`; callers provide a finite value in `0...1`.
  func go(toTotalProgression: Double) async throws

  /// Submits the current reader preferences to the active publication.
  func submit(preferences: ReaderPreferences) async throws
}
