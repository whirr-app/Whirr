import AppModel
import CarPlay
import Observation
import Persistence
import PlayerCore
import Testing
import UIKit

@testable import Whirr

/// A navigation stack that applies operations at once, the way the car does when nothing is
/// animating.
@MainActor
final class FakeCarPlayInterface: CarPlayInterface {
  private(set) var root: CPTemplate?
  private(set) var pushed: [CPTemplate] = []
  private(set) var rootCount = 0
  private(set) var alerts: [CPAlertTemplate] = []
  private(set) var dismissCount = 0

  var top: CPTemplate? { pushed.last ?? root }
  var topList: CPListTemplate? { top as? CPListTemplate }

  func setRoot(_ template: CPTemplate) {
    root = template
    pushed = []
    rootCount += 1
  }

  func push(_ template: CPTemplate) { pushed.append(template) }

  func pop(to template: CPTemplate) {
    if let index = pushed.firstIndex(where: { $0 === template }) {
      pushed.removeSubrange((index + 1)...)
    } else {
      pushed = []
    }
  }

  func presentAlert(_ template: CPAlertTemplate) { alerts.append(template) }
  func dismissAlert() { dismissCount += 1 }
}

@MainActor
final class FakeCarPlayNowPlaying: CarPlayNowPlayingSurface {
  let template: CPTemplate = CPListTemplate(title: "Now Playing", sections: [])
  var onChapters: (@MainActor () -> Void)?
  var onRate: (@MainActor () -> Void)?
  var onUpNext: (@MainActor () -> Void)?
  private(set) var buttons = CarPlayNowPlayingButtons()
  private(set) var isDetached = false

  func show(_ buttons: CarPlayNowPlayingButtons) { self.buttons = buttons }
  func detach() { isDetached = true }
}

/// The process as the coordinator sees it. Observable, so a change here reaches the
/// coordinator the way a change in the runtime or the player does.
@MainActor
@Observable
final class CarPlayTestWorld {
  var rootState = CarPlayRootState.ready
  var generation = 1
  var limits = CarPlayLimits(maximumTabCount: 4, maximumItemCount: 12, imagePixelSize: 90, isDark: false)
  var presets: [Double] = [1, 1.5, 2]
  var snapshots: [CarPlayBrowseRoute: [CarPlayBrowseRow]] = [:]
  var pages: [CarPlayBrowseRoute: [CarPlayBrowseRow]] = [:]
  var player = PlayerState.idle
  var rate = 1.0

  @ObservationIgnored private(set) var startCount = 0
  @ObservationIgnored private(set) var performed: [CarPlaySelection] = []
  @ObservationIgnored private(set) var pageRequests: [CarPlayBrowseRoute] = []
  @ObservationIgnored private(set) var selectedChapters: [Int] = []
  @ObservationIgnored private(set) var rates: [Double] = []
  @ObservationIgnored private(set) var artworkKeys: [CarPlayArtworkKey] = []
  /// When set, a start waits here until `finishStart` is called.
  @ObservationIgnored var holdsStarts = false
  @ObservationIgnored var startResult = CarPlayPlaybackResult.accepted
  @ObservationIgnored private var waitingStarts: [CheckedContinuation<CarPlayPlaybackResult, Never>] = []
  /// A read of one of these routes waits until `releasePages` is called.
  @ObservationIgnored var heldRoutes: Set<CarPlayBrowseRoute> = []
  @ObservationIgnored private var waitingPages: [CheckedContinuation<Void, Never>] = []

  var hasWaitingPage: Bool { waitingPages.isEmpty == false }

  func releasePages() {
    heldRoutes = []
    for continuation in waitingPages { continuation.resume() }
    waitingPages = []
  }

  private func recordArtwork(_ key: CarPlayArtworkKey) { artworkKeys.append(key) }

  var hasWaitingStart: Bool { waitingStarts.isEmpty == false }

  func finishStart(_ result: CarPlayPlaybackResult) {
    for continuation in waitingStarts { continuation.resume(returning: result) }
    waitingStarts = []
  }

  var environment: CarPlayEnvironment {
    CarPlayEnvironment(
      start: { [self] in startCount += 1 },
      rootState: { [self] in rootState },
      graph: { [self] in rootState == .ready ? graph(generation) : nil },
      presets: { [self] in presets },
      limits: { [self] in limits })
  }

  private func graph(_ generation: Int) -> CarPlayGraph {
    CarPlayGraph(
      generation: generation,
      start: {},
      snapshot: { [self] route in
        CarPlayBrowseSnapshot(
          generation: generation, route: route, content: snapshots[route].map { .rows($0) } ?? .loading)
      },
      page: { [self] route, _, _ in
        pageRequests.append(route)
        if heldRoutes.contains(route) { await withCheckedContinuation { waitingPages.append($0) } }
        guard generation == self.generation else { return .rejected(.staleGeneration) }
        return .page(CarPlayBrowsePage(generation: generation, route: route, rows: pages[route] ?? [], next: nil))
      },
      perform: { [self] selection in
        performed.append(selection)
        guard holdsStarts else { return startResult }
        return await withCheckedContinuation { waitingStarts.append($0) }
      },
      selectChapter: { [self] row, _ in
        selectedChapters.append(row.id)
        return .accepted
      },
      setRate: { [self] rate in
        rates.append(rate)
        return .accepted
      },
      playerState: { [self] in player },
      effectiveRate: { [self] _ in rate },
      loadArtwork: { [weak self] key in
        await self?.recordArtwork(key)
        return UIImage()
      })
  }

  static func book(_ id: String, artwork: CarPlayArtworkReference = .none) -> CarPlayBrowseRow {
    CarPlayBrowseRow(
      id: id, identity: ListeningIdentity.audiobook(itemID: id), title: "Book \(id)", subtitle: "Author",
      artwork: artwork)
  }

  static func author(_ name: String) -> CarPlayBrowseRow {
    CarPlayBrowseRow(
      id: "author|\(name)", identity: nil, title: name, subtitle: "2 books", artwork: .none,
      child: .authorBooks(name: name))
  }

  static func episode(_ id: String, progress: Double? = nil) -> CarPlayBrowseRow {
    CarPlayBrowseRow(
      id: "latest|\(id)", identity: ListeningIdentity.podcastEpisode(itemID: "show", episodeID: id),
      title: "Episode \(id)", subtitle: "Show · Today · 30 min", artwork: .none, progress: progress)
  }

  static func show(_ id: String) -> CarPlayBrowseRow {
    CarPlayBrowseRow(
      id: id, identity: nil, title: "Show \(id)", subtitle: nil, artwork: .none,
      child: .showEpisodes(itemID: id))
  }

  static func chapteredBook(position: Double = 150) throws -> PlayerState {
    let item = PlayerItem(
      id: "book", episodeID: nil,
      timeline: try PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 300)]),
      chapters: PlaybackChapterMap(chapters: [
        PlaybackChapter(title: "Opening", start: 0, end: 100),
        PlaybackChapter(title: "Middle", start: 100, end: 200),
        PlaybackChapter(title: "Closing", start: 200, end: 300),
      ]))
    return PlayerState(phase: .playing, item: item, currentTrackIndex: 0, globalPosition: position, rate: 1)
  }
}

extension CPListTemplate {
  var listItems: [CPListItem] { sections.flatMap(\.items).compactMap { $0 as? CPListItem } }
  var texts: [String] { listItems.compactMap(\.text) }

  func item(_ text: String) -> CPListItem? { listItems.first { $0.text == text } }
}

/// Counts how often the car's completion handler for one tap is called.
@MainActor
final class CarPlayCompletionCounter {
  private(set) var count = 0
  func tap(_ item: CPListItem?) {
    guard let item, let handler = item.handler else {
      Issue.record("the row has no handler")
      return
    }
    handler(item) { MainActor.assumeIsolated { self.count += 1 } }
  }
}
