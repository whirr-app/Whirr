import AppModel
import AuthenticationServices
import DesignSystem
import SwiftUI
import SyncEngine

enum AuthRecoveryField: Hashable {
  case username
  case password
  case apiToken
}

/// The focused credential sheet Reconnect presents: a fixed, read-only server display (see
/// `AuthRecoveryModel.serverDisplayString`), username and password fields, Cancel, and a submit
/// action reflecting `AuthRecoveryModel`'s submitting/failed states. Follows `SetupFlowView`'s
/// `CredentialsFields`/`ServerURLFields` conventions, except the server identity is fixed.
struct AuthRecoverySheetView: View {
  @Bindable var model: AuthRecoveryModel
  @Bindable var presentation: AuthRecoveryPresentation
  @FocusState private var focusedField: AuthRecoveryField?
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession

  var body: some View {
    NavigationStack {
      Form {
        Section {
          serverRow
          if presentation.canTryOtherAddresses {
            Button {
              Task { await presentation.tryOtherAddresses() }
            } label: {
              Label(
                AuthRecoveryCopy.tryOtherAddressesLabel,
                systemImage: "arrow.triangle.2.circlepath")
            }
            .accessibilityHint(AuthRecoveryCopy.tryOtherAddressesAccessibilityHint)
            .accessibilityIdentifier(AuthRecoveryAccessibilityID.sheetTryOtherAddresses)
          }
        }

        Section {
          switch model.authenticationMode {
          case .openID:
            singleSignOnRow
          case .apiToken:
            apiTokenRow
          case .password:
            usernameRow
            passwordRow
          }
        } footer: {
          VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
            if let errorMessage {
              Text(errorMessage)
                .foregroundStyle(.red)
                .accessibilityIdentifier(AuthRecoveryAccessibilityID.sheetErrorMessage)
            }
            if model.authenticationMode == .openID {
              Text(SetupFlowCopy.singleSignOnFootnote)
            }
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(AuthRecoveryCopy.sheetTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(AuthRecoveryCopy.cancelLabel) {
            presentation.cancel()
          }
          .accessibilityIdentifier(AuthRecoveryAccessibilityID.sheetCancelButton)
        }
        ToolbarItem(placement: .confirmationAction) {
          if isSubmitting {
            ProgressView()
              .accessibilityLabel(AuthRecoveryCopy.submittingLabel)
          } else if model.authenticationMode != .openID {
            Button(AuthRecoveryCopy.submitLabel) {
              Task { await presentation.submit() }
            }
            .disabled(isSubmitDisabled)
            .accessibilityIdentifier(AuthRecoveryAccessibilityID.sheetSubmitButton)
          }
        }
      }
    }
    .interactiveDismissDisabled(isSubmitting)
  }

  private var serverRow: some View {
    LabeledContent(AuthRecoveryCopy.sheetServerLabel) {
      Text(model.activeServerDisplayString ?? "")
        .foregroundStyle(WhirrColorToken.textSecondary.color)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(AuthRecoveryAccessibilityID.sheetServerDisplay)
  }

  private var usernameRow: some View {
    TextField(AuthRecoveryCopy.usernameLabel, text: $presentation.username)
      .textContentType(.username)
      .autocorrectionDisabled()
      .textInputAutocapitalization(.never)
      .focused($focusedField, equals: .username)
      .submitLabel(.next)
      .onSubmit { focusedField = .password }
      .frame(minHeight: WhirrMetric.minimumTouchTarget)
      .accessibilityLabel(AuthRecoveryCopy.usernameLabel)
      .accessibilityIdentifier(AuthRecoveryAccessibilityID.sheetUsernameField)
  }

  private var passwordRow: some View {
    SecureField(AuthRecoveryCopy.passwordLabel, text: $model.password)
      .textContentType(.password)
      .focused($focusedField, equals: .password)
      .submitLabel(.go)
      .onSubmit { Task { await presentation.submit() } }
      .frame(minHeight: WhirrMetric.minimumTouchTarget)
      .accessibilityLabel(AuthRecoveryCopy.passwordLabel)
      .accessibilityIdentifier(AuthRecoveryAccessibilityID.sheetPasswordField)
  }

  /// An `.openID` account signs in again at its identity provider; the sheet has no field to fill.
  private var singleSignOnRow: some View {
    Button {
      let browser = SingleSignOnBrowser(session: webAuthenticationSession)
      Task { await presentation.submitSingleSignOn(using: browser) }
    } label: {
      Label(SetupFlowCopy.singleSignOnButtonTitle, systemImage: "person.badge.key.fill")
        .frame(minHeight: WhirrMetric.minimumTouchTarget)
    }
    .disabled(isSubmitting)
    .accessibilityIdentifier(AuthRecoveryAccessibilityID.sheetSingleSignOnButton)
  }

  private var apiTokenRow: some View {
    SecureField(AuthRecoveryCopy.apiTokenLabel, text: $model.apiToken)
      .textContentType(.password)
      .focused($focusedField, equals: .apiToken)
      .submitLabel(.go)
      .onSubmit { Task { await presentation.submit() } }
      .frame(minHeight: WhirrMetric.minimumTouchTarget)
      .accessibilityLabel(AuthRecoveryCopy.apiTokenLabel)
      .accessibilityIdentifier(AuthRecoveryAccessibilityID.sheetAPITokenField)
  }

  private var isSubmitting: Bool {
    if case .submitting = model.state { return true }
    return false
  }

  private var isSubmitDisabled: Bool {
    if model.authenticationMode == .apiToken {
      return isSubmitting || model.apiToken.isEmpty
    }
    return isSubmitting
      || presentation.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || model.password.isEmpty
  }

  private var errorMessage: String? {
    guard case .failed(let error) = model.state else { return nil }
    return AuthRecoveryCopy.errorMessage(for: error).text
  }
}
