import AppModel
import DesignSystem
import Persistence
import SwiftUI

struct SetupLibrarySelectionFields: View {
  let libraries: [SelectableLibrary]
  let selectedIDs: Set<String>
  let onToggle: (String) -> Void
  let onContinue: () -> Void

  var body: some View {
    VStack(spacing: WhirrSpacing.medium) {
      ForEach(libraries, id: \.serverLibraryID) { library in
        Toggle(
          isOn: Binding(
            get: { selectedIDs.contains(library.serverLibraryID) },
            set: { _ in onToggle(library.serverLibraryID) }
          )
        ) {
          VStack(alignment: .leading, spacing: 2) {
            Text(library.name)
            Text(library.mediaType.capitalized)
              .font(.caption)
              .foregroundStyle(WhirrColorToken.textSecondary.color)
          }
        }
        .accessibilityIdentifier("setup.librarySelection.\(library.serverLibraryID)")
      }

      Button("Continue", action: onContinue)
        .font(.headline)
        .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(selectedIDs.isEmpty)
        .accessibilityIdentifier("setup.librarySelection.continue")
    }
  }
}

/// Split out of `SetupFlowView` so typing a credential never re-renders the screen around it.
/// This is the only view that reads the credential fields.
struct CredentialsFields: View {
  @Bindable var draft: SetupDraft
  @Bindable var model: SetupFlowModel
  @FocusState.Binding var focusedField: SetupFlowField?
  let onSubmit: () -> Void
  let onSingleSignOn: () -> Void
  let onUseADifferentServer: () -> Void

  /// A password-capable server keeps the password form, with the SSO button under it when both
  /// are offered. An SSO-only server leads with the SSO button and keeps an API token one tap
  /// away, since ABS accepts API keys whichever methods are enabled.
  var body: some View {
    VStack(spacing: WhirrSpacing.medium) {
      if model.state.offersPasswordSignIn {
        signInMethodMenu
        credentialEntry
        if model.state.offersSingleSignOn {
          singleSignOnSection(prominent: false)
        }
      } else {
        // An SSO-only server on plain HTTP offers neither, so only the API token remains.
        if model.state.offersSingleSignOn {
          singleSignOnSection(prominent: true)
        }
        if draft.credentialMode == .apiToken {
          credentialEntry
        } else if model.state.offersSingleSignOn {
          Button(SetupFlowCopy.useAPITokenTitle) { select(.apiToken) }
            .font(.subheadline.weight(.medium))
            .accessibilityIdentifier("setup.credentials.useAPIToken")
        }
      }

      Button("Use a different server", action: onUseADifferentServer)
        .font(.subheadline.weight(.medium))
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }
  }

  @ViewBuilder
  private var credentialEntry: some View {
    if draft.credentialMode == .apiToken {
      apiTokenFields
    } else {
      passwordFields
    }
    submitButton
  }

  private func singleSignOnSection(prominent: Bool) -> some View {
    VStack(spacing: WhirrSpacing.xSmall) {
      let button = Button(action: onSingleSignOn) {
        Label(SetupFlowCopy.singleSignOnButtonTitle, systemImage: "person.badge.key.fill")
          .font(.headline)
          .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
      }
      Group {
        if prominent {
          button.buttonStyle(.borderedProminent)
        } else {
          button.buttonStyle(.bordered)
        }
      }
      .buttonBorderShape(.capsule)
      .accessibilityIdentifier("setup.credentials.singleSignOn")

      Text(SetupFlowCopy.singleSignOnFootnote)
        .font(.footnote)
        .foregroundStyle(WhirrColorToken.textSecondary.color)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)

      if let note = model.state.singleSignOnProxyNote {
        Text(note)
          .font(.footnote)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("setup.credentials.singleSignOnProxyNote")
      }
    }
  }

  private var submitButton: some View {
    Button(action: onSubmit) {
      Text(isLoginFailure ? "Try Again" : "Sign In")
        .font(.headline)
        .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
    }
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.capsule)
    .disabled(
      draft.credentialMode == .apiToken
        ? model.apiToken.isEmpty
        : draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.password.isEmpty
    )
    .accessibilityLabel(isLoginFailure ? "Try again" : "Sign in")
    .id(draft.credentialMode == .apiToken ? SetupFlowField.apiToken : SetupFlowField.password)
  }

  private var signInMethodMenu: some View {
    Menu {
      ForEach(SetupCredentialMode.allCases) { mode in
        Button {
          select(mode)
        } label: {
          Label(mode.displayName, systemImage: mode == .password ? "person.fill" : "key.fill")
        }
      }
    } label: {
      HStack {
        Text("Sign in with")
          .foregroundStyle(WhirrColorToken.textSecondary.color)
        Spacer()
        Text(draft.credentialMode.displayName)
          .foregroundStyle(.primary)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2.weight(.bold))
          .foregroundStyle(.secondary)
      }
      .frame(minHeight: WhirrMetric.minimumTouchTarget)
    }
    .accessibilityLabel("Sign-in method")
    .accessibilityValue(draft.credentialMode.displayName)
  }

  private var passwordFields: some View {
    VStack(spacing: 0) {
      credentialRow(systemImage: "person.fill", label: "Username") {
        TextField("Username", text: $draft.username)
          .textContentType(.username)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .focused($focusedField, equals: .username)
          .submitLabel(.next)
          .onSubmit { focusedField = .password }
          .accessibilityLabel("Username")
      }
      .id(SetupFlowField.username)

      Divider()
        .padding(.leading, 48)

      credentialRow(systemImage: "lock.fill", label: "Password") {
        SecureField("Password", text: $model.password)
          .textContentType(.password)
          .focused($focusedField, equals: .password)
          .submitLabel(.go)
          .onSubmit(onSubmit)
          .accessibilityLabel("Password")
      }
    }
  }

  private var apiTokenFields: some View {
    credentialRow(systemImage: "key.fill", label: "API token") {
      SecureField("Paste API token", text: $model.apiToken)
        .textContentType(.password)
        .focused($focusedField, equals: .apiToken)
        .submitLabel(.go)
        .onSubmit(onSubmit)
        .accessibilityLabel("API token")
    }
    .id(SetupFlowField.apiToken)
  }

  private func select(_ mode: SetupCredentialMode) {
    guard draft.credentialMode != mode else { return }
    draft.credentialMode = mode
    model.password = ""
    model.apiToken = ""
    focusedField = mode == .apiToken ? .apiToken : .username
  }

  private var isLoginFailure: Bool {
    if case .loginFailed = model.state { return true }
    return false
  }

  private func credentialRow<Content: View>(
    systemImage: String, label: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(spacing: WhirrSpacing.small) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 22)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .font(.caption)
          .foregroundStyle(WhirrColorToken.textSecondary.color)

        content()
          .frame(minHeight: WhirrMetric.minimumTouchTarget)
      }
    }
    .padding(.horizontal, WhirrSpacing.small)
  }
}
