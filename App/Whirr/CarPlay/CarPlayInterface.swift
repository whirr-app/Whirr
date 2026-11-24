import CarPlay
import CoreSupport
import OSLog

/// The slice of `CPInterfaceController` the coordinator drives, so its navigation can be tested
/// against a fake. Templates are real `CPTemplate`s either way.
@MainActor
protocol CarPlayInterface: AnyObject {
  func setRoot(_ template: CPTemplate)
  func push(_ template: CPTemplate)
  func pop(to template: CPTemplate)
  func presentAlert(_ template: CPAlertTemplate)
  func dismissAlert()
}

/// The two custom Now Playing controls and Up Next, as the coordinator sees them.
struct CarPlayNowPlayingButtons: Equatable {
  var showsChapters = false
  var showsRate = false
  var showsUpNext = false
}

/// The shared Now Playing template behind a seam: it has no public initializer, so a test
/// cannot make one.
@MainActor
protocol CarPlayNowPlayingSurface: AnyObject {
  var template: CPTemplate { get }
  var onChapters: (@MainActor () -> Void)? { get set }
  var onRate: (@MainActor () -> Void)? { get set }
  var onUpNext: (@MainActor () -> Void)? { get set }
  func show(_ buttons: CarPlayNowPlayingButtons)
  /// Releases the scene's handlers and observation.
  func detach()
}

/// Runs template operations one at a time, in order. `CPInterfaceController` rejects an
/// operation started while another is animating, which is how a fast double tap becomes a
/// duplicate push or a dropped pop.
@MainActor
final class CarPlayInterfaceQueue: CarPlayInterface {
  private static let log = CoreLogging.logger(category: "CarPlay")

  private let controller: CPInterfaceController
  private var pending: [(name: StaticString, run: (@escaping (Bool, (any Error)?) -> Void) -> Void)] = []
  private var isRunning = false
  /// Called when the car refused an operation, so the owner can resynchronise its stack.
  var onFailure: (@MainActor () -> Void)?

  init(controller: CPInterfaceController) {
    self.controller = controller
  }

  func setRoot(_ template: CPTemplate) {
    enqueue("setRoot") { [controller] in controller.setRootTemplate(template, animated: false, completion: $0) }
  }

  func push(_ template: CPTemplate) {
    enqueue("push") { [controller] in controller.pushTemplate(template, animated: true, completion: $0) }
  }

  func pop(to template: CPTemplate) {
    enqueue("pop") { [controller] completion in
      if controller.templates.contains(where: { $0 === template }) {
        controller.pop(to: template, animated: true, completion: completion)
      } else {
        // A tab's own list is not on the stack; the tab bar beneath everything is.
        controller.popToRootTemplate(animated: true, completion: completion)
      }
    }
  }

  func presentAlert(_ template: CPAlertTemplate) {
    enqueue("present") { [controller] completion in
      guard controller.presentedTemplate == nil else {
        completion(true, nil)
        return
      }
      controller.presentTemplate(template, animated: true, completion: completion)
    }
  }

  func dismissAlert() {
    enqueue("dismiss") { [controller] completion in
      guard controller.presentedTemplate != nil else {
        completion(true, nil)
        return
      }
      controller.dismissTemplate(animated: true, completion: completion)
    }
  }

  private func enqueue(
    _ name: StaticString, _ run: @escaping (@escaping (Bool, (any Error)?) -> Void) -> Void
  ) {
    pending.append((name, run))
    runNext()
  }

  private func runNext() {
    guard isRunning == false, pending.isEmpty == false else { return }
    isRunning = true
    let operation = pending.removeFirst()
    operation.run { [weak self] succeeded, error in
      Task { @MainActor in
        guard let self else { return }
        if succeeded == false || error != nil {
          // Category only: a template error can quote titles.
          Self.log.error("CarPlay template operation failed: \(operation.name, privacy: .public)")
          self.onFailure?()
        }
        self.isRunning = false
        self.runNext()
      }
    }
  }
}

/// `CPNowPlayingTemplate.shared`, configured for one car scene.
@MainActor
final class CarPlaySharedNowPlaying: NSObject, CarPlayNowPlayingSurface, CPNowPlayingTemplateObserver {
  private let shared = CPNowPlayingTemplate.shared
  private var shown: CarPlayNowPlayingButtons?
  var template: CPTemplate { shared }
  var onChapters: (@MainActor () -> Void)?
  var onRate: (@MainActor () -> Void)?
  var onUpNext: (@MainActor () -> Void)?

  override init() {
    super.init()
    shared.add(self)
    shared.isAlbumArtistButtonEnabled = false
  }

  func show(_ buttons: CarPlayNowPlayingButtons) {
    guard buttons != shown else { return }
    shown = buttons
    var controls: [CPNowPlayingButton] = []
    if buttons.showsRate {
      controls.append(CPNowPlayingPlaybackRateButton { [weak self] _ in self?.onRate?() })
    }
    if buttons.showsChapters, let image = UIImage(systemName: "list.bullet") {
      controls.append(CPNowPlayingImageButton(image: image) { [weak self] _ in self?.onChapters?() })
    }
    shared.updateNowPlayingButtons(controls)
    shared.isUpNextButtonEnabled = buttons.showsUpNext
  }

  func detach() {
    shared.remove(self)
    shared.updateNowPlayingButtons([])
    shared.isUpNextButtonEnabled = false
    shown = nil
    onChapters = nil
    onRate = nil
    onUpNext = nil
  }

  nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
    Task { @MainActor in self.onUpNext?() }
  }

  nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}
}
