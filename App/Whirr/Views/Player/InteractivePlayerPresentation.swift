import AppModel
import SwiftUI
import UIKit

/// The presentation coordinator's serialised phases.
enum PlayerPresentationPhase: Equatable {
  case idle, presenting, presented, interacting, dismissing
}

/// What a SwiftUI update should do, given the current phase and the requested presentation state.
enum PlayerPresentationAction: Equatable {
  case present, updateContent, dismiss, ignore
}

/// Pure transition rules, so the ordering guarantees are testable without a window, a view
/// controller, or the player view.
enum PlayerPresentationStateMachine {
  static func action(
    phase: PlayerPresentationPhase, isPresentedRequested: Bool
  ) -> PlayerPresentationAction {
    if isPresentedRequested {
      switch phase {
      case .idle:
        return .present
      case .presenting, .presented, .interacting:
        return .updateContent
      case .dismissing:
        return .ignore
      }
    }

    switch phase {
    case .presented:
      return .dismiss
    case .idle, .presenting, .interacting, .dismissing:
      return .ignore
    }
  }

  static func phaseAfterInteractiveBegin(
    phase: PlayerPresentationPhase
  ) -> PlayerPresentationPhase? {
    phase == .presented ? .interacting : nil
  }

  static func phaseAfterDismissalEnded(
    phase: PlayerPresentationPhase, completed: Bool
  ) -> PlayerPresentationPhase {
    completed ? .idle : .presented
  }

  /// Whether reaching this end-of-dismissal should run the shell's cleanup exactly once.
  static func shouldRunCompletionCleanup(
    phase: PlayerPresentationPhase, completed: Bool
  ) -> Bool {
    completed && (phase == .presented || phase == .interacting || phase == .dismissing)
  }
}

extension View {
  /// Presents the expanded player through a UIKit custom transition that owns its interactive
  /// pull-down dismissal, in place of `.fullScreenCover`. `chromeColorScheme` is the polarity the
  /// page resolved to (its ground is the artwork's colour, not the app's; see
  /// `PlayerHostingController`). `collapseStyle` is `NavigationModel.playerCollapseStyle`, read in
  /// the update that flips `isPresented` to false, so the model writes it first. `morphGeometry`
  /// is the shell's relay for collapsing into the mini player; without one every collapse slides.
  @MainActor
  func interactivePlayerPresentation<PlayerContent: View>(
    isPresented: Binding<Bool>,
    collapseStyle: NavigationModel.PlayerCollapseStyle = .slide,
    morphGeometry: PlayerMorphGeometry? = nil,
    chromeColorScheme: ColorScheme,
    onDismissCompleted: @escaping () -> Void,
    @ViewBuilder content: @escaping () -> PlayerContent
  ) -> some View {
    background(
      InteractivePlayerPresentationBridge(
        isPresented: isPresented,
        collapseStyle: collapseStyle,
        morphGeometry: morphGeometry,
        chromeColorScheme: chromeColorScheme,
        onDismissCompleted: onDismissCompleted,
        content: content
      )
      .frame(width: 0, height: 0))
  }
}

@MainActor
private struct InteractivePlayerPresentationBridge<PlayerContent: View>:
  UIViewControllerRepresentable
{
  private let isPresented: Binding<Bool>
  private let collapseStyle: NavigationModel.PlayerCollapseStyle
  private let morphGeometry: PlayerMorphGeometry?
  private let chromeColorScheme: ColorScheme
  private let onDismissCompleted: () -> Void
  private let content: () -> PlayerContent
  /// Read here, inside the presenting scene, because the hosted page is not in one. A
  /// UIKit-presented hosting controller reads `.background` for as long as it is on screen, which
  /// would shut every gate on the page built from `scenePhase`, the audio-route refresh among them.
  @Environment(\.scenePhase) private var scenePhase
  /// Read here for the same reason. The speed card's per-show Voice Boost and Trim Silences rows
  /// need it; without it only the app-wide Voice Boost row shows.
  @Environment(\.showPlaybackEffects) private var showPlaybackEffects

  init(
    isPresented: Binding<Bool>,
    collapseStyle: NavigationModel.PlayerCollapseStyle,
    morphGeometry: PlayerMorphGeometry?,
    chromeColorScheme: ColorScheme,
    onDismissCompleted: @escaping () -> Void,
    @ViewBuilder content: @escaping () -> PlayerContent
  ) {
    self.isPresented = isPresented
    self.collapseStyle = collapseStyle
    self.morphGeometry = morphGeometry
    self.chromeColorScheme = chromeColorScheme
    self.onDismissCompleted = onDismissCompleted
    self.content = content
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIViewController(context: Context) -> PlayerPresentationAnchorController {
    let anchor = PlayerPresentationAnchorController()
    anchor.onMoveToWindow = { [weak coordinator = context.coordinator, weak anchor] in
      guard let coordinator, let anchor else { return }
      coordinator.anchorDidMoveToWindow(anchor)
    }
    return anchor
  }

  func updateUIViewController(
    _ anchor: PlayerPresentationAnchorController, context: Context
  ) {
    context.coordinator.update(
      anchor: anchor,
      content: content,
      scenePhase: scenePhase,
      showPlaybackEffects: showPlaybackEffects,
      collapseStyle: collapseStyle,
      morphGeometry: morphGeometry,
      chromeColorScheme: chromeColorScheme,
      isPresented: isPresented,
      onDismissCompleted: onDismissCompleted)
  }

  @MainActor
  final class Coordinator {
    private(set) var phase: PlayerPresentationPhase = .idle

    private weak var anchor: PlayerPresentationAnchorController?
    private var content: (() -> PlayerContent)?
    private var scenePhase: ScenePhase = .active
    private var showPlaybackEffects: ShowPlaybackEffectsAccess?
    private var isPresented: Binding<Bool>?
    private var onDismissCompleted: (() -> Void)?
    private var pendingPresentation = false
    /// Set from app appearance by update before the host is created.
    private var chromeColorScheme: ColorScheme = .dark
    /// The shape the model asked the current collapse to take; handed to the delegate only by the
    /// non-interactive `dismiss()` below.
    private var collapseStyle: NavigationModel.PlayerCollapseStyle = .slide
    /// Held weakly: the shell owns the relay, and the delegate and its animators read it through
    /// here only while the shell is alive.
    private weak var morphGeometry: PlayerMorphGeometry?

    private var host: PlayerHostingController<PresentingEnvironmentForwarding<PlayerContent>>?
    private var transitionDelegate: PlayerTransitioningDelegate?
    private var dismissInteractor: PlayerDismissInteractor?

    func update(
      anchor: PlayerPresentationAnchorController,
      content: @escaping () -> PlayerContent,
      scenePhase: ScenePhase,
      showPlaybackEffects: ShowPlaybackEffectsAccess?,
      collapseStyle: NavigationModel.PlayerCollapseStyle,
      morphGeometry: PlayerMorphGeometry? = nil,
      chromeColorScheme: ColorScheme,
      isPresented: Binding<Bool>,
      onDismissCompleted: @escaping () -> Void
    ) {
      self.anchor = anchor
      self.content = content
      self.scenePhase = scenePhase
      self.showPlaybackEffects = showPlaybackEffects
      self.collapseStyle = collapseStyle
      self.morphGeometry = morphGeometry
      transitionDelegate?.morphGeometry = morphGeometry
      self.chromeColorScheme = chromeColorScheme
      self.isPresented = isPresented
      self.onDismissCompleted = onDismissCompleted
      // Keep explicit app appearance changes in sync even during an interactive transition.
      host?.chromeColorScheme = chromeColorScheme

      let action = PlayerPresentationStateMachine.action(
        phase: phase, isPresentedRequested: isPresented.wrappedValue)
      perform(action, from: anchor)
    }

    func anchorDidMoveToWindow(_ anchor: PlayerPresentationAnchorController) {
      self.anchor = anchor
      guard anchor.viewIfLoaded?.window != nil else { return }
      guard pendingPresentation else { return }

      let requested = isPresented?.wrappedValue ?? false
      let action = PlayerPresentationStateMachine.action(
        phase: phase, isPresentedRequested: requested)
      perform(action, from: anchor)
    }

    private func perform(
      _ action: PlayerPresentationAction, from anchor: PlayerPresentationAnchorController
    ) {
      if action != .present, isPresented?.wrappedValue == false {
        pendingPresentation = false
      }

      switch action {
      case .present:
        present(from: anchor)
      case .updateContent:
        if let content {
          host?.rootView = PresentingEnvironmentForwarding(
            scenePhase: scenePhase, showPlaybackEffects: showPlaybackEffects, content: content())
        }
      case .dismiss:
        dismiss()
      case .ignore:
        break
      }
    }

    private func present(from anchor: PlayerPresentationAnchorController) {
      guard phase == .idle, host == nil, let content else { return }

      guard anchor.viewIfLoaded?.window != nil else {
        // SwiftUI can update the background before its anchor enters a window; retrying from
        // didMoveToWindow avoids presenting into a controller hierarchy UIKit cannot display.
        pendingPresentation = true
        return
      }

      pendingPresentation = false
      phase = .presenting

      let host = PlayerHostingController(
        rootView: PresentingEnvironmentForwarding(
          scenePhase: scenePhase, showPlaybackEffects: showPlaybackEffects, content: content()),
        chromeColorScheme: chromeColorScheme)
      let transitionDelegate = PlayerTransitioningDelegate()
      transitionDelegate.morphGeometry = morphGeometry
      let dismissInteractor = PlayerDismissInteractor { [weak self] in
        self?.interactiveDismissalRequested() ?? false
      }

      transitionDelegate.interactionProvider = dismissInteractor
      transitionDelegate.onDismissalEnded = { [weak self, weak host] completed in
        guard let self, let host, self.host === host else { return }
        self.dismissalEnded(completed: completed)
      }
      host.transitioningDelegate = transitionDelegate
      dismissInteractor.attach(to: host)

      self.host = host
      self.transitionDelegate = transitionDelegate
      self.dismissInteractor = dismissInteractor

      anchor.present(host, animated: true) { [weak self, weak host] in
        guard let self, self.host === host, self.phase == .presenting else { return }
        self.phase = .presented

        // A collapse can arrive while presentation is in flight (notably during logout). The
        // presenting-phase rule defers that dismissal until UIKit has established the host.
        guard self.isPresented?.wrappedValue == false, let anchor = self.anchor else { return }
        let action = PlayerPresentationStateMachine.action(
          phase: self.phase, isPresentedRequested: false)
        self.perform(action, from: anchor)
      }
    }

    private func dismiss() {
      guard phase == .presented, let host else { return }

      // The state machine only reaches this path without a live interaction controller, so UIKit
      // uses the same dismissal animator non-interactively, including when a child is presented.
      phase = .dismissing
      // Only this path may dissolve. An interactive dismissal goes through
      // `interactiveDismissalRequested` and leaves the delegate at its slide default.
      transitionDelegate?.dismissStyle = collapseStyle
      // The carrying SwiftUI update's transaction may have disabled animations (a caller
      // installing a route behind the player does), and UIKit runs a modal transition without
      // animation when animations are disabled at `dismiss`, turning the collapse into a cut.
      // Re-enable for the call and restore the caller's setting.
      let wereAnimationsEnabled = UIView.areAnimationsEnabled
      UIView.setAnimationsEnabled(true)
      host.dismiss(animated: true)
      UIView.setAnimationsEnabled(wereAnimationsEnabled)
    }

    /// Returns whether the drag may drive a dismissal. Refusing tells the interactor to drop the
    /// interaction controller it had to build before asking.
    private func interactiveDismissalRequested() -> Bool {
      guard let nextPhase = PlayerPresentationStateMachine.phaseAfterInteractiveBegin(phase: phase)
      else { return false }
      guard let host else { return false }

      phase = nextPhase
      // Beginning a drag changes only UIKit's transition phase. Navigation remains expanded until
      // completion so cancellation preserves both the committed snapshot and the route.
      host.dismiss(animated: true)
      return true
    }

    private func dismissalEnded(completed: Bool) {
      // A root alert can make UIKit dismiss the player without a navigation or drag request.
      // That dismissal arrives while still presented and must release the host too, otherwise
      // later expand requests update an invisible controller. Idle callbacks remain stale.
      guard phase == .presented || phase == .interacting || phase == .dismissing else { return }

      let shouldCleanup = PlayerPresentationStateMachine.shouldRunCompletionCleanup(
        phase: phase, completed: completed)
      phase = PlayerPresentationStateMachine.phaseAfterDismissalEnded(
        phase: phase, completed: completed)

      // A cancelled slide leaves the delegate for the next dismissal, which must not inherit a
      // dissolve the model asked for once; the coordinator sets the style afresh each time.
      transitionDelegate?.dismissStyle = .slide

      guard shouldCleanup else { return }

      // A navigation collapse may already have made the binding read false. Avoid writing it a
      // second time: the binding is also the source of SwiftUI updates during teardown.
      if isPresented?.wrappedValue == true {
        isPresented?.wrappedValue = false
      }

      transitionDelegate?.onDismissalEnded = nil
      transitionDelegate?.interactionProvider = nil
      host = nil
      dismissInteractor = nil
      transitionDelegate = nil
      onDismissCompleted?()
    }
  }
}

/// Carries the presenting side's environment into the player's own hosting controller, which
/// SwiftUI does not treat as part of that scene: a value not forwarded here reads its default on
/// the expanded player and in everything it presents.
private struct PresentingEnvironmentForwarding<Content: View>: View {
  let scenePhase: ScenePhase
  let showPlaybackEffects: ShowPlaybackEffectsAccess?
  let content: Content

  var body: some View {
    content
      .environment(\.scenePhase, scenePhase)
      .environment(\.showPlaybackEffects, showPlaybackEffects)
  }
}

@MainActor
final class PlayerPresentationAnchorController: UIViewController {
  var onMoveToWindow: (() -> Void)?

  init() {
    super.init(nibName: nil, bundle: nil)
  }

  override func loadView() {
    view = PlayerPresentationAnchorView()
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("PlayerPresentationAnchorController does not support NSCoder initialization")
  }
}

@MainActor
private final class PlayerPresentationAnchorView: UIView {
  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard window != nil else { return }
    (next as? PlayerPresentationAnchorController)?.onMoveToWindow?()
  }

  override var intrinsicContentSize: CGSize {
    .zero
  }
}
