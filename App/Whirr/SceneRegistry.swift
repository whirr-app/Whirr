import SwiftUI

/// The process's one view of its scenes.
///
/// The phone window and a CarPlay screen are separate scenes with separate phases. Following the
/// last report would background a process still driving a car screen, so every scene reports
/// here, keyed by role and session, and the registry decides what the process as a whole did:
///
/// - The process is active while any scene is, and backgrounded only once every scene is in the
///   background or gone, so keyed work runs once however many scenes are attached.
/// - The phone's own phase is reported separately, for work that must not run on a car-only drive.
///
/// `.inactive` is passed through: `ScenePhaseLifecycleMapper` treats an active-inactive-active
/// bounce as a second foregrounding and must see it. A phone scene never disconnects here (SwiftUI
/// gives no reliable destruction signal); reaching `.background` first is all the aggregate needs.
@MainActor
final class SceneRegistry {
  enum Role: Hashable, Sendable {
    case phone
    case car
  }

  struct SceneID: Hashable, Sendable {
    let role: Role
    let session: String
  }

  /// What the registry drives. Each closure is one decision about which scenes a piece of work
  /// follows; `Effects.production` holds the app's answers.
  struct Effects {
    /// The process's aggregate phase, on every change of it.
    var lifecyclePhase: @MainActor (ScenePhase) -> Void
    /// The phone scenes' aggregate phase, on every change of it.
    var phoneScenePhase: @MainActor (ScenePhase) -> Void
    /// A car scene connected to a process that has no phone scene.
    var carConnectedWithoutPhone: @MainActor () -> Void
    /// The process went from having no active scene to having one.
    var anySceneBecameActive: @MainActor () -> Void
    /// The phone went from having no active scene to having one.
    var phoneSceneBecameActive: @MainActor () -> Void
    /// The last scene that was not in the background entered it, or disconnected.
    var allScenesEnteredBackground: @MainActor () -> Void
  }

  static let shared = SceneRegistry(effects: .production)

  private let effects: Effects
  private var phases: [SceneID: ScenePhase] = [:]

  init(effects: Effects) {
    self.effects = effects
  }

  /// The process's aggregate phase; nil while no scene is attached.
  var phase: ScenePhase? { Self.aggregate(phases.values) }

  /// Records a scene's phase, registering the scene on its first report. A scene's opening phase
  /// is reported like any later one: it is not a change SwiftUI or UIKit will deliver again.
  func report(_ phase: ScenePhase, for scene: SceneID) {
    guard phases[scene] != phase else { return }
    let isConnecting = phases[scene] == nil
    let before = snapshot()
    phases[scene] = phase
    if isConnecting, scene.role == .car, before.phone == nil {
      effects.carConnectedWithoutPhone()
    }
    apply(from: before)
  }

  /// Forgets a scene that has gone away. One that was still active or inactive takes its claim on
  /// the foreground with it.
  func disconnect(_ scene: SceneID) {
    guard phases[scene] != nil else { return }
    let before = snapshot()
    phases[scene] = nil
    apply(from: before)
  }

  private struct Snapshot {
    var all: ScenePhase?
    var phone: ScenePhase?
  }

  private func snapshot() -> Snapshot {
    Snapshot(
      all: Self.aggregate(phases.values),
      phone: Self.aggregate(phases.filter { $0.key.role == .phone }.values))
  }

  private func apply(from before: Snapshot) {
    let after = snapshot()
    // With no scene left, the process is in the background whatever its last scene was doing.
    let all = after.all ?? .background
    let phone = after.phone ?? .background
    let allChanged = all != before.all
    let phoneChanged = phone != before.phone && (after.phone != nil || before.phone != nil)

    if allChanged { effects.lifecyclePhase(all) }
    if phoneChanged { effects.phoneScenePhase(phone) }
    if phoneChanged, phone == .active { effects.phoneSceneBecameActive() }
    if allChanged, all == .active { effects.anySceneBecameActive() }
    // A scene that launches into the background has not entered it: nothing was running in the
    // foreground to wind down or to schedule work on behalf of.
    if allChanged, all == .background, before.all != nil { effects.allScenesEnteredBackground() }
  }

  private static func aggregate(_ phases: some Collection<ScenePhase>) -> ScenePhase? {
    if phases.isEmpty { return nil }
    if phases.contains(.active) { return .active }
    if phases.contains(.inactive) { return .inactive }
    return .background
  }
}
