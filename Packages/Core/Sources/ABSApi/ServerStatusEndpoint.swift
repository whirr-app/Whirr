/// Pre-login `GET /status` response (API-CONVENTIONS.md rule 23).
public struct ServerStatus: Sendable, Equatable {
  /// The server's own name for itself (`"audiobookshelf"` on a real one). Before credentials are
  /// sent, this is the only proof the address belongs to Audiobookshelf.
  ///
  /// Optional, never a decode failure: the lifecycle layer owns the refusal so it can give a
  /// specific recovery message. A decoder rejection would read as an unreachable server.
  public let app: String?
  public let serverVersion: String
  /// The sign-in methods the server accepts (`authMethods`). Nil when the field is absent or not
  /// an array. Every server at the 2.35.1 floor sends it, so nil means a malformed response, not
  /// evidence about which methods the server refuses.
  public let authMethods: Set<ServerAuthMethod>?
  /// The administrator's label for the SSO button (`authFormData.authOpenIDButtonText`), sent only
  /// while OpenID is enabled. Nil when absent, blank or not a string.
  public let openIDButtonText: String?

  public init(
    serverVersion: String, app: String? = nil, authMethods: Set<ServerAuthMethod>? = nil,
    openIDButtonText: String? = nil
  ) {
    self.app = app
    self.serverVersion = serverVersion
    self.authMethods = authMethods
    self.openIDButtonText = openIDButtonText
  }
}

/// One entry of `/status` `authMethods`. A value Whirr does not know is kept rather than dropped,
/// so a future method can never be mistaken for, or hide, a known one.
public enum ServerAuthMethod: Sendable, Hashable {
  /// Username and password (`"local"`).
  case local
  /// OpenID Connect single sign-on (`"openid"`).
  case openID
  case unrecognized(String)

  init(wireValue: String) {
    switch wireValue {
    case "local": self = .local
    case "openid": self = .openID
    default: self = .unrecognized(wireValue)
    }
  }
}

extension ABSClient {
  /// Setup calls this before the compatibility gate runs, so it uses the unauthenticated composed
  /// transport floor rather than an account-scoped authenticated client.
  public func fetchServerStatus() async throws -> ServerStatus {
    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/status",
      routeTemplate: "/status"
    ).reportingRefusedRedirect()
    let response = try await send(request)
    try validateSuccess(response)
    let dto = try decoder.decode(ServerStatusDTO.self, from: response.body, endpoint: "/status")
    return ServerStatus(
      serverVersion: dto.serverVersion,
      app: dto.app,
      // A non-string entry is dropped; a non-array field is nil (`LossyOptional`).
      authMethods: dto.authMethods.map { Set($0.compactMap(\.wrappedValue).map(ServerAuthMethod.init(wireValue:))) },
      openIDButtonText: dto.authFormData?.authOpenIDButtonText
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .flatMap { $0.isEmpty ? nil : $0 }
    )
  }
}

/// Every field but `serverVersion` is lossy: `/status` gates setup, and a malformed optional field
/// must not turn a reachable server into "couldn't read the response".
private struct ServerStatusDTO: Decodable {
  @LossyOptional var app: String?
  let serverVersion: String
  @LossyOptional var authMethods: [LossyOptional<String>]?
  @LossyOptional var authFormData: AuthFormDataDTO?
}

private struct AuthFormDataDTO: Decodable {
  @LossyOptional var authOpenIDButtonText: String?
}
