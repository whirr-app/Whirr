import AppModel
import AuthenticationServices
import DesignSystem
import Foundation
import SwiftUI
import SyncEngine

/// Setup and login. State-specific messages come from `SetupFlowModel.State.copyText`; this view
/// switches over the state to decide which fields and messages to show, then forwards submitted
/// values back into the model.
struct SetupFlowView: View {
  /// The flow's tint. Whirr's navy, not the neutral `AppChrome.tint`, whose near-white dark
  /// appearance would leave prominent buttons relying on `AppChrome.onTint` for legibility.
  static let tint = AppChrome.brandTint

  @Bindable var model: SetupFlowModel

  @State private var draft = SetupDraft()
  @State private var isConfirmingSignOut = false
  @State private var isShowingSignOutFailure = false
  @FocusState private var focusedField: SetupFlowField?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession

  var body: some View {
    ZStack {
      ambientBackground

      VStack(spacing: 0) {
        brandHeader
          .frame(maxWidth: 480)
          .frame(maxWidth: .infinity)
          .padding(.top, SetupFlowLayout.contentTopPadding)
          .padding(.horizontal, WhirrSpacing.large)

        setupForm
      }
    }
    .tint(Self.tint)
    // Setup's discovery failure is only reachable once an account exists, so signing out here
    // destroys what Settings' logout destroys and asks in the same words.
    .alert(SettingsCopy.logoutTitle, isPresented: $isConfirmingSignOut) {
      Button(SettingsCopy.cancel, role: .cancel) {}
      Button(SettingsCopy.confirmLogout, role: .destructive) {
        Task { await attemptSignOut() }
      }
      .disabled(model.isSigningOut)
    } message: {
      Text(SettingsCopy.logoutMessage)
    }
    .alert(SettingsCopy.logoutFailedTitle, isPresented: $isShowingSignOutFailure) {
      Button(SettingsCopy.cancel, role: .cancel) {}
      Button(SettingsCopy.retryLogout) {
        Task { await attemptSignOut() }
      }
      .disabled(model.isSigningOut)
    } message: {
      Text(SettingsCopy.logoutFailedMessage)
    }
    .onChange(of: model.state) { _, newState in
      // Focus assignment already participates in the system keyboard transaction, so no explicit
      // animation here: it would overlap a whole-form animation and the scroll below.
      switch newState {
      case .needsCredentials:
        // An SSO-only server leads with a button, not a field, unless the user chose a token. On
        // plain HTTP it offers no button, so the token is the only way in.
        if newState.offersPasswordSignIn == false && newState.offersSingleSignOn == false {
          draft.credentialMode = .apiToken
        }
        if newState.offersPasswordSignIn || draft.credentialMode == .apiToken {
          focusedField = draft.credentialMode == .apiToken ? .apiToken : .username
        } else {
          focusedField = nil
        }
      case .authenticated, .validatingServer, .loggingIn, .loadingLibraries, .savingLibrarySelection:
        focusedField = nil
      default:
        break
      }
    }
  }

  private var ambientBackground: some View {
    WhirrColorToken.groupedSurface.color
      .ignoresSafeArea()
  }

  private var brandHeader: some View {
    VStack(spacing: WhirrSpacing.small) {
      Image("AppLogo")
        .resizable()
        .scaledToFit()
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(.white.opacity(0.2), lineWidth: 0.5)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 14, y: 8)
        .accessibilityHidden(true)

      Text("Whirr")
        .font(.title.weight(.bold))
        .tracking(-0.6)
        .multilineTextAlignment(.center)
    }
  }

  private var setupForm: some View {
    switch SetupFlowLayout.contentPresentation {
    case .groupedForm:
      ScrollViewReader { scrollProxy in
        Form {
          Section {
            stateHeader
              .frame(maxWidth: .infinity)
              .padding(.vertical, WhirrSpacing.small)
              .listRowBackground(Color.clear)
              .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
          }

          Section {
            fields
          }
          .listRowInsets(
            EdgeInsets(
              top: WhirrSpacing.xSmall,
              leading: WhirrSpacing.small,
              bottom: WhirrSpacing.xSmall,
              trailing: WhirrSpacing.small
            )
          )
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(WhirrColorToken.groupedSurface.color.ignoresSafeArea())
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .scrollDismissesKeyboard(.interactively)
        // No broad animation here: it makes every Form descendant join state changes while the
        // keyboard and scroll position move. The scroll holds the only custom transaction.
        .task(id: focusedField) {
          let field = focusedField
          guard let field else { return }
          await Task.yield()
          guard Task.isCancelled == false, focusedField == field else { return }
          withAnimation(SetupFlowMotion.focusScrollAnimation(reduceMotion: reduceMotion)) {
            scrollProxy.scrollTo(field, anchor: SetupFlowLayout.scrollAnchor(for: field))
          }
        }
      }
    }
  }

  private var stateHeader: some View {
    VStack(spacing: WhirrSpacing.xSmall) {
      if let serverName {
        Label(serverName, systemImage: "checkmark.circle.fill")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.tint)
          .lineLimit(1)
      }

      Text(stateTitle)
        .font(.title2.weight(.bold))
        .multilineTextAlignment(.center)

      if let stateMessage {
        Text(stateMessage)
          .font(WhirrTypeToken.body.font)
          .foregroundStyle(
            isError ? Color.red : WhirrColorToken.textSecondary.color
          )
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier(model.state.copyKey)
      }
    }
  }

  @ViewBuilder
  private var fields: some View {
    switch model.state {
    case .idle, .serverValidationFailed:
      serverURLFields
    case .validatingServer:
      progressView(label: "Checking server")
    case .needsCredentials, .loginFailed:
      credentialsFields
    case .loggingIn:
      progressView(label: "Signing in")
    case .loadingLibraries:
      progressView(label: "Finding your libraries")
    case .choosingLibraries(let libraries, let selectedIDs):
      SetupLibrarySelectionFields(
        libraries: libraries, selectedIDs: selectedIDs,
        onToggle: model.toggleLibrarySelection,
        onContinue: { Task { await model.continueLibrarySelection() } })
    case .savingLibrarySelection:
      progressView(label: "Saving your library choices")
    case .libraryDiscoveryFailed:
      VStack(spacing: WhirrSpacing.small) {
        Button("Try Again") { Task { await model.retry() } }
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.capsule)
          .disabled(model.isSigningOut)
          .accessibilityIdentifier("setup.libraryDiscovery.retry")
        Button(SettingsCopy.confirmLogout, role: .destructive) { isConfirmingSignOut = true }
          .disabled(model.isSigningOut)
          .accessibilityIdentifier("setup.libraryDiscovery.signOut")
      }
    case .authenticated:
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 44))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
    }
  }

  private func attemptSignOut() async {
    if await model.signOut() == false {
      isShowingSignOutFailure = true
    }
  }

  private var serverURLFields: some View {
    ServerURLFields(draft: draft, focusedField: $focusedField, onSubmit: submitServer)
  }

  private var credentialsFields: some View {
    CredentialsFields(
      draft: draft,
      model: model,
      focusedField: $focusedField,
      onSubmit: submitCredentials,
      onSingleSignOn: submitSingleSignOn,
      onUseADifferentServer: {
        draft.forgetServerScopedSecrets()
        model.cancel()
        focusedField = .server
      }
    )
  }

  private func progressView(label: String) -> some View {
    HStack(spacing: WhirrSpacing.small) {
      ProgressView()
      Text(label)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(WhirrColorToken.textSecondary.color)
    }
    .frame(minHeight: WhirrMetric.minimumTouchTarget)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(label)
  }

  private var stateTitle: String {
    switch model.state {
    case .idle, .serverValidationFailed:
      return isError ? "Let’s try that again" : "Connect your library"
    case .validatingServer:
      return "Finding your shelf"
    case .needsCredentials, .loginFailed:
      return isError ? "Couldn’t sign you in" : "Welcome back"
    case .loggingIn, .loadingLibraries:
      return "Opening your library"
    case .choosingLibraries:
      return "Choose Libraries"
    case .savingLibrarySelection:
      return "Saving your choices"
    case .authenticated:
      return "You’re all set"
    case .libraryDiscoveryFailed:
      return "Couldn’t load libraries"
    }
  }

  private var serverName: String? {
    let serverURL: URL?
    switch model.state {
    case .needsCredentials(let server), .loggingIn(let server, _), .loginFailed(let server, _):
      serverURL = server.serverURL
    default:
      serverURL = nil
    }
    return serverURL?.host()
  }

  private var stateMessage: String? {
    // The title already carries the credentials step; keep its supporting copy quiet unless the
    // server's sign-in methods need explaining.
    if case .needsCredentials = model.state { return model.state.credentialsNotice }
    return model.state.copyText
  }

  private var isError: Bool {
    switch model.state {
    case .serverValidationFailed, .loginFailed, .libraryDiscoveryFailed:
      return true
    default:
      return false
    }
  }

  private func submitServer(customHeaders: [String: String]) {
    let address = draft.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    guard address.isEmpty == false else { return }

    let urlText = address.contains("://") ? address : "\(draft.scheme.rawValue)://\(address)"
    guard let url = URL(string: urlText) else { return }
    focusedField = nil
    Task { await model.submitServerURL(url, customHeaders: customHeaders) }
  }

  private func submitSingleSignOn() {
    focusedField = nil
    let browser = SingleSignOnBrowser(session: webAuthenticationSession)
    Task {
      if case .loginFailed = model.state {
        await model.retry()
      }
      await model.submitSingleSignOn(using: browser)
    }
  }

  private func submitCredentials() {
    if draft.credentialMode == .apiToken {
      guard model.apiToken.isEmpty == false else { return }
      focusedField = nil
      Task {
        if case .loginFailed = model.state {
          await model.retry()
        }
        await model.submitAPIToken()
      }
      return
    }

    let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard username.isEmpty == false, model.password.isEmpty == false else { return }

    focusedField = nil
    Task {
      if case .loginFailed = model.state {
        await model.retry()
      }
      await model.submitCredentials(username: draft.username)
    }
  }
}
