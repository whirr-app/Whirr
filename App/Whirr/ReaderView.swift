import AppModel
import DesignSystem
import Persistence
import ReaderCore
import SwiftUI
import SyncEngine

/// Which sheet, if any, the reader opens with. Production always passes `nil`; the harness uses it
/// to land directly on a panel without simulating a tap.
enum ReaderPanel: Equatable {
  case appearance
  case toc
  case search
}

struct ReaderView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) var systemColorScheme
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @State var model: ReaderModel
  @State var brightnessController: ReaderBrightnessController?
  @State var brightnessLevel = 0.0
  @State var isShowingAppearance = false
  @State var appearanceDetent: PresentationDetent = .medium
  /// The open book's passage for the appearance sample, read when Customise opens.
  @State var sampleText: String?
  /// The page's frame in global coordinates, measured for the rail.
  @State private var pageFrame: CGRect = .zero
  /// Where the bottom bar placed the rail's leading edge, in global coordinates.
  @State private var railLeading: CGFloat?
  /// The page a release would land on while a finger is on the rail. Held past the release until
  /// the seek reports its landing, so the readout never flicks back to the page being left.
  @State private var scrubPreview: ReaderProgressDisplay?
  @State private var isScrubSettling = false
  @State var isShowingTOC = false
  @State var isShowingSearch = false
  @State var pendingSearchHitID: String?
  @State var draftTheme: DesignSystem.ReaderTheme = .light
  @State var draftFontFamily: DesignSystem.ReaderFontFamily = .publisher
  @State var draftAlignment: DesignSystem.ReaderTextAlignment = .publisherDefault
  @State var draftFontSize = 0.0
  @State var draftPublisherStyles = true
  @State var draftLineSpacing = 0.0
  @State var draftWordSpacing = 0.0
  @State var draftLetterSpacing = 0.0
  @State var draftParagraphSpacing = 0.0
  @State var draftHyphenation = false
  @State var draftMargins = 0.0
  @State var draftScrollMode = false

  let title: String
  let renderer: any EPUBRendering
  let onThemeChange: (DesignSystem.ReaderTheme?) -> Void
  let injectedTOC: [TOCEntry]
  let initialPanel: ReaderPanel?
  /// Where the reader lands on this opening, when it was raised from a contents entry.
  let initialTarget: ReaderRestoreTarget?

  init(
    itemID: String,
    title: String,
    category: ItemMediaCategory,
    stateReading: any ReaderStateReading,
    progress: any ReaderProgressAccessing,
    extrasAccess: any ItemDetailExtrasAccess = NoOpItemDetailExtrasAccess(),
    preferencesStore: any ReaderPreferencesStoring,
    downloadIntents: any DownloadIntents,
    renderer: any EPUBRendering,
    appLifecycle: any AppLifecycle,
    playback: PlaybackModel? = nil,
    onThemeChange: @escaping (DesignSystem.ReaderTheme?) -> Void = { _ in },
    injectedTOC: [TOCEntry] = [],
    initialPanel: ReaderPanel? = nil,
    initialTarget: ReaderRestoreTarget? = nil
  ) {
    self.title = title
    self.initialTarget = initialTarget
    self.renderer = renderer
    self.onThemeChange = onThemeChange
    self.injectedTOC = injectedTOC
    self.initialPanel = initialPanel
    let playbackInterlock: any ReaderPlaybackInterlock
    if let playback {
      playbackInterlock = PlaybackReaderInterlock(playback: playback)
    } else {
      playbackInterlock = NoOpReaderPlaybackInterlock()
    }
    _model = State(
      initialValue: ReaderModel(
        itemID: itemID,
        category: category,
        stateReading: stateReading,
        progress: progress,
        extrasAccess: extrasAccess,
        preferencesStore: preferencesStore,
        downloadIntents: downloadIntents,
        renderer: renderer,
        appLifecycle: appLifecycle,
        playbackInterlock: playbackInterlock
      ))
  }

  var theme: DesignSystem.ReaderTheme {
    ReaderPresentation.designTheme(
      for: model.preferences.theme, systemScheme: systemColorScheme)
  }

  var palette: ReaderThemePalette { theme.palette }

  private var isReading: Bool {
    if case .reading = model.state { return true }
    return false
  }

  /// The renderer is not `@Observable`, so `isSearchable` alone is read once: a book that finishes
  /// opening after the chrome first draws would leave the action hidden until something unrelated
  /// invalidated the body. Pairing it with the model state that flips on open gives a dependency.
  private var isSearchable: Bool { isReading && renderer.isSearchable }

  var tocEntries: [TOCEntry] {
    (renderer as? ReadiumEPUBRenderer)?.openedPublication?.toc ?? injectedTOC
  }

  var body: some View {
    // The stack exists for its bars: the chrome is the system's own glass toolbar, drawn over a
    // page that ignores the safe area those bars add, so showing them never moves or reflows it.
    NavigationStack {
      readerPage
        // Measured for the rail, which a bottom-bar item cannot stretch across on its own.
        .onGeometryChange(for: CGRect.self) {
          $0.frame(in: .global)
        } action: {
          pageFrame = $0
        }
        .toolbar { readerToolbar }
        .toolbarVisibility(
          ReaderPresentation.toolbarVisibility(chromeVisible: model.isChromeVisible),
          for: .bottomBar
        )
        // With no scroll view under Readium for the bar to track, it otherwise draws an opaque
        // band behind the glass controls.
        .toolbarBackgroundVisibility(.hidden, for: .bottomBar)
        // Inside the stack so the bottom safe area includes the toolbar: the offer rides above
        // the bar while the chrome shows and drops to the home indicator when it hides.
        .overlay(alignment: .bottom) { returnOffer }
    }
    .animation(ReaderChromeMotion.animation(reduceMotion: reduceMotion), value: model.returnPoint)
    // Driven by the value rather than by `withAnimation` at the toggle sites:
    // `ReaderModel.turnPage(fromTap:)` hides the chrome from inside the model, where the view has
    // no call site to wrap.
    .animation(
      ReaderChromeMotion.animation(reduceMotion: reduceMotion),
      value: model.isChromeVisible
    )
    .environment(\.colorScheme, theme == .dark ? .dark : .light)
    .statusBarHidden(
      ReaderPresentation.isStatusBarHidden(chromeVisible: model.isChromeVisible)
    )
    // The cover's own window preference. `RootView` resolves the same value for the shell, but a
    // presenting view's preference does not reach a full-screen cover's status bar.
    .preferredColorScheme(ReaderPresentation.windowScheme(for: theme))
    // Give the screen its own container so its identifier cannot replace the page/control IDs.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(ReaderAccessibilityID.screen)
    .task {
      if let screen = SystemScreenBrightness() {
        let controller = ReaderBrightnessController(
          screen: screen,
          store: DefaultsReaderBrightnessStore()
        )
        brightnessLevel = screen.brightness
        controller.enterReader()
        brightnessController = controller
      }
      onThemeChange(theme)
      await model.open(initialTarget: initialTarget)
      syncAppearanceDraft(with: model.preferences)
      onThemeChange(theme)
      switch initialPanel {
      case .appearance: isShowingAppearance = true
      case .toc: isShowingTOC = true
      case .search:
        if isSearchable { isShowingSearch = true }
      case nil: break
      }
    }
    .task(id: isReading) {
      guard isReading, let readium = renderer as? ReadiumEPUBRenderer else { return }
      readium.hostViewController.onPageSwipe = { [model] in model.pageSwiped() }
      defer { readium.hostViewController.onPageSwipe = nil }
      for await zone in readium.tapEvents {
        guard isReading else { return }
        handle(ReaderPresentation.intent(for: zone))
      }
    }
    .onChange(of: model.progressDisplay) {
      if isScrubSettling {
        isScrubSettling = false
        scrubPreview = nil
      }
    }
    // A seek that never reports back must not leave the readout on its preview.
    .task(id: isScrubSettling) {
      guard isScrubSettling else { return }
      try? await Task.sleep(for: .seconds(3))
      if Task.isCancelled == false {
        isScrubSettling = false
        scrubPreview = nil
      }
    }
    .onChange(of: model.preferences) { _, preferences in
      syncAppearanceDraft(with: preferences)
      onThemeChange(
        ReaderPresentation.designTheme(for: preferences.theme, systemScheme: systemColorScheme))
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard let brightnessController else { return }
      switch newPhase {
      case .active:
        brightnessController.didBecomeActive()
      case .inactive, .background:
        brightnessController.willResignActive()
      @unknown default:
        break
      }
    }
    .onDisappear {
      onThemeChange(nil)
      // The back button restores through `ReaderPresentation.dismiss`, early enough that the
      // library is never revealed at the borrowed level. This is the backstop for every other way
      // the cover can go away: a logout or an environment rebuild tears the reader down without
      // ever calling `close()`, and launch recovery would not run again until the next launch.
      // `leaveReader()` is idempotent, so the ordinary path still restores once.
      brightnessController?.leaveReader()
      Task { await model.close() }
    }
    .sheet(isPresented: $isShowingAppearance) {
      appearanceSheet
        .accessibilityIdentifier(ReaderAccessibilityID.appearanceSheet)
        // A half-height glass sheet leaves the page visible above it, so each change is seen as
        // it is made. Customise grows it to full height.
        .presentationDetents([.medium, .large], selection: $appearanceDetent)
        // Without this the system dims the page at every detent, hiding the change being made.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .modifier(TrailingSheetPlacement())
    }
    .sheet(isPresented: $isShowingTOC) {
      tocSheet
        .accessibilityIdentifier(ReaderAccessibilityID.tocSheet)
        .presentationDetents([.large])
    }
    .sheet(isPresented: $isShowingSearch, onDismiss: navigateToPendingSearchHit) {
      searchSheet
        .accessibilityIdentifier(ReaderAccessibilityID.searchSheet)
        .presentationDetents([.large])
    }
  }

  private var readerPage: some View {
    ZStack {
      palette.backgroundColor
        .ignoresSafeArea(edges: .all)

      // Mounted from `.opening`, not `.reading`: Readium finishes a navigation only once the
      // navigator's web view has laid out, which needs it in a window, and the restore that
      // gates `.reading` is itself a navigation. See `ReaderModel.isPageMounted`.
      if model.isPageMounted {
        ReadiumSurface(renderer: renderer)
          // Covered, never hidden: `.hidden()` or a zero opacity would stop the web view laying
          // out, which is the deadlock above. This only keeps the occluded page out of the
          // accessibility tree, where it would otherwise duplicate the state view's identifier.
          .accessibilityHidden(model.isPageObscured)
          .accessibilityIdentifier(ReaderAccessibilityID.page)
          .accessibilityLabel("Book page")
          .accessibilityAction(named: Text("Turn page left")) {
            turnPage(.left)
          }
          .accessibilityAction(named: Text("Turn page right")) {
            turnPage(.right)
          }
          .accessibilityAction(
            named: Text(ReaderCopy.readerControlsActionLabel(chromeVisible: model.isChromeVisible))
          ) {
            model.toggleChrome()
          }
      }

      if let furniture = ReaderPageFurniture.make(
        isReading: isReading,
        isReflowable: model.reflowControlsEnabled,
        isScrollMode: model.preferences.isScrollMode,
        bookTitle: title,
        footerReadout: model.preferences.footerReadout,
        progress: model.progressDisplay)
      {
        ReaderPageFurnitureView(
          furniture: furniture, chromeVisible: model.isChromeVisible, palette: palette,
          onSelectFooterReadout: { readout in Task { await model.selectFooterReadout(readout) } })
      }

      // The opaque cover, drawn over the mounted page rather than instead of it.
      if model.isPageObscured {
        palette.backgroundColor
          .ignoresSafeArea(edges: .all)
        ReaderStateView(model: model, theme: theme)
      }

    }
  }

  @ToolbarContentBuilder
  private var readerToolbar: some ToolbarContent {
    // Inserted and removed as a toolbar item rather than hiding the navigation bar, which the
    // system slides off the top instead of fading like the bottom bar.
    if model.isChromeVisible {
      ToolbarItem(placement: .topBarLeading) {
        Button(role: .close, action: close)
          .accessibilityLabel(ReaderCopy.closeReader)
          .accessibilityIdentifier(ReaderAccessibilityID.back)
      }
    }

    ToolbarItem(placement: .bottomBar) {
      ReaderProgressRail(
        progressFraction: model.progressDisplay.percentage,
        accessibilityLabel: ReaderCopy.readingProgress,
        accessibilityValue: ReaderCopy.progressAccessibilityValue(
          percentText: model.progressDisplay.percentText,
          pageText: model.progressDisplay.pageText),
        theme: theme,
        onAdjust: { direction in
          turnPage(direction == .increment ? .right : .left)
        },
        onSeek: { fraction in
          Task { await model.seek(toTotalProgression: fraction) }
        },
        onScrub: { preview in
          if let preview {
            isScrubSettling = false
            scrubPreview = model.scrubPreview(forTotalProgression: preview.fraction)
          } else {
            isScrubSettling = true
          }
        }
      )
      .modifier(
        ReaderRailReadoutPlacement(
          readout: scrubPreview.map { ReaderProgressReadout.make(scrubbing: $0) }
            ?? ReaderProgressReadout.make(progress: model.progressDisplay),
          palette: palette)
      )
      // Keeps the track's ends and the readout clear of the capsule's rounded ends.
      .padding(.horizontal, ReaderPresentation.railCapsuleInset)
      .frame(
        width: ReaderPresentation.railWidth(
          containerWidth: pageFrame.width, showsFinishOffer: model.isFinishOfferVisible,
          railLeading: railLeading, pageTrailing: pageFrame.maxX)
      )
      // Whole points, so the rail's settling passes end rather than chase sub-point offsets.
      .onGeometryChange(for: CGFloat.self) {
        $0.frame(in: .global).minX.rounded()
      } action: {
        railLeading = $0
      }
      .accessibilityIdentifier(ReaderAccessibilityID.progress)
    }

    if model.isFinishOfferVisible {
      ToolbarItem(placement: .bottomBar) {
        Button {
          Task { await model.markFinished() }
        } label: {
          Label(ReaderCopy.markAsFinished, systemImage: "checkmark.circle")
            .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel(ReaderCopy.markBookAsFinished)
        .accessibilityHint(ReaderCopy.markAsFinishedHint)
        .accessibilityIdentifier(ReaderAccessibilityID.finishOffer)
      }
    }

    ToolbarSpacer(.fixed, placement: .bottomBar)

    if ReaderPresentation.showsAppearanceButton(isFinishOfferVisible: model.isFinishOfferVisible) {
      ToolbarItem(placement: .bottomBar) {
        Button(action: beginAppearanceEdit) {
          Label(ReaderCopy.appearance, systemImage: ReaderMenuAction.appearance.systemImage)
        }
        .accessibilityIdentifier(ReaderMenuAction.appearance.accessibilityIdentifier)
      }
    }

    ToolbarItem(placement: .bottomBar) {
      Menu {
        let actions = ReaderPresentation.menuActions(
          isSearchable: isSearchable, isFinishOfferVisible: model.isFinishOfferVisible)
        ForEach(actions, id: \.self) { action in
          Button {
            perform(action)
          } label: {
            Label(menuTitle(for: action), systemImage: action.systemImage)
          }
          .accessibilityIdentifier(action.accessibilityIdentifier)
        }
      } label: {
        Label(ReaderCopy.readerMenu, systemImage: "ellipsis")
      }
      .accessibilityIdentifier(ReaderAccessibilityID.menu)
    }
  }

  @ViewBuilder
  private var returnOffer: some View {
    if let returnPoint = model.returnPoint, isReading {
      ReaderReturnToast(
        returnPoint: returnPoint,
        onGoBack: { Task { await model.goBack() } },
        onDismiss: { model.dismissReturnPoint() }
      )
      .padding(.bottom, 12)
      .transition(
        reduceMotion
          ? .opacity : .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)))
    }
  }

  private func menuTitle(for action: ReaderMenuAction) -> String {
    switch action {
    case .contents: ReaderCopy.contents
    case .search: ReaderCopy.search
    case .appearance: ReaderCopy.appearance
    }
  }

  private func perform(_ action: ReaderMenuAction) {
    switch action {
    case .contents: isShowingTOC = true
    case .search: isShowingSearch = true
    case .appearance: beginAppearanceEdit()
    }
  }

  private func handle(_ intent: ReaderTapIntent) {
    switch intent {
    case .toggleChrome: model.toggleChrome()
    case .turnPage(let direction): Task { await model.turnPage(fromTap: direction) }
    }
  }

  private func turnPage(_ direction: ReaderPageDirection) {
    Task { await model.turnPage(direction) }
  }

  private func close() {
    ReaderPresentation.dismiss(
      onThemeChange: onThemeChange,
      dismissCover: { dismiss() },
      leaveReader: { brightnessController?.leaveReader() })
    Task { await model.close() }
  }

  /// The sheet must finish dismissing before the navigator is asked to move. The renderer retains
  /// the hit's locator after the panel drops its stream, so this delayed handoff is still safe.
  private func navigateToPendingSearchHit() {
    guard let id = pendingSearchHitID else { return }
    pendingSearchHitID = nil
    // A dismissed panel has no place to show a navigation failure, so the model absorbs it.
    Task { await model.goToSearchHit(id: id) }
  }

  func isCurrent(_ entry: TOCEntry) -> Bool {
    guard let position = model.currentPosition else { return false }
    return entry.href == position.href || entry.position == position.position
  }
}
