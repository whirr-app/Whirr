import AppModel
import CarPlay
import Observation
import PlayerCore

/// One car scene's templates and navigation.
///
/// Owns no playback or data: lists come from the current graph's browse model, taps go to its
/// action facade, and Now Playing is the system's shared template. It owns what only a scene can:
/// which templates exist, the stack, and ending every tap's completion once.
@MainActor
final class CarPlayCoordinator {
  private final class Screen {
    let template: CPListTemplate
    var content: CarPlayListContent?
    var items: [String: CPListItem] = [:]
    var rows: [String: CarPlayBrowseRow] = [:]
    var imaged: Set<String> = []

    init(title: String) {
      template = CPListTemplate(title: title, sections: [])
    }
  }

  private struct RootKey: Equatable {
    let state: CarPlayRootState
    let generation: Int?
    let layout: CarPlayRootLayout?
  }

  /// Thumbnails held for the lists a listener can move between without a new read.
  private static let artworkCapacity = 80

  private let environment: CarPlayEnvironment
  private let interface: any CarPlayInterface
  private let nowPlaying: any CarPlayNowPlayingSurface
  private let selections = CarPlaySelectionOperations()

  private var isConnected = false
  private var rootKey: RootKey?
  private var rootTemplate: CPTemplate?
  private var graph: CarPlayGraph?
  private var navigation = CarPlayNavigation()
  private var screens: [CarPlayScreen: Screen] = [:]
  private var pagedLists: [CarPlayBrowseRoute: CarPlayPagedList] = [:]
  private var artwork: CarPlayArtworkRequests<UIImage>?
  private var selectedTab = CarPlayTab.continueListening
  private var controls: CarPlayNowPlayingControls?
  private var lastSelection: CarPlaySelection?
  private var alertIsShown = false
  private var renderEpoch = 0

  init(
    environment: CarPlayEnvironment, interface: any CarPlayInterface,
    nowPlaying: any CarPlayNowPlayingSurface
  ) {
    self.environment = environment
    self.interface = interface
    self.nowPlaying = nowPlaying
  }

  // MARK: - Scene lifecycle

  /// Puts a root on screen before returning, as the connection callback requires, and fills it
  /// in afterwards. Connecting never starts playback.
  func connect() {
    guard isConnected == false else { return }
    isConnected = true
    nowPlaying.onChapters = { [weak self] in self?.show(.chapters) }
    nowPlaying.onUpNext = { [weak self] in self?.show(.upNext) }
    nowPlaying.onRate = { [weak self] in self?.cycleRate() }
    environment.start()
    refresh()
    track { [weak self] in self?.renderPlayer() }
  }

  /// Ends every wait and releases the scene's templates and thumbnails. Playback is left as it
  /// is: whether audio pauses when the car goes away is the audio route's decision.
  func disconnect() {
    guard isConnected else { return }
    isConnected = false
    discardGraph()
    nowPlaying.detach()
    rootKey = nil
    rootTemplate = nil
  }

  /// The car's restrictions or appearance changed.
  func limitsChanged() { refresh() }

  /// Memory is short: drop every thumbnail, then ask again for the ones on screen.
  func purgeArtwork() {
    artwork?.purge()
    for screen in screens.values { screen.imaged = [] }
    refresh()
  }

  /// The car put `template` on top: a push or pop finished, the listener went back, or the
  /// system opened Now Playing itself.
  func appeared(_ template: CPTemplate) {
    guard isConnected else { return }
    if template === nowPlaying.template {
      navigation.appeared(.nowPlaying)
    } else if template === rootTemplate {
      navigation.appeared(.root)
    } else if let screen = screens.first(where: { $0.value.template === template })?.key {
      if case .tab(let tab) = screen, navigation.stack.contains(screen) == false {
        // A tab bar child: still the root level, now showing this tab.
        selectedTab = tab
        navigation.appeared(.root)
      } else {
        navigation.appeared(screen)
      }
    }
    releaseHiddenScreens()
    refresh()
  }

  // MARK: - Rendering

  private func track(_ body: @escaping @MainActor () -> Void) {
    withObservationTracking {
      body()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.isConnected else { return }
        self.track(body)
      }
    }
  }

  /// Renders and follows what the render read. A direct call matters as much as a change: a
  /// list pushed since the last render is read here for the first time, and would otherwise
  /// never be followed.
  private func refresh() {
    renderEpoch += 1
    let epoch = renderEpoch
    withObservationTracking {
      render()
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        // An older registration is covered by the newer one.
        guard let self, self.isConnected, self.renderEpoch == epoch else { return }
        self.refresh()
      }
    }
  }

  private func render() {
    guard isConnected else { return }
    let limits = environment.limits()
    let state = environment.rootState()
    let current = state == .ready ? environment.graph() : nil
    let key = RootKey(
      // Ready without a graph is the moment between a replacement and its lists.
      state: state == .ready && current == nil ? .starting : state,
      generation: current?.generation,
      layout: current == nil ? nil : CarPlayRootLayout(maximumTabCount: limits.maximumTabCount))
    if key != rootKey { rebuildRoot(key, graph: current) }
    for (screen, entry) in screens { update(entry, with: content(for: screen, limits: limits)) }
    updateNowPlayingButtons()
    requestArtwork(limits)
  }

  private func renderPlayer() {
    guard isConnected, let graph else { return }
    let state = graph.playerState()
    let next = CarPlayNowPlayingControls(
      state: state, effectiveRate: graph.effectiveRate(state.item?.id), presets: environment.presets(),
      generation: graph.generation)
    if next != controls {
      controls = next
      updateNowPlayingButtons()
      if let chapters = screens[.chapters] {
        update(chapters, with: content(for: .chapters, limits: environment.limits()))
      }
    }
    if let failure = selections.lateFailure(in: state) { apply(CarPlayFeedback(failure)) }
  }

  private func updateNowPlayingButtons() {
    guard let graph else {
      nowPlaying.show(CarPlayNowPlayingButtons())
      return
    }
    var hasQueue = false
    if case .rows(let rows) = graph.snapshot(.upNext)?.content { hasQueue = rows.isEmpty == false }
    nowPlaying.show(
      CarPlayNowPlayingButtons(
        showsChapters: controls?.chapters != nil, showsRate: controls?.nextRate != nil, showsUpNext: hasQueue))
  }

  private func rebuildRoot(_ key: RootKey, graph: CarPlayGraph?) {
    discardGraph()
    rootKey = key
    self.graph = graph
    let root: CPTemplate
    if let graph, let layout = key.layout {
      graph.start()
      artwork = CarPlayArtworkRequests(capacity: Self.artworkCapacity, load: graph.loadArtwork)
      switch layout {
      case .tabs(let tabs):
        let templates = tabs.map { tab in
          let screen = Screen(title: tab.title)
          screen.template.tabTitle = tab.title
          screen.template.tabImage = UIImage(systemName: Self.symbol(for: tab))
          screens[.tab(tab)] = screen
          return screen.template
        }
        selectedTab = tabs.first ?? .continueListening
        root = CPTabBarTemplate(templates: templates)
      case .list:
        let screen = Screen(title: "Whirr")
        screens[.root] = screen
        root = screen.template
      }
    } else {
      let status = CPListTemplate(title: "Whirr", sections: [])
      if let message = key.state.message {
        status.emptyViewTitleVariants = [message.title]
        status.emptyViewSubtitleVariants = [message.detail]
      }
      root = status
    }
    rootTemplate = root
    interface.setRoot(root)
    renderPlayer()
  }

  /// Everything that belonged to the outgoing graph: its waits, reads, thumbnails and templates.
  private func discardGraph() {
    selections.cancelAll()
    artwork?.purge()
    artwork = nil
    for list in pagedLists.values { list.cancel() }
    pagedLists = [:]
    screens = [:]
    navigation.reset()
    controls = nil
    graph = nil
    lastSelection = nil
    if alertIsShown {
      alertIsShown = false
      interface.dismissAlert()
    }
    nowPlaying.show(CarPlayNowPlayingButtons())
  }

  private func content(for screen: CarPlayScreen, limits: CarPlayLimits) -> CarPlayListContent {
    guard let graph else { return .loading }
    let maximum = limits.maximumItemCount
    switch screen {
    case .root:
      return .rootList(CarPlayTab.allCases)
    case .tab(.continueListening):
      return .observed(graph.snapshot(.continueListening), leading: [.resume], maximumItemCount: maximum)
    case .tab(.books):
      // Under a root list the Books screen is already a level down, and an author's books would
      // leave Now Playing no place.
      let leading: [CarPlayListContent.Entry] =
        rootTemplate is CPTabBarTemplate ? [.allBooks, .authors, .series] : [.allBooks]
      return .observed(
        graph.snapshot(.recentBooks), leading: leading, header: "Recently Added", maximumItemCount: maximum)
    case .tab(.podcasts):
      return .podcasts(
        latest: graph.snapshot(.latestEpisodes), shows: pagedList(.podcastShows, limits: limits),
        maximumItemCount: maximum)
    case .tab(.downloads):
      return .paged(pagedList(.downloads, limits: limits), maximumItemCount: maximum)
    case .list(let route):
      return .paged(pagedList(route, limits: limits), maximumItemCount: maximum)
    case .upNext:
      return .observed(graph.snapshot(.upNext), maximumItemCount: maximum)
    case .chapters:
      return .chapters(controls?.chapters, maximumItemCount: maximum)
    case .nowPlaying:
      return .loading
    }
  }

  private func pagedList(_ route: CarPlayBrowseRoute, limits: CarPlayLimits) -> CarPlayPagedList {
    if let list = pagedLists[route] { return list }
    var capacity = limits.maximumItemCount
    if route == .podcastShows {
      capacity -= CarPlayListContent.latestEpisodeSlots(maximumItemCount: capacity)
    }
    // A car too restricted to page gets one bounded page, and the list says it is partial.
    let pageSize =
      CarPlayListLayout.pageSize(maximumItemCount: capacity, productLimit: CarPlayBrowseModel.maximumPageSize)
      ?? max(1, capacity)
    let list = CarPlayPagedList(route: route) { [graph] cursor in
      await graph?.page(route, cursor, pageSize) ?? .rejected(.staleGeneration)
    }
    pagedLists[route] = list
    list.load()
    return list
  }

  private func update(_ screen: Screen, with content: CarPlayListContent) {
    guard screen.content != content else { return }
    screen.content = content
    var items: [String: CPListItem] = [:]
    var rows: [String: CarPlayBrowseRow] = [:]
    let sections = content.sections.map { section in
      CPListSection(
        items: section.entries.map { entry -> CPListItem in
          guard case .row(let row) = entry else { return item(for: entry) }
          // An unchanged row keeps its item, and with it the car's focus and its thumbnail.
          let item = screen.rows[row.id] == row ? screen.items[row.id] ?? item(for: entry) : item(for: entry)
          items[row.id] = item
          rows[row.id] = row
          return item
        }, header: section.header, sectionIndexTitle: nil)
    }
    screen.imaged = screen.imaged.filter { items[$0] != nil && items[$0] === screen.items[$0] }
    screen.items = items
    screen.rows = rows
    screen.template.emptyViewTitleVariants = content.emptyTitle.map { [$0] } ?? []
    screen.template.updateSections(sections)
  }

  private func item(for entry: CarPlayListContent.Entry) -> CPListItem {
    switch entry {
    case .tab(let tab):
      return link(tab.title) { [weak self] in self?.show(.tab(tab)) }
    case .allBooks:
      return link("All Books", to: .audiobooks)
    case .authors:
      return link("Authors", to: .authors)
    case .series:
      return link("Series", to: .series)
    case .previous(let route):
      return link("Previous") { [weak self] in self?.pagedLists[route]?.showPrevious() }
    case .next(let route):
      return link("More") { [weak self] in self?.pagedLists[route]?.showNext() }
    case .resume:
      let item = CPListItem(text: "Resume", detailText: "Pick up where you left off")
      item.handler = { [weak self] _, completion in self?.select(.resumeLastPlayed, completion) ?? completion() }
      return item
    case .row(let row):
      if let child = row.child {
        let item = link(row.title, to: child)
        item.setDetailText(row.subtitle)
        return item
      }
      let item = CPListItem(text: row.title, detailText: row.subtitle)
      item.isEnabled = row.isPlayable
      if let progress = row.progress { item.playbackProgress = progress }
      if let identity = row.identity {
        let chapter = row.chapter
        item.handler = { [weak self] _, completion in
          self?.select(.play(identity, chapter: chapter), completion) ?? completion()
        }
      }
      return item
    case .chapter(let row):
      let item = CPListItem(text: row.title, detailText: nil)
      item.isPlaying = row.isCurrent
      item.handler = { [weak self] _, completion in
        self?.selectChapter(row)
        completion()
      }
      return item
    }
  }

  private func link(_ title: String, _ action: @escaping @MainActor () -> Void) -> CPListItem {
    let item = CPListItem(text: title, detailText: nil)
    item.accessoryType = .disclosureIndicator
    item.handler = { _, completion in
      action()
      completion()
    }
    return item
  }

  private func link(_ title: String, to route: CarPlayBrowseRoute) -> CPListItem {
    let item = CPListItem(text: title, detailText: nil)
    item.accessoryType = .disclosureIndicator
    item.handler = { [weak self] _, completion in self?.open(route, completion) ?? completion() }
    return item
  }

  /// Pushes a paged list once its first page has an answer. Until then the car keeps its spinner
  /// on the tapped row, which reads better than an empty list filling in.
  private func open(_ route: CarPlayBrowseRoute, _ completion: @escaping () -> Void) {
    guard isConnected, graph != nil else {
      completion()
      return
    }
    let origin = navigation.top
    let tab = selectedTab
    let list = pagedList(route, limits: environment.limits())
    Task { [weak self] in
      await list.settled()
      defer { completion() }
      guard let self, self.pagedLists[route] === list else { return }
      // The listener moved on while the page was read: the push is no longer theirs.
      let stayed = self.navigation.top == origin && self.selectedTab == tab
      if stayed == false || self.show(.list(route)) == false, self.screens[.list(route)] == nil {
        self.pagedLists.removeValue(forKey: route)?.cancel()
      }
    }
  }

  // MARK: - Selection

  /// `completion` is the car's: it is called exactly once, whatever becomes of the selection.
  private func select(_ selection: CarPlaySelection, _ completion: @escaping () -> Void) {
    guard let graph else {
      completion()
      return
    }
    lastSelection = selection
    Task { [weak self, selections] in
      let outcome = await selections.select(selection) { await graph.perform(selection) }
      completion()
      // An outcome for a graph or a scene that has gone is not this screen's to show.
      guard let self, self.isConnected, self.graph?.generation == graph.generation else { return }
      self.apply(CarPlayFeedback(outcome))
    }
  }

  private func selectChapter(_ row: CarPlayChapterRow) {
    guard let graph, let list = controls?.chapters else { return }
    if graph.selectChapter(row, list) == .accepted { show(.nowPlaying) }
  }

  private func cycleRate() {
    guard let graph, let next = controls?.nextRate else { return }
    // A refused write raises the phone's existing alert; the button redraws from the player.
    _ = graph.setRate(next)
  }

  private func apply(_ feedback: CarPlayFeedback) {
    switch feedback {
    case .none:
      break
    case .showNowPlaying:
      show(.nowPlaying)
    case .reload:
      rootKey = nil
      refresh()
    case .alert(let alert):
      present(alert)
    }
  }

  private func present(_ alert: CarPlayAlert) {
    var actions: [CPAlertAction] = []
    if alert.canRetry, let selection = lastSelection {
      actions.append(
        CPAlertAction(title: "Try Again", style: .default) { [weak self] _ in
          self?.dismissAlert()
          self?.select(selection) {}
        })
    }
    actions.append(CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in self?.dismissAlert() })
    alertIsShown = true
    interface.presentAlert(CPAlertTemplate(titleVariants: alert.titleVariants, actions: actions))
  }

  private func dismissAlert() {
    guard alertIsShown else { return }
    alertIsShown = false
    interface.dismissAlert()
  }

  // MARK: - Navigation

  @discardableResult
  private func show(_ screen: CarPlayScreen) -> Bool {
    guard isConnected, graph != nil, let steps = navigation.show(screen) else { return false }
    for step in steps {
      switch step {
      case .push(let screen): template(for: screen).map(interface.push)
      case .pop(let screen): template(for: screen).map(interface.pop(to:))
      }
    }
    releaseHiddenScreens()
    refresh()
    return true
  }

  private func template(for screen: CarPlayScreen) -> CPTemplate? {
    switch screen {
    case .root: return rootTemplate
    case .nowPlaying: return nowPlaying.template
    case .tab, .list, .upNext, .chapters:
      if let existing = screens[screen] { return existing.template }
      let created = Screen(title: Self.title(for: screen))
      screens[screen] = created
      return created.template
    }
  }

  /// Drops the templates and reads of pushed lists that are no longer on the stack.
  private func releaseHiddenScreens() {
    let tabsAreRoot = rootTemplate is CPTabBarTemplate
    for screen in screens.keys where navigation.stack.contains(screen) == false {
      switch screen {
      case .root, .nowPlaying:
        continue
      case .tab:
        if tabsAreRoot { continue }
      case .list(let route):
        pagedLists.removeValue(forKey: route)?.cancel()
      case .upNext, .chapters:
        break
      }
      screens[screen] = nil
    }
  }

  // MARK: - Thumbnails

  /// Only the list on screen asks for artwork; rows are already drawn with their text.
  private func requestArtwork(_ limits: CarPlayLimits) {
    guard let artwork, let graph else { return }
    var visible = navigation.top
    if visible == .root, rootTemplate is CPTabBarTemplate { visible = .tab(selectedTab) }
    guard let screen = screens[visible] else {
      artwork.show([]) { _, _ in }
      return
    }
    func key(_ row: CarPlayBrowseRow) -> CarPlayArtworkKey {
      CarPlayArtworkKey(
        generation: graph.generation, reference: row.artwork, pixelSize: limits.imagePixelSize,
        isDark: limits.isDark)
    }
    let rows = screen.rows.values.filter { screen.imaged.contains($0.id) == false }
    let held = artwork.show(rows.map(key)) { [weak self, weak screen] loaded, image in
      guard let self, let screen, self.screens[visible] === screen else { return }
      for row in screen.rows.values where key(row) == loaded { self.setImage(image, row.id, on: screen) }
    }
    for row in rows { held[key(row)].map { setImage($0, row.id, on: screen) } }
  }

  private func setImage(_ image: UIImage, _ rowID: String, on screen: Screen) {
    guard screen.imaged.insert(rowID).inserted else { return }
    screen.items[rowID]?.setImage(image)
  }

  private static func title(for screen: CarPlayScreen) -> String {
    switch screen {
    case .root, .nowPlaying: "Whirr"
    case .tab(let tab): tab.title
    case .list(.audiobooks): "All Books"
    case .list(.authors): "Authors"
    case .list(.series): "Series"
    case .list(.authorBooks(let name)), .list(.seriesBooks(let name)): name
    case .list(.latestEpisodes): "New Episodes"
    case .list(.showEpisodes): "Episodes"
    case .list(.downloads): "Downloads"
    case .list(.podcastShows): "Podcasts"
    case .list(.recentBooks): "Recently Added"
    case .list(.continueListening): "Continue"
    case .list(.upNext), .upNext: "Up Next"
    case .chapters: "Chapters"
    }
  }

  private static func symbol(for tab: CarPlayTab) -> String {
    switch tab {
    case .continueListening: "play.circle"
    case .books: "book"
    case .podcasts: "antenna.radiowaves.left.and.right"
    case .downloads: "arrow.down.circle"
    }
  }
}
