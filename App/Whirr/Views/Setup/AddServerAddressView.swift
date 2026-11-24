import AppModel
import DesignSystem
import SwiftUI

private enum AddCredentialMode: String, CaseIterable, Identifiable {
  case password
  case apiToken

  var id: Self { self }
  var title: String { self == .password ? "Password" : "API token" }
}

struct AddServerAddressView: View {
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: ServerAddressesModel
  @State private var draft = SetupDraft()
  @State private var credentialMode = AddCredentialMode.password
  @State private var username = ""
  @State private var password = ""
  @State private var apiToken = ""
  @State private var submittedHeaders: [String: String] = [:]
  @FocusState private var focusedField: SetupFlowField?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          ServerURLFields(
            draft: draft, focusedField: $focusedField,
            onSubmit: { headers in submit(headers: headers) })
        }

        if case .needsCredentials = model.addState {
          credentialsSection
        }

        if case .failed(let message) = model.addState {
          Section {
            Text(message)
              .foregroundStyle(.red)
              .accessibilityIdentifier(ScreenAccessibilityID.serverAddressError)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(ServerAddressesCopy.addTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(ServerAddressesCopy.cancel) { dismiss() }
        }
      }
    }
    .interactiveDismissDisabled(model.addState == .probing)
    .onAppear { model.resetAddState() }
    .task {
      // The sheet is presented at a single large detent, so the keyboard cannot resize it. Focus
      // has to wait for the presentation animation: a request made on the first frame is dropped
      // while the sheet is still being installed, leaving the field cold.
      try? await Task.sleep(for: .milliseconds(300))
      focusedField = .server
    }
    .onChange(of: model.addState) { _, state in
      if state == .added { dismiss() }
    }
  }

  private var credentialsSection: some View {
    Section(ServerAddressesCopy.credentialsTitle) {
      Picker("Sign-in method", selection: $credentialMode) {
        ForEach(AddCredentialMode.allCases) { mode in
          Text(mode.title).tag(mode)
        }
      }
      .pickerStyle(.segmented)

      if credentialMode == .password {
        TextField(ServerAddressesCopy.username, text: $username)
          .textContentType(.username)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .focused($focusedField, equals: .username)
          .accessibilityIdentifier(ScreenAccessibilityID.serverAddressUsername)
        SecureField(ServerAddressesCopy.password, text: $password)
          .textContentType(.password)
          .focused($focusedField, equals: .password)
          .accessibilityIdentifier(ScreenAccessibilityID.serverAddressPassword)
        Button(ServerAddressesCopy.verifyAndAdd) {
          Task { await model.add(address: address, headers: submittedHeaders, username: username, password: password) }
        }
        .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
      } else {
        SecureField(ServerAddressesCopy.apiToken, text: $apiToken)
          .textContentType(.password)
          .focused($focusedField, equals: .apiToken)
          .accessibilityIdentifier(ScreenAccessibilityID.serverAddressAPIToken)
        Button(ServerAddressesCopy.verifyAndAdd) {
          Task { await model.add(address: address, headers: submittedHeaders, apiToken: apiToken) }
        }
        .disabled(apiToken.isEmpty)
      }
    }
  }

  private var address: String {
    "\(draft.scheme.rawValue)://\(draft.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines))"
  }

  private func submit(headers: [String: String]) {
    submittedHeaders = headers
    Task { await model.add(address: address, headers: headers) }
  }
}
