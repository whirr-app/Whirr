import SwiftUI

/// The phone scene's root. `RootView` reads the account graph unconditionally, so it is mounted
/// only once `AppRuntime` has one; until then this shows why not, instead of the process
/// trapping on a store that would not open.
struct RootGate: View {
  private let runtime: AppRuntime

  /// A default argument is evaluated nonisolated, so the process runtime is resolved here.
  init(runtime: AppRuntime? = nil) {
    self.runtime = runtime ?? .shared
  }

  var body: some View {
    // `prepare()` composes the launch graph on the first render, so a normal launch never shows
    // an intermediate frame.
    if runtime.prepare() != nil {
      RootView(runtime: runtime)
    } else {
      LaunchUnavailableView(runtime: runtime)
    }
  }
}

/// What the phone shows while there is no graph to show.
struct LaunchUnavailablePresentation: Equatable {
  let title: LocalizedStringResource
  let message: LocalizedStringResource
  let symbol: String

  /// Nil once there is a graph, and before anyone has asked for one.
  init?(_ readiness: AppRuntime.Readiness) {
    switch readiness {
    case .starting, .ready:
      return nil
    case .storageUnavailable:
      title = "Unlock iPhone"
      message = "Whirr can open your library once this iPhone has been unlocked."
      symbol = "lock"
    case .failed(.databaseUnopenable):
      title = "Library Unavailable"
      message = "Whirr couldn't open its library. Nothing has been deleted. Restart your iPhone and try again."
      symbol = "exclamationmark.triangle"
    case .failed(.accountUnreadable):
      title = "Account Unavailable"
      message = "Whirr couldn't read your account. Nothing has been deleted. Restart your iPhone and try again."
      symbol = "person.crop.circle.badge.exclamationmark"
    }
  }
}

private struct LaunchUnavailableView: View {
  let runtime: AppRuntime
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Group {
      if let presentation = LaunchUnavailablePresentation(runtime.readiness) {
        ContentUnavailableView {
          Label {
            Text(presentation.title)
          } icon: {
            Image(systemName: presentation.symbol)
          }
        } description: {
          Text(presentation.message)
        }
      }
    }
    // Arms the protected-data retry; returning to the app is the other moment worth retrying.
    .task { runtime.start() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { runtime.start() }
    }
  }
}
