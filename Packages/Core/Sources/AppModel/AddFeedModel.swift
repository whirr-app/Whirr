import Foundation
import Observation
import Persistence
import PodcastFeeds

@MainActor
@Observable
public final class AddFeedModel {
  public enum Phase: Sendable, Equatable {
    case empty
    case loadingPreview
    case preview(FeedPreview)
    case following(FeedPreview)
    case followed(feedId: Int64)
    case failed(AddFeedError)
  }

  public enum DirectoryPhase: Sendable, Equatable {
    case idle
    case searching
    case results([PodcastDirectoryResult])
    case failed(AddFeedError)
  }

  /// The directory result whose detail page is open, and how far its feed preview has got.
  public enum DirectoryDetailPhase: Sendable, Equatable {
    case idle
    case loading(URL)
    case loaded(URL, FeedPreview)
    case failed(URL, AddFeedError)
  }

  public private(set) var phase: Phase = .empty
  public private(set) var directoryPhase: DirectoryPhase = .idle
  public private(set) var directoryDetailPhase: DirectoryDetailPhase = .idle
  public private(set) var directoryFollowingURL: URL?
  public private(set) var directoryFollowErrors: [URL: AddFeedError] = [:]
  public private(set) var didExtractCredentials = false
  /// Match keys (see `followKey`) of feeds known to be followed, loaded alongside each search or
  /// preview so a followed podcast shows its state before any follow is attempted.
  private var followedFeedKeys: Set<String> = []
  /// OPML import is a one-off migration step, so the sheet offers it only to a device that
  /// followed nothing when the sheet opened; Settings keeps it available afterwards.
  public private(set) var offersOPMLImport = false

  public var directoryResults: [DirectoryPodcastDisplay] {
    guard case .results(let results) = directoryPhase else { return [] }
    return results.map(DirectoryPodcastDisplay.init)
  }

  /// Nil unless `feedURL` is one of the displayed results.
  public func directoryDetail(for feedURL: URL) -> DirectoryPodcastDetailDisplay? {
    guard case .results(let results) = directoryPhase,
      let result = results.first(where: { $0.feedURL == feedURL })
    else { return nil }
    return DirectoryPodcastDetailDisplay(result: result, phase: directoryDetailPhase)
  }

  public var isSearchingDirectory: Bool {
    if case .searching = directoryPhase { return true }
    return false
  }

  public var directoryFailure: AddFeedError? {
    if case .failed(let error) = directoryPhase { return error }
    return nil
  }

  public var previewDisplay: AddFeedPreviewDisplay? {
    switch phase {
    case .preview(let preview), .following(let preview):
      AddFeedPreviewDisplay(
        title: preview.title, author: preview.author, artworkURL: preview.artworkURL,
        episodeCount: preview.episodeCount)
    default:
      nil
    }
  }

  public var isLoadingPreview: Bool {
    if case .loadingPreview = phase { return true }
    return false
  }

  public var isFollowing: Bool {
    if case .following = phase { return true }
    return false
  }

  public var isFollowed: Bool {
    if case .followed = phase { return true }
    return false
  }

  /// The native item identity for a single successful follow, retained until the sheet's
  /// dismissal callback has handed it to the shell.
  public var followedFeedItemID: String? {
    guard case .followed(let feedId) = phase else { return nil }
    return PodcastSourceIdentity.rss(feedId: feedId)?.itemId
  }

  public var canFollow: Bool {
    if case .preview = phase { return isPreviewFollowed == false }
    return false
  }

  public var isPreviewFollowed: Bool {
    guard case .preview(let preview) = phase else { return false }
    return followedFeedKeys.contains(Self.followKey(preview.feedURL))
  }

  public func isDirectoryResultFollowed(_ feedURL: URL) -> Bool {
    followedFeedKeys.contains(Self.followKey(feedURL))
  }

  public var failure: AddFeedError? {
    if case .failed(let error) = phase { return error }
    return nil
  }

  private let previews: any FeedPreviewProviding
  private let following: any NativeFeedFollowing
  private let directory: any PodcastDirectorySearching
  private let now: @Sendable () -> Date
  private struct PendingPreview: Sendable {
    // Preview equality covers display data, so retain the requested feed identity separately.
    let sourceURL: URL
    let preview: FeedPreview
    let credential: PodcastFeedCredential?
  }
  private var pendingPreview: PendingPreview?
  private var operationGeneration = 0
  // The sheet launches short-lived waiter tasks, but the model owns the actual network/store work.
  // Ignoring this task avoids publishing task bookkeeping as observable UI state.
  @ObservationIgnored private var operationTask: Task<Void, Never>?
  // The detail load has its own generation and task so that opening a detail never cancels a row
  // follow in flight, and a row follow never cancels a detail load.
  private var detailGeneration = 0
  @ObservationIgnored private var detailTask: Task<Void, Never>?

  public init(
    previews: any FeedPreviewProviding,
    following: any NativeFeedFollowing,
    directory: any PodcastDirectorySearching = NoOpPodcastDirectorySearch(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.previews = previews
    self.following = following
    self.directory = directory
    self.now = now
  }

  deinit {
    operationTask?.cancel()
    detailTask?.cancel()
  }

  /// Called as the sheet appears. A read failure leaves the import offer hidden.
  public func loadFollowedFeeds() async {
    guard let urls = try? await following.followedFeedURLs() else { return }
    followedFeedKeys.formUnion(urls.map(Self.followKey))
    offersOPMLImport = urls.isEmpty
  }

  /// URLs retain the explicit preview-before-follow journey. Every other non-empty value is a
  /// directory query, entirely separate from the account-owned Library Search model.
  public func submit(_ rawInput: String) async {
    let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else {
      invalidateOperation()
      pendingPreview = nil
      didExtractCredentials = false
      phase = .failed(.invalidAddress)
      directoryPhase = .idle
      directoryFollowingURL = nil
      return
    }
    if Self.looksLikeWebURL(trimmed) {
      directoryPhase = .idle
      await loadPreview(from: trimmed)
    } else {
      phase = .empty
      await searchDirectory(for: trimmed)
    }
  }

  public func searchDirectory(for term: String) async {
    let generation = beginOperation()
    closeDirectoryDetail()
    pendingPreview = nil
    didExtractCredentials = false
    phase = .empty
    directoryFollowingURL = nil
    let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else {
      directoryPhase = .idle
      return
    }
    directoryPhase = .searching
    directoryFollowErrors = [:]
    let directory = self.directory
    let following = self.following
    let task = Task { @MainActor [weak self] in
      do {
        async let followed = Self.loadFollowedFeedKeys(following)
        let results = try await directory.search(term: trimmed)
        let followedKeys = await followed
        guard Task.isCancelled == false, let self, self.ownsOperation(generation) else { return }
        self.followedFeedKeys = followedKeys
        self.directoryPhase = .results(results)
      } catch is CancellationError {
        return
      } catch {
        guard Task.isCancelled == false, let self, self.ownsOperation(generation) else { return }
        self.directoryPhase = .failed(.unreachable)
      }
    }
    operationTask = task
    await task.value
  }

  /// Loads the feed preview behind a displayed directory result for its detail page. Opening the
  /// result already loaded is free, and opening one that failed retries it.
  public func openDirectoryDetail(feedURL: URL) async {
    guard case .results(let results) = directoryPhase,
      results.contains(where: { $0.feedURL == feedURL })
    else { return }
    if case .loaded(let loadedURL, _) = directoryDetailPhase, loadedURL == feedURL { return }
    detailTask?.cancel()
    detailGeneration &+= 1
    let generation = detailGeneration
    directoryDetailPhase = .loading(feedURL)
    let previews = self.previews
    let task = Task { @MainActor [weak self] in
      let outcome: DirectoryDetailPhase
      do {
        let preview = try await previews.preview(for: feedURL, credential: nil)
        outcome = .loaded(feedURL, preview)
      } catch let error as FeedPreviewError {
        outcome = .failed(feedURL, AddFeedError(feedPreviewError: error))
      } catch is CancellationError {
        return
      } catch {
        outcome = .failed(feedURL, .unreachable)
      }
      guard Task.isCancelled == false, let self, self.detailGeneration == generation else { return }
      self.directoryDetailPhase = outcome
    }
    detailTask = task
    await task.value
  }

  public func closeDirectoryDetail() {
    detailTask?.cancel()
    detailTask = nil
    detailGeneration &+= 1
    directoryDetailPhase = .idle
  }

  /// A directory hit is already the visible preview. Follow still validates and enriches it from
  /// the bounded feed transport before committing the device-owned row. A search can yield several
  /// podcasts worth following, so success marks the row followed and leaves the sheet open.
  public func followDirectoryResult(feedURL: URL) async {
    guard case .results(let results) = directoryPhase,
      results.contains(where: { $0.feedURL == feedURL }),
      directoryFollowingURL == nil,
      isDirectoryResultFollowed(feedURL) == false
    else { return }
    let generation = beginOperation()
    directoryFollowingURL = feedURL
    directoryFollowErrors[feedURL] = nil
    let previews = self.previews
    let following = self.following
    let now = self.now
    // An open detail page has already fetched this feed; following from it costs no second GET.
    var detailPreview: FeedPreview?
    if case .loaded(let loadedURL, let loaded) = directoryDetailPhase, loadedURL == feedURL {
      detailPreview = loaded
    }
    let task = Task { @MainActor [weak self, detailPreview] in
      do {
        let preview: FeedPreview
        if let detailPreview {
          preview = detailPreview
        } else {
          preview = try await previews.preview(for: feedURL, credential: nil)
        }
        try Task.checkCancellation()
        _ = try await following.follow(preview, credential: nil, subscribedAt: now())
        guard Task.isCancelled == false, let self, self.ownsOperation(generation) else { return }
        self.followedFeedKeys.insert(Self.followKey(feedURL))
        self.directoryFollowingURL = nil
      } catch let error as FeedPreviewError {
        guard Task.isCancelled == false, let self, self.ownsOperation(generation) else { return }
        self.directoryFollowErrors[feedURL] = AddFeedError(feedPreviewError: error)
        self.directoryFollowingURL = nil
      } catch let error as FollowFeedError {
        guard Task.isCancelled == false, let self, self.ownsOperation(generation) else { return }
        if case .alreadyFollowing = error {
          self.followedFeedKeys.insert(Self.followKey(feedURL))
        }
        self.directoryFollowingURL = nil
      } catch is CancellationError {
        guard let self, self.ownsOperation(generation) else { return }
        self.directoryFollowingURL = nil
      } catch {
        guard Task.isCancelled == false, let self, self.ownsOperation(generation) else { return }
        self.directoryFollowErrors[feedURL] = .couldNotFollow
        self.directoryFollowingURL = nil
      }
    }
    operationTask = task
    await task.value
  }

  public func loadPreview(from rawInput: String) async {
    let generation = beginOperation()
    directoryFollowingURL = nil
    pendingPreview = nil
    let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let candidate = Self.candidate(trimmed) else {
      didExtractCredentials = false
      phase = .failed(.invalidAddress)
      return
    }
    didExtractCredentials = candidate.credential != nil
    phase = .loadingPreview
    let previews = self.previews
    let following = self.following
    let task = Task { @MainActor [weak self] in
      do {
        async let followed = Self.loadFollowedFeedKeys(following)
        let preview = try await previews.preview(
          for: candidate.url, credential: candidate.credential)
        let followedKeys = await followed
        guard Task.isCancelled == false, let self, self.ownsOperation(generation) else { return }
        self.followedFeedKeys = followedKeys
        self.pendingPreview = PendingPreview(
          sourceURL: candidate.url, preview: preview, credential: candidate.credential)
        self.phase = .preview(preview)
      } catch let error as FeedPreviewError {
        guard Task.isCancelled == false, let self, self.ownsOperation(generation) else { return }
        self.phase = .failed(AddFeedError(feedPreviewError: error))
      } catch is CancellationError {
        return
      } catch {
        guard Task.isCancelled == false, let self, self.ownsOperation(generation) else { return }
        self.phase = .failed(.unreachable)
      }
    }
    operationTask = task
    await task.value
  }

  public func follow() async {
    guard case .preview(let preview) = phase,
      let pendingPreview,
      pendingPreview.sourceURL == preview.feedURL,
      pendingPreview.preview == preview
    else { return }
    let generation = beginOperation()
    phase = .following(pendingPreview.preview)
    let following = self.following
    let now = self.now
    let task = Task { @MainActor [weak self] in
      do {
        let feedID = try await following.follow(
          pendingPreview.preview, credential: pendingPreview.credential, subscribedAt: now())
        guard Task.isCancelled == false, let self, self.ownsOperation(generation) else { return }
        self.pendingPreview = nil
        self.phase = .followed(feedId: feedID)
      } catch let error as FollowFeedError {
        guard Task.isCancelled == false, let self, self.ownsOperation(generation) else { return }
        if case .alreadyFollowing = error {
          self.followedFeedKeys.insert(Self.followKey(preview.feedURL))
          self.phase = .preview(preview)
        }
      } catch is CancellationError {
        guard let self, self.ownsOperation(generation) else { return }
        self.phase = .preview(preview)
      } catch {
        guard Task.isCancelled == false, let self, self.ownsOperation(generation) else { return }
        self.phase = .failed(.couldNotFollow)
      }
    }
    operationTask = task
    await task.value
  }

  /// Nothing has been asked for, or the query was cleared: the sheet shows its idle state.
  public var isIdle: Bool {
    phase == .empty && directoryPhase == .idle
  }

  /// Returns to the idle state when the field is cleared. Unlike `reset()`, the sheet stays open,
  /// so the followed marks and the OPML offer survive. A cancelled follow returns without clearing
  /// `directoryFollowingURL` (the next operation is expected to), and `followDirectoryResult`
  /// refuses while it is set, so it is cleared here rather than left to the cancelled task.
  public func clearQuery() {
    invalidateOperation()
    closeDirectoryDetail()
    phase = .empty
    directoryPhase = .idle
    directoryFollowingURL = nil
    directoryFollowErrors = [:]
    pendingPreview = nil
    didExtractCredentials = false
  }

  public func reset() {
    invalidateOperation()
    closeDirectoryDetail()
    phase = .empty
    directoryPhase = .idle
    directoryFollowingURL = nil
    directoryFollowErrors = [:]
    followedFeedKeys = []
    offersOPMLImport = false
    pendingPreview = nil
    didExtractCredentials = false
  }

  private func beginOperation() -> Int {
    invalidateOperation()
    return operationGeneration
  }

  private func invalidateOperation() {
    operationTask?.cancel()
    operationTask = nil
    operationGeneration &+= 1
  }

  private func ownsOperation(_ generation: Int) -> Bool {
    generation == operationGeneration
  }

  /// A failed read only costs the pre-marking; a follow still meets the store's duplicate check.
  private nonisolated static func loadFollowedFeedKeys(
    _ following: any NativeFeedFollowing
  ) async -> Set<String> {
    guard let urls = try? await following.followedFeedURLs() else { return [] }
    return Set(urls.map(followKey))
  }

  /// Directory and stored spellings of one feed routinely differ in scheme, host case and a
  /// trailing slash, so matching compares this key rather than the raw URL.
  nonisolated static func followKey(_ url: URL) -> String {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return url.absoluteString
    }
    components.user = nil
    components.password = nil
    components.fragment = nil
    components.scheme = "https"
    components.host = components.host?.lowercased()
    if components.port == 80 || components.port == 443 { components.port = nil }
    while components.path.count > 1, components.path.hasSuffix("/") {
      components.path.removeLast()
    }
    return components.string ?? url.absoluteString
  }

  private struct Candidate {
    let url: URL
    let credential: PodcastFeedCredential?
  }

  private static func looksLikeWebURL(_ value: String) -> Bool {
    guard let scheme = URLComponents(string: value)?.scheme?.lowercased() else { return false }
    return scheme == "https" || scheme == "http"
  }

  private static func candidate(_ value: String) -> Candidate? {
    guard value.isEmpty == false, var components = URLComponents(string: value) else { return nil }
    let carriesUser = components.percentEncodedUser != nil
    let carriesPassword = components.percentEncodedPassword != nil
    guard carriesUser == carriesPassword else { return nil }

    let credential: PodcastFeedCredential?
    if carriesUser {
      guard let username = components.user, let password = components.password,
        let basic = try? PodcastFeedCredential.basic(username: username, password: password)
      else { return nil }
      credential = basic
      components.percentEncodedUser = nil
      components.percentEncodedPassword = nil
    } else {
      credential = nil
    }

    guard let cleanURL = components.url, let endpoint = FeedEndpoint(url: cleanURL) else {
      return nil
    }
    return Candidate(url: endpoint.url, credential: credential)
  }
}
