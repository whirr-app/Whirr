import CarPlay
import SwiftUI

/// The CarPlay scene's entry point. The system instantiates it by name from the scene manifest's
/// `CPTemplateApplicationSceneSessionRoleApplication` configuration in `Info.plist`.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
  CPInterfaceControllerDelegate, CPTabBarTemplateDelegate, CPSessionConfigurationDelegate
{
  private var coordinator: CarPlayCoordinator?
  private var sessionConfiguration: CPSessionConfiguration?
  private var memoryWarnings: NSObjectProtocol?
  private var sceneID: SceneRegistry.SceneID?

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    let queue = CarPlayInterfaceQueue(controller: interfaceController)
    let coordinator = CarPlayCoordinator(
      environment: .production(runtime: .shared) { [weak interfaceController] in
        let traits = interfaceController?.carTraitCollection
        let side = CPListItem.maximumImageSize.width * (traits?.displayScale ?? 2)
        return CarPlayLimits(
          maximumTabCount: CPTabBarTemplate.maximumTabCount,
          maximumItemCount: CPListTemplate.maximumItemCount,
          imagePixelSize: Int(side.rounded()),
          isDark: traits?.userInterfaceStyle == .dark)
      },
      interface: queue, nowPlaying: CarPlaySharedNowPlaying())
    // A refused operation means the stack is not what was asked for; `appeared` re-reads it.
    queue.onFailure = { [weak coordinator, weak interfaceController] in
      interfaceController?.topTemplate.map { coordinator?.appeared($0) }
    }
    self.coordinator = coordinator
    interfaceController.delegate = self
    sessionConfiguration = CPSessionConfiguration(delegate: self)
    memoryWarnings = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { [weak coordinator] _ in
      MainActor.assumeIsolated { coordinator?.purgeArtwork() }
    }
    sceneID = SceneRegistry.SceneID(
      role: .car, session: templateApplicationScene.session.persistentIdentifier)
    report(templateApplicationScene.activationState == .foregroundActive ? .active : .inactive)
    coordinator.connect()
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    coordinator?.disconnect()
    coordinator = nil
    sessionConfiguration = nil
    if let memoryWarnings { NotificationCenter.default.removeObserver(memoryWarnings) }
    memoryWarnings = nil
    if let sceneID { SceneRegistry.shared.disconnect(sceneID) }
    sceneID = nil
  }

  // A connected car screen is not foreground until the scene says so.
  func sceneDidBecomeActive(_ scene: UIScene) { report(.active) }
  func sceneWillResignActive(_ scene: UIScene) { report(.inactive) }
  func sceneDidEnterBackground(_ scene: UIScene) { report(.background) }

  private func report(_ phase: ScenePhase) {
    if let sceneID { SceneRegistry.shared.report(phase, for: sceneID) }
  }

  // MARK: - Template callbacks

  func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
    coordinator?.appeared(aTemplate)
  }

  func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
    coordinator?.appeared(selectedTemplate)
  }

  func sessionConfiguration(
    _ sessionConfiguration: CPSessionConfiguration,
    limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
  ) {
    coordinator?.limitsChanged()
  }

  func sessionConfiguration(
    _ sessionConfiguration: CPSessionConfiguration,
    contentStyleChanged contentStyle: CPContentStyle
  ) {
    coordinator?.limitsChanged()
  }
}
