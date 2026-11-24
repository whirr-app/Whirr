import ABSApi
import Foundation
import Observation
import WatchPlayback
import WatchProtocol

@MainActor
@Observable
final class WatchCatalogueController {
  private unowned let model: WatchLibraryModel
  private var context: WatchSessionContext? { model.session.context }
  var libraries: [WatchLibrary] = [] { didSet { model.publishCatalogue() } }
  var items: [WatchLibraryItem] = [] { didSet { model.publishCatalogue() } }
  var continued: [WatchContinueItem] = [] { didSet { model.publishCatalogue() } }
  /// Every server progress row from the last successful read. Start and resume weigh these, not
  /// the Continue list, which drops finished and hidden titles and keeps ten.
  @ObservationIgnored var serverProgress: [MediaProgress] = []
  var continueTitles: [WatchSelection: String] = [:] { didSet { model.publishCatalogue() } }
  var selectedLibrary: String? = nil { didSet { model.publishCatalogue() } }
  var hasMore: Bool = false { didSet { model.publishCatalogue() } }
  /// Why the last library refresh produced nothing to browse; kept until a refresh succeeds so the
  /// Books screen can say what to fix instead of only that no library is available.
  var libraryLoadFailure: WatchLibraryLoadFailure? = nil { didSet { model.publishCatalogue() } }
  var isRefreshingLibraries = false { didSet { model.publishCatalogue() } }
  /// What the last library request proved about the server link, reported to the phone's status
  /// probe. In memory only: nil until this process has asked the server, or after new credentials.
  private(set) var lastLinkHealth: WatchLinkHealth?
  /// When the Watch last checked its server, sent with `lastLinkHealth` so the phone can date the
  /// status it cannot wake the Watch to ask for. In memory only, like the health it accompanies.
  private(set) var lastServerContactAt: Date?
  @ObservationIgnored private lazy var browse = WatchBrowseModel(clientProvider: { [weak model] in
    model?.session.context?.libraryClient
  })
  private let catalogueLoader: (@Sendable (String, Int, Int) async throws -> WatchLibraryPage)?
  private var account: WatchAccountRecord? { context?.account ?? model.account }
  private var message: String? {
    get { model.message }
    set { model.setMessage(newValue) }
  }
  private var sessionEpoch: Int { model.session.epoch }
  private var libraryClient: WatchLibraryClient? { context?.libraryClient }
  private var service: ABSWatchLibraryService? { context?.service }
  private var downloadLabels: [String: String] { model.downloadsController.downloadLabels }
  private var downloads: [WatchDownloadManifest] { model.downloadsController.downloads }

  init(model: WatchLibraryModel, catalogueLoader: (@Sendable (String, Int, Int) async throws -> WatchLibraryPage)?) {
    self.model = model
    self.catalogueLoader = catalogueLoader
  }

  func homeProjection(scope: WatchHomeProjection.Scope) -> WatchHomeProjection {
    WatchHomeProjection(
      snapshot: model.companion.snapshot, continued: continued,
      nativeContinued: model.nativeContinueItems,
      watchAccountStamp: try? model.account?.authenticatedStamp(),
      currentSelection: model.currentSelection, scope: scope)
  }

  func refresh() async {
    guard let libraryClient else {
      if account != nil {
        libraryLoadFailure = .signInRejected
        recordLinkHealth(.signInRejected)
      }
      return
    }
    let token = sessionEpoch
    isRefreshingLibraries = true
    defer { if token == sessionEpoch { isRefreshingLibraries = false } }
    do {
      await libraryClient.invalidateBrowseCache()
      WatchBrowseModel.noteCacheInvalidated(for: libraryClient)
      let list = try await libraryClient.libraries()
      guard token == sessionEpoch else { return }
      // Recorded before the cancellation check: the server answered, whatever this refresh does next.
      recordLinkHealth(.healthy)
      guard !Task.isCancelled else { return }
      libraries = list
      libraryLoadFailure = WatchNavigationPolicy.libraries(list, mediaType: .book).isEmpty ? .noAudiobookLibrary : nil
      let preferred = selectedLibrary ?? account?.defaultLibraryID
      if let library = list.first(where: { $0.id == preferred })?.id ?? list.first?.id {
        await selectLibrary(library)
      }
      guard token == sessionEpoch, !Task.isCancelled else { return }
      await refreshContinueListening()
      guard token == sessionEpoch, !Task.isCancelled else { return }
      await model.offlineSync.reconcileOfflineProgress()
    } catch {
      guard token == sessionEpoch, !Task.isCancelled else { return }
      guard let failure = WatchLibraryLoadFailure(error) else { return }
      libraryLoadFailure = failure
      if let health = failure.linkHealth { recordLinkHealth(health) }
      WatchDiagnostics.record(.libraryLoadFailed)
    }
  }

  /// One writer for the link verdict, so every library load also updates the phone's status report.
  /// A failed attempt dates the verdict too: the Watch has just established where it stands.
  private func recordLinkHealth(_ health: WatchLinkHealth) {
    lastLinkHealth = health
    lastServerContactAt = .now
    model.publishStatusReport()
  }

  /// The one writer of the Continue list: newest first, ten rows, titles resolved.
  func adopt(_ read: WatchServerProgress) async {
    serverProgress = read.rows
    continued = Array(
      read.continued.sorted { ($0.lastUpdate ?? .distantPast) > ($1.lastUpdate ?? .distantPast) }.prefix(10))
    let selections = Set(continued.map(\.selection))
    continueTitles = continueTitles.filter { selections.contains($0.key) }
    await resolveContinueTitles()
  }

  /// Foreground refresh reads server progress without restarting library paging or uploading sessions.
  func refreshContinueListening() async {
    guard let libraryClient else { return }
    let token = sessionEpoch
    do {
      let read = try await libraryClient.serverProgress()
      guard token == sessionEpoch, !Task.isCancelled else { return }
      await adopt(read)
    } catch {
      // Keep the last valid audio rows while offline; a successful empty response clears them.
    }
  }

  func selectLibrary(_ id: String) async {
    browse.reset()
    selectedLibrary = id
    items = []
    hasMore = false
    await browse.loadCatalogue(libraryID: id, loader: catalogueLoader)
    publishPage()
  }

  /// Clear the catalogue only after teardown succeeds so a failed sign-out keeps the
  /// current account’s catalogue available while the user retries.
  func reset() {
    browse.reset()
    libraries = []
    items = []
    continued = []
    serverProgress = []
    continueTitles = [:]
    selectedLibrary = nil
    hasMore = false
    libraryLoadFailure = nil
    isRefreshingLibraries = false
    lastLinkHealth = nil
    lastServerContactAt = nil
  }

  /// New credentials are being installed, so the old pair's verdict no longer applies. The check
  /// time goes with it: the new pair has not asked its server yet.
  func forgetLinkHealth() {
    lastLinkHealth = nil
    lastServerContactAt = nil
  }

  /// Supersedes any in-flight page without touching the published catalogue.
  func invalidatePaging() {
    browse.reset()
  }

  private func publishPage() {
    items = browse.books
    hasMore = browse.hasMore
    if browse.phase == .failed { message = "Couldn’t load this library. Try refreshing." }
  }

  func loadMore() async {
    guard browse.phase != .loading else { return }
    await browse.loadMore()
    publishPage()
  }

  func resolveContinueTitles() async {
    guard let service, let account else { return }
    let token = sessionEpoch
    for progress in continued {
      if let item = items.first(where: { $0.selection == progress.selection }) {
        continueTitles[progress.selection] = item.title
        continue
      }
      // A wrist raise needs fresh progress, not another expanded-metadata request for every title.
      if continueTitles[progress.selection] != nil { continue }
      guard case .audiobookshelf(let itemID, let episodeID) = progress.selection,
        let detail = try? await service.detail(account: account.tokenAccount(), itemID: itemID)
      else { continue }
      guard token == sessionEpoch, !Task.isCancelled else { return }
      switch detail.media {
      case .book(let book): continueTitles[progress.selection] = book.title
      case .podcast(let podcast):
        continueTitles[progress.selection] = podcast.episodes.first { $0.id == episodeID }?.title ?? podcast.title
      default: break
      }
    }
  }

  func title(for selection: WatchSelection) -> String {
    continueTitles[selection] ?? downloads.first(where: { $0.selection == selection }).flatMap {
      downloadLabels[$0.id.uuidString]
    }
      ?? items.first(where: { $0.selection == selection })?.title ?? "Audiobookshelf"
  }
}
