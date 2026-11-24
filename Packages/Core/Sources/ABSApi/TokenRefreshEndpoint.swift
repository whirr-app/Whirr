import Foundation

extension ABSClient {
  /// Refreshes the stored pair through this client's cached authenticated transport. Callers that
  /// own the live account client must use this operation rather than constructing another client:
  /// the server rotates refresh tokens, so a second cache would retain an already-invalidated pair.
  public func refreshTokens(for account: TokenAccount) async throws -> TokenPair {
    let tokens = try loadTokens(for: account)
    return try await authenticatedTransport(for: account, initialTokens: tokens).forceRefresh()
  }
}
