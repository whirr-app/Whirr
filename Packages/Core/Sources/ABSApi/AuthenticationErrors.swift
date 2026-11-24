/// A local credential wipe failed after (or independently of) the server logout attempt. This is
/// distinct from the server-side error so account-removal callers can retain their
/// durable identity and offer a retry instead of deleting the account row.
public enum LogoutError: Error {
  case localCredentialClearFailed(underlying: any Error)
}

/// Same-account reauthentication is a hard, non-mutating refusal when the login response
/// identifies a different server user than `expectedAccount`.
public enum ReauthenticationError: Error, Sendable, Equatable {
  case accountMismatch
  /// The server accepted the credentials and the identity guard passed, but the rotated pair
  /// could not be written to the token store.
  case tokenPersistenceFailed(underlying: any Error)

  /// Hand-written because `underlying` is an existential. Case identity is what callers switch
  /// on; the payload exists for logging, so comparing it is neither possible nor wanted.
  public static func == (lhs: ReauthenticationError, rhs: ReauthenticationError) -> Bool {
    switch (lhs, rhs) {
    case (.accountMismatch, .accountMismatch): return true
    case (.tokenPersistenceFailed, .tokenPersistenceFailed): return true
    default: return false
    }
  }
}
