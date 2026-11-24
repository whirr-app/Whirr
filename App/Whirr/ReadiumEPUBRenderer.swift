import DesignSystem
import Foundation
import ReaderCore
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer
import UIKit

/// A dumb Readium 3.11 adapter for the frozen `EPUBRendering` boundary.
///
/// Readium 3.11's EPUB navigator owns its resource-serving surface; this adapter starts no
/// `GCDHTTPServer`/`ReadiumAdapterGCDWebServer`, so there is no server, URL, port or teardown to
/// manage, and scene background/return creates no external URL. A second successful open prepares
/// the replacement before closing the current publication; a failed open leaves the current
/// publication and position stream alone. Callers `stop()` at logout or environment rebuild, then
/// `start()` and `open()` after return. Every close, replacement, stop and failed-open path is
/// explicit; cleanup is not a `deinit` hook.
@MainActor
final class ReadiumEPUBRenderer: EPUBRendering, EPUBNavigatorDelegate {
  /// Readium takes the maximum of these values and the window safe-area insets, keyed by vertical
  /// size class. They are fixed so the page never repaginates as the chrome and status bar come
  /// and go, and deep enough that the running header and footer (`ReaderPageFurnitureView`) sit in
  /// blank margin. The chrome may overlay the text while it shows; hiding it reclaims the page.
  /// Starting values; tune on device.
  static let contentInsets: [UIUserInterfaceSizeClass: EPUBContentInsets] = [
    .compact: (top: 56, bottom: 68),
    .regular: (top: 112, bottom: 72),
  ]

  private lazy var httpClient = DefaultHTTPClient(ephemeral: true)
  private lazy var assetRetriever = AssetRetriever(httpClient: httpClient)
  private lazy var parser = DefaultPublicationParser(
    httpClient: httpClient,
    assetRetriever: assetRetriever,
    pdfFactory: DefaultPDFDocumentFactory()
  )
  private lazy var opener = PublicationOpener(parser: parser)

  private(set) var lifecycle = ReadiumEPUBRendererLifecycle()
  private(set) var publication: Publication?
  private(set) var navigator: EPUBNavigatorViewController?
  /// The metadata returned by the current publication for App-side reader chrome (TOC and the
  /// fixed-layout capability). ReaderModel remains the owner of open state and restore policy.
  private(set) var openedPublication: OpenedEPUBPublication?
  private var inputObserverTokens = Set<InputObservableToken>()
  let hostViewController = ReadiumEPUBRendererHostViewController()
  private var currentPreferences = ReaderPreferences()

  private var positionStream: AsyncStream<ReadingPosition>
  private var positionContinuation: AsyncStream<ReadingPosition>.Continuation?
  private var tapStream: AsyncStream<ReadiumEPUBTapZone>
  private var tapContinuation: AsyncStream<ReadiumEPUBTapZone>.Continuation?

  var searchGeneration = 0
  var searchLocators: [String: Locator] = [:]
  var searchTask: Task<Void, Never>?
  var searchIterator: (any SearchIterator)?
  var searchContinuation: AsyncThrowingStream<[ReaderSearchHit], any Error>.Continuation?

  init() {
    let position = Self.makeStream(ReadingPosition.self)
    positionStream = position.stream
    position.continuation.finish()
    positionContinuation = nil

    let taps = Self.makeStream(ReadiumEPUBTapZone.self)
    tapStream = taps.stream
    taps.continuation.finish()
    tapContinuation = nil
  }

  var lifecycleState: EPUBRenderingLifecycleState { lifecycle.state }

  var positionUpdates: AsyncStream<ReadingPosition> { positionStream }

  var isSearchable: Bool {
    guard lifecycle.state == .publicationOpen, let publication else { return false }
    return publication.isSearchable
  }

  /// The input-observer events consumed by the reader screen.
  var tapEvents: AsyncStream<ReadiumEPUBTapZone> { tapStream }

  /// The UIKit host used by the minimal `UIViewControllerRepresentable` below.
  var viewController: UIViewController { hostViewController }

  func start() async throws {
    lifecycle.start()
  }

  func open(_ request: EPUBOpenRequest) async throws -> OpenedEPUBPublication {
    guard lifecycle.state != .stopped else {
      throw EPUBRenderingOpenFailure.serverFailure
    }
    if let failure = Self.localFileFailure(for: request.localFileURL) {
      lifecycle.openFailed()
      throw failure
    }
    guard let fileURL = FileURL(url: request.localFileURL) else {
      lifecycle.openFailed()
      throw EPUBRenderingOpenFailure.noEbook
    }

    // Every Readium failure below is classified into the frozen four-case boundary, which discards
    // the original error, and `classifyOpenFailure` funnels anything it doesn't recognise into
    // `.unopenable`. The raw error and its stage are traced first so "this book never opens" stays
    // attributable.
    let began = Date()
    func elapsed() -> String { String(Int(Date().timeIntervalSince(began) * 1000)) }
    ReaderTrace.emit(
      "readium", ["stage": "begin", "file": ReaderTrace.fileValue(request.localFileURL)])
    var navigatorTarget = "none"

    do {
      let asset: Asset
      switch await assetRetriever.retrieve(url: fileURL) {
      case .success(let value):
        asset = value
      case .failure(let error):
        ReaderTrace.emit(
          "readium", ["stage": "retrieve", "ms": elapsed(), "error": String(describing: error)])
        throw Self.classifyOpenFailure(error)
      }
      ReaderTrace.emit(
        "readium",
        ["stage": "retrieved", "ms": elapsed(), "format": String(describing: asset.format)])
      guard asset.format.conformsTo(.epub) else {
        ReaderTrace.emit("readium", ["stage": "format", "ms": elapsed(), "error": "not-epub"])
        throw EPUBRenderingOpenFailure.unopenable
      }

      // Expanded-resource admission, before the parser reads a single entry. A refusal is reported
      // as `.unopenable` because the frozen boundary has no case for it; the measurement that
      // failed is traced, so a refused book stays diagnosable without naming it.
      if case .container(let containerAsset) = asset,
        let refusal = await EPUBArchiveAdmissionCheck.refusal(for: containerAsset.container)
      {
        ReaderTrace.emit(
          "readium",
          ["stage": "admission", "ms": elapsed(), "refusal": String(describing: refusal)])
        throw EPUBRenderingOpenFailure.unopenable
      }

      let newPublication: Publication
      switch await opener.open(asset: asset, allowUserInteraction: false) {
      case .success(let value):
        newPublication = value
      case .failure(let error):
        ReaderTrace.emit(
          "readium", ["stage": "parse", "ms": elapsed(), "error": String(describing: error)])
        throw Self.classifyOpenFailure(error)
      }
      ReaderTrace.emit("readium", ["stage": "parsed", "ms": elapsed()])

      let positions = await Self.positions(from: newPublication)
      let readingPositions = positions?.compactMap { Self.readingPosition(from: $0) }
      let positionsByResourceHref = readingPositions.map(Self.pageNumberByResourceHref) ?? [:]
      let progressionsByResourceHref =
        readingPositions.map(Self.startProgressionByResourceHref) ?? [:]
      ReaderTrace.emit(
        "readium",
        ["stage": "positions", "ms": elapsed(), "count": String(positions?.count ?? -1)])
      let progressionLocator: Locator?
      if case .totalProgression(let progression) = request.initialLocation {
        progressionLocator = await newPublication.locate(progression: progression)
      } else {
        progressionLocator = nil
      }
      let initialLocation = Self.resolveInitialLocation(
        for: request.initialLocation,
        positions: positions,
        progressionLocator: progressionLocator
      )
      navigatorTarget = initialLocation.target
      let toc = await Self.tableOfContents(from: newPublication)
      currentPreferences = request.preferences
      let preferences = Self.epubPreferences(
        for: request.preferences,
        systemTheme: systemTheme
      )
      let navigatorConfiguration = EPUBNavigatorViewController.Configuration(
        preferences: preferences,
        contentInset: Self.contentInsets,
        readiumCSSRSProperties: Self.readingSystemProperties
      )
      let newNavigator = try EPUBNavigatorViewController(
        publication: newPublication,
        initialLocation: initialLocation.locator,
        config: navigatorConfiguration
      )

      ReaderTrace.emit(
        "readium",
        ["stage": "navigator", "ms": elapsed(), "target": initialLocation.target]
      )

      newNavigator.delegate = self
      let reflowable = Self.isReflowable(newPublication)

      // Do not disturb the current publication until parsing, metadata extraction, and navigator
      // creation all succeed. This is the protocol's failed-second-open guarantee.
      closeCurrentPublication()
      publication = newPublication
      navigator = newNavigator
      lifecycle.openSucceeded()
      beginPublicationStreams()
      install(newNavigator)
      installInputObserver(on: newNavigator)

      let opened = OpenedEPUBPublication(
        toc: Self.flattenTOC(
          toc,
          positionsByResourceHref: positionsByResourceHref,
          progressionsByResourceHref: progressionsByResourceHref),
        positions: readingPositions,
        reflowable: reflowable
      )
      openedPublication = opened
      ReaderTrace.emit(
        "readium",
        ["stage": "ready", "ms": elapsed(), "reflowable": reflowable ? "1" : "0"])
      return opened
    } catch let failure as EPUBRenderingOpenFailure {
      lifecycle.openFailed()
      throw failure
    } catch {
      // The navigator's own initialiser is the only throw that reaches here, and its error is the
      // one `classifyOpenFailure` is least likely to recognise.
      ReaderTrace.emit(
        "readium",
        [
          "stage": "navigator", "ms": elapsed(), "target": navigatorTarget,
          "error": String(describing: error),
        ]
      )
      lifecycle.openFailed()
      throw Self.classifyOpenFailure(error)
    }
  }

  func close() async {
    guard lifecycle.state == .publicationOpen else { return }
    closeCurrentPublication()
  }

  func stop() async {
    closeCurrentPublication()
    lifecycle.stop()
  }

  func go(to position: ReadingPosition) async throws {
    guard lifecycle.state == .publicationOpen, let navigator else {
      throw ReadiumEPUBRendererError.noPublication
    }
    guard await navigator.go(to: Self.locator(from: position), options: .none) else {
      throw ReadiumEPUBRendererError.navigationFailed
    }
  }

  func turnPage(_ direction: ReaderPageDirection) async -> Bool {
    guard lifecycle.state == .publicationOpen, let navigator else { return false }
    // `goLeft`/`goRight` exist only as nonisolated defaults on `VisualNavigator`, so calling them
    // would carry the navigator's main-actor-isolated conformance into a nonisolated context, an
    // error under the Swift 6 language mode. `goForward`/`goBackward` and `presentation` are
    // declared on the navigator itself and stay on the main actor, so the reading-progression
    // mapping those defaults perform is applied here instead.
    let forward: Bool
    switch (direction, navigator.presentation.readingProgression) {
    case (.left, .ltr), (.right, .rtl): forward = false
    case (.right, .ltr), (.left, .rtl): forward = true
    }
    return forward
      ? await navigator.goForward(options: .none)
      : await navigator.goBackward(options: .none)
  }

  func go(toTotalProgression progression: Double) async throws {
    guard lifecycle.state == .publicationOpen, let publication, let navigator else {
      throw ReadiumEPUBRendererError.noPublication
    }
    guard let locator = await publication.locate(progression: progression) else {
      throw ReadiumEPUBRendererError.navigationFailed
    }
    guard await navigator.go(to: locator, options: .none) else {
      throw ReadiumEPUBRendererError.navigationFailed
    }
  }

  func submit(preferences: ReaderPreferences) async throws {
    guard lifecycle.state == .publicationOpen, let navigator else {
      throw ReadiumEPUBRendererError.noPublication
    }
    currentPreferences = preferences
    let mapped = Self.epubPreferences(for: preferences, systemTheme: systemTheme)
    navigator.submitPreferences(mapped)
    setBackgroundColor(for: mapped)
  }

  private var systemTheme: Theme {
    hostViewController.traitCollection.userInterfaceStyle == .dark ? .dark : .light
  }

  private func closeCurrentPublication() {
    cancelSearchState()
    guard publication != nil || navigator != nil else { return }

    for token in inputObserverTokens {
      navigator?.removeObserver(token)
    }
    inputObserverTokens.removeAll()
    navigator?.delegate = nil
    hostViewController.removeChildViewController()
    navigator = nil
    publication = nil
    openedPublication = nil
    finishPublicationStreams()
    lifecycle.close()
  }

  private func beginPublicationStreams() {
    let position = Self.makeStream(ReadingPosition.self)
    positionStream = position.stream
    positionContinuation = position.continuation

    let taps = Self.makeStream(ReadiumEPUBTapZone.self)
    tapStream = taps.stream
    tapContinuation = taps.continuation
  }

  private func finishPublicationStreams() {
    positionContinuation?.finish()
    positionContinuation = nil
    tapContinuation?.finish()
    tapContinuation = nil
  }

  private func install(_ navigator: EPUBNavigatorViewController) {
    let mapped = Self.epubPreferences(for: currentPreferences, systemTheme: systemTheme)
    setBackgroundColor(for: mapped)
    hostViewController.install(navigator)
  }

  private func setBackgroundColor(for preferences: EPUBPreferences) {
    guard let color = preferences.backgroundColor?.uiColor else { return }
    hostViewController.view.backgroundColor = color
    navigator?.view.backgroundColor = color
  }

  private func installInputObserver(on navigator: EPUBNavigatorViewController) {
    let token = navigator.addObserver(
      .tap { [weak self, weak navigator] event in
        let width = navigator?.view.bounds.width ?? 0
        self?.tapContinuation?.yield(Self.tapZone(for: event.location.x, width: width))
        return false
      }
    )
    inputObserverTokens.insert(token)
  }

  private static func positions(from publication: Publication) async -> [Locator]? {
    switch await publication.positions() {
    case .success(let positions):
      return positions
    case .failure:
      return nil
    }
  }

  private static func tableOfContents(from publication: Publication) async -> [ReadiumLink] {
    switch await publication.tableOfContents() {
    case .success(let links):
      return links
    case .failure:
      return []
    }
  }

  private static func isReflowable(_ publication: Publication) -> Bool {
    switch publication.metadata.layout {
    case .fixed?: return false
    default: return true
    }
  }

  private static func makeStream<Element>(
    _ type: Element.Type
  ) -> (stream: AsyncStream<Element>, continuation: AsyncStream<Element>.Continuation) {
    var continuation: AsyncStream<Element>.Continuation!
    let stream = AsyncStream<Element>(bufferingPolicy: .bufferingNewest(1)) {
      continuation = $0
    }
    return (stream, continuation)
  }

  func navigator(_ navigator: Navigator, presentError error: NavigatorError) {}

  func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
    guard let position = Self.readingPosition(from: locator) else {
      ReaderTrace.emit("readium", ["stage": "position", "error": "href-bound"])
      return
    }
    positionContinuation?.yield(position)
  }
}
