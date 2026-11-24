import ABSApi
import DesignSystem
import Foundation
import SwiftUI

/// Split out of `SetupFlowView` so a keystroke invalidates only this (see `SetupDraft`). The
/// scheme `Menu` in particular must not be rebuilt per character.
struct ServerURLFields: View {
  @Bindable var draft: SetupDraft
  @FocusState.Binding var focusedField: SetupFlowField?
  let onSubmit: ([String: String]) -> Void

  @State private var headersExpanded = false
  @State private var headerValidationMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.medium) {
      Text("Server address")
        .font(.subheadline.weight(.medium))

      HStack(spacing: 0) {
        Menu {
          ForEach(SetupServerScheme.allCases) { scheme in
            Button {
              draft.scheme = scheme
            } label: {
              Label(scheme.displayName, systemImage: scheme.securitySymbol)
            }
          }
        } label: {
          HStack(spacing: WhirrSpacing.xxSmall) {
            Text(draft.scheme.displayName)
              .font(.body.monospaced())
            Image(systemName: "chevron.up.chevron.down")
              .font(.caption2.weight(.bold))
          }
          .foregroundStyle(.primary)
          .frame(minHeight: WhirrMetric.minimumTouchTarget)
          .padding(.horizontal, WhirrSpacing.small)
          .contentShape(Rectangle())
        }
        .accessibilityLabel("Connection protocol")
        .accessibilityValue(draft.scheme.displayName)

        Divider()
          .frame(height: 28)

        TextField("192.168.1.10:13378", text: $draft.serverAddress)
          .textContentType(.URL)
          .keyboardType(.URL)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .focused($focusedField, equals: .server)
          .submitLabel(.continue)
          .onSubmit(submit)
          .padding(.horizontal, WhirrSpacing.small)
          .frame(minHeight: WhirrMetric.minimumTouchTarget)
          .accessibilityLabel("Server address")
      }

      ProxyHeadersDisclosure(
        draft: draft,
        isExpanded: $headersExpanded,
        validationMessage: $headerValidationMessage
      )

      Button(action: submit) {
        Text("Continue")
          .font(.headline)
          .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.capsule)
      .disabled(draft.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .accessibilityLabel("Continue")
      .id(SetupFlowField.server)
    }
  }

  private func submit() {
    do {
      let headers = try makeHeaderFields()
      headerValidationMessage = nil
      onSubmit(headers)
    } catch let error as CustomHeadersError {
      headerValidationMessage = HeaderValidationCopy.message(for: error, headers: draft.headers)
      headersExpanded = true
    } catch {
      // Fallback in case `CustomHeaders` grows a failure beyond the typed cases above.
      headerValidationMessage = "These proxy headers couldn't be added. Check the key and value."
      headersExpanded = true
    }
  }

  private func makeHeaderFields() throws -> [String: String] {
    var fields: [String: String] = [:]
    var seenNames = Set<String>()

    for header in draft.headers where header.isBlank == false {
      // Validate each row before checking duplicates so an empty or malformed row gets the
      // field-level message, not a duplicate-empty-name report.
      _ = try CustomHeaders([header.name: header.value])

      guard seenNames.insert(header.name.lowercased()).inserted else {
        throw CustomHeadersError.duplicateName
      }
      fields[header.name] = header.value
    }

    return fields
  }

  private enum HeaderValidationCopy {
    static func message(for error: CustomHeadersError, headers: [SetupHeaderDraft]) -> String {
      switch error {
      case .emptyName:
        return "Enter a header name."
      case .invalidName:
        return "Use a valid HTTP header name."
      case .emptyValue:
        return "Enter a value for this header."
      case .invalidValue:
        return "Header values can use visible characters only."
      case .duplicateName:
        let name = duplicateName(in: headers) ?? "This header"
        return "\(name) is entered more than once. Header names are case-insensitive."
      case .authorizationNotAllowed:
        return
          "Authorization is used by Audiobookshelf for its Bearer token. A reverse proxy that requires HTTP Basic authentication is not supported unless it can be configured to accept a different header or a cookie."
      case .reservedName:
        let name = offendingHeaderName(for: error, in: headers) ?? "That header"
        return "\(name) is reserved by the system and can't be added."
      }
    }

    private static func offendingHeaderName(
      for error: CustomHeadersError, in headers: [SetupHeaderDraft]
    ) -> String? {
      headers.first { header in
        do {
          _ = try CustomHeaders([header.name: header.value])
          return false
        } catch let rowError as CustomHeadersError {
          return rowError == error
        } catch {
          return false
        }
      }?.name
    }

    private static func duplicateName(in headers: [SetupHeaderDraft]) -> String? {
      var seen = Set<String>()
      return headers.first { seen.insert($0.name.lowercased()).inserted == false }?.name
    }
  }
}

/// Header entry is isolated from `ServerURLFields` so typing a proxy value does not rebuild the
/// server address controls or their scheme `Menu`. The draft remains the single source of truth;
/// this subview only owns disclosure/error presentation state.
struct ProxyHeadersDisclosure: View {
  @Bindable var draft: SetupDraft
  @Binding var isExpanded: Bool
  @Binding var validationMessage: String?

  /// Rows the user has actually filled in. The disclosure seeds a blank row when it opens, so the
  /// label must not count that seed as a configured header.
  private var configuredHeaderCount: Int {
    draft.headers.count { $0.isBlank == false }
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: WhirrSpacing.small) {
        ForEach($draft.headers) { $header in
          SetupHeaderRow(header: $header) { removeHeader(withID: header.id) }
        }

        Button {
          draft.headers.append(SetupHeaderDraft())
        } label: {
          Label("Add header", systemImage: "plus")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)

        if let validationMessage {
          Text(validationMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("setup.serverHeaders.validationError")
        }
      }
      .padding(.top, WhirrSpacing.xSmall)
    } label: {
      HStack(alignment: .firstTextBaseline, spacing: WhirrSpacing.small) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Advanced")
            .font(.subheadline.weight(.medium))
          Text("Proxy headers")
            .font(.caption)
            .foregroundStyle(WhirrColorToken.textSecondary.color)
        }

        Spacer(minLength: 0)

        if configuredHeaderCount > 0 {
          Text("\(configuredHeaderCount)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(WhirrColorToken.textSecondary.color)
            .accessibilityLabel("\(configuredHeaderCount) proxy headers")
        }
      }
    }
    .onChange(of: isExpanded) { _, expanded in
      // Opening `Advanced` is itself the request to enter a header, so seed a row instead of
      // opening onto a lone `Add header` button.
      if expanded, draft.headers.isEmpty {
        draft.headers.append(SetupHeaderDraft())
      }
    }
    .onChange(of: draft.headers) { _, _ in
      if validationMessage != nil {
        validationMessage = nil
      }
    }
  }

  private func removeHeader(withID id: UUID) {
    draft.headers.removeAll { $0.id == id }
  }
}

private struct SetupHeaderRow: View {
  @Binding var header: SetupHeaderDraft
  let onDelete: () -> Void

  var body: some View {
    let deleteAction = SetupFlowLayout.deleteHeaderAction

    HStack(spacing: WhirrSpacing.xSmall) {
      TextField("Key", text: $header.name)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Header key")

      Text(":")
        .foregroundStyle(.secondary)

      switch SetupFlowLayout.headerValueFieldPresentation {
      case .secure:
        SecureField("Value", text: $header.value)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("Header value")
      }

      // A visible control, not a swipe action. These rows sit inside one `Form` row, not `List`
      // rows, so per-row `swipeActions` collapse onto the enclosing row and a swipe shows one
      // Delete button per header.
      Button(role: deleteAction.buttonRole, action: onDelete) {
        Image(systemName: deleteAction.systemImage)
      }
      .buttonStyle(.borderless)
      .frame(minWidth: WhirrMetric.minimumTouchTarget)
      .accessibilityLabel(deleteAction.title)
    }
    .frame(minHeight: WhirrMetric.minimumTouchTarget)
  }
}
