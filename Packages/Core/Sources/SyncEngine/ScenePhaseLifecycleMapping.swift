/// The pure decision half of the `ScenePhase` to `AppLifecycle` adapter (ARCHITECTURE.md).
/// `AppScenePhase` mirrors SwiftUI's `ScenePhase` cases without importing SwiftUI, so this stays
/// Foundation-only and testable on the macOS host. The App-target adapter converts a real
/// `ScenePhase` to this value and hands the (previous, new) pair to `transition(from:to:)`.
public enum AppScenePhase: Sendable, Equatable {
  case active
  case inactive
  case background
}

/// Maps a scene-phase change to an `AppLifecycleTransition`, or `nil` when the change carries no
/// transition SyncEngine cares about.
public enum ScenePhaseLifecycleMapper {
  /// `.inactive` is transient (app switch, system interruption) and never produces a transition.
  /// Entering `.active` or `.background` does, only on a genuine change, so the adapter can call
  /// this on every `ScenePhase` change.
  ///
  /// Not deduped: the adapter stores `.inactive` as its previous phase, so an
  /// `.active -> .inactive -> .active` bounce (Control Centre, app switcher, permission alert,
  /// call banner) emits a second `.foreground`, as a real background return does. Needed for
  /// correctness (an interruption can outlast a server-side change) but costly: every
  /// `.foreground` starts a full library traversal with no minimum interval.
  public static func transition(from oldPhase: AppScenePhase?, to newPhase: AppScenePhase) -> AppLifecycleTransition? {
    switch newPhase {
    case .active:
      return oldPhase == .active ? nil : .foreground
    case .background:
      return oldPhase == .background ? nil : .background
    case .inactive:
      return nil
    }
  }
}
