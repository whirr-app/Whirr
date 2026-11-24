import AppModel
import DesignSystem
import SwiftUI

nonisolated enum NoAccessibleLibraryViewPresentation {
  enum Action: Hashable {
    case retry
    case chooseLibraries
    case signOut
  }

  static let actions: [Action] = [.retry, .chooseLibraries, .signOut]

  static func actions(isNoAccessibleLibrary: Bool, canChooseLibraries: Bool) -> [Action] {
    guard isNoAccessibleLibrary else { return [] }
    return canChooseLibraries ? actions : [.retry, .signOut]
  }
}

/// The authenticated-but-empty account escape surface. It keeps the account signed in while a
/// retry is useful, and sends sign-out through the same confirmed removal path as Settings.
struct NoAccessibleLibraryView: View {
  static let retryTitle = "Retry"
  static let chooseLibrariesTitle = "Choose Libraries"
  static let signOutTitle = "Sign Out and Change Server"

  let canChooseLibraries: Bool
  let onRetry: () async -> Void
  let onChooseLibraries: () -> Void
  let onSignOut: () async -> Bool

  @State private var isRetrying = false
  @State private var isSigningOut = false
  @State private var isConfirmingSignOut = false
  @State private var isShowingSignOutFailure = false

  var body: some View {
    VStack(spacing: WhirrSpacing.medium) {
      ContentUnavailableView {
        Label("No Library Available", systemImage: "books.vertical")
      } description: {
        Text("This account does not have access to a library on the current server.")
      }

      HStack(spacing: WhirrSpacing.small) {
        ForEach(
          NoAccessibleLibraryViewPresentation.actions(
            isNoAccessibleLibrary: true, canChooseLibraries: canChooseLibraries),
          id: \.self
        ) { action in
          button(for: action)
            .disabled(isRetrying || isSigningOut)
        }
      }

      if isRetrying || isSigningOut {
        ProgressView()
          .accessibilityLabel(isSigningOut ? "Signing out" : "Retrying library resolution")
      }
    }
    .padding(WhirrSpacing.large)
    .alert("Sign Out and Change Server?", isPresented: $isConfirmingSignOut) {
      Button("Cancel", role: .cancel) {}
      Button("Sign Out", role: .destructive) {
        Task { await attemptSignOut() }
      }
      .disabled(isSigningOut)
    } message: {
      Text("Your account and its local data will be removed before returning to server setup.")
    }
    .alert(SettingsCopy.logoutFailedTitle, isPresented: $isShowingSignOutFailure) {
      Button(SettingsCopy.cancel, role: .cancel) {}
      Button(SettingsCopy.retryLogout) {
        Task { await attemptSignOut() }
      }
      .disabled(isSigningOut)
    } message: {
      Text(SettingsCopy.logoutFailedMessage)
    }
  }

  @ViewBuilder
  private func button(for action: NoAccessibleLibraryViewPresentation.Action) -> some View {
    switch action {
    case .retry:
      Button(Self.retryTitle) {
        Task {
          isRetrying = true
          await onRetry()
          isRetrying = false
        }
      }
    case .chooseLibraries:
      Button(Self.chooseLibrariesTitle, action: onChooseLibraries)
    case .signOut:
      Button(Self.signOutTitle, role: .destructive) {
        isConfirmingSignOut = true
      }
    }
  }

  private func attemptSignOut() async {
    guard isSigningOut == false else { return }
    isSigningOut = true
    let succeeded = await onSignOut()
    isSigningOut = false
    if succeeded == false {
      isShowingSignOutFailure = true
    }
  }
}
