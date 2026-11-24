import Foundation
import Observation

enum SetupFlowField: Hashable {
  case server
  case username
  case password
  case apiToken
}

enum SetupServerScheme: String, CaseIterable, Identifiable {
  case http
  case https

  var id: Self { self }
  var displayName: String { "\(rawValue)://" }
  var securitySymbol: String { self == .https ? "lock.fill" : "network" }
}

enum SetupCredentialMode: String, CaseIterable, Identifiable {
  case password
  case apiToken

  var id: Self { self }
  var displayName: String { self == .password ? "Password" : "API token" }
}

struct SetupHeaderDraft: Identifiable, Equatable {
  let id: UUID
  var name: String
  var value: String

  init(id: UUID = UUID(), name: String = "", value: String = "") {
    self.id = id
    self.name = name
    self.value = value
  }

  /// A row the user has not typed into. Opening `Advanced` seeds one so the disclosure is never
  /// empty, and an untouched seed must not fail submission the way a half-filled row does.
  var isBlank: Bool {
    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

/// What the user has typed, in an `@Observable` reference, not `SetupFlowView`'s `@State`, which
/// would invalidate the whole surface and scheme `Menu` per keystroke (logging
/// `-[UIContextMenuInteraction updateVisibleMenuWithBlock:]`). It also keeps a half-typed
/// username alive across `.loggingIn`, which replaces the subviews.
@MainActor
@Observable
final class SetupDraft {
  var scheme: SetupServerScheme = .https
  var serverAddress = ""
  var username = ""
  var credentialMode: SetupCredentialMode = .password
  var headers: [SetupHeaderDraft] = []

  func forgetServerScopedSecrets() {
    headers.removeAll()
  }
}
