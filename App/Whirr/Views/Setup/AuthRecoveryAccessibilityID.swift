/// Semantic accessibility identifiers for the recovery indicator and credential sheet, so
/// `WhirrTests` and any UI automation can address these controls by stable name rather than
/// view-tree position, as `PlayerAccessibilityID` does. `sheetOrder` documents the sheet's
/// top-to-bottom VoiceOver/keyboard-navigation order (matching `AuthRecoverySheetView`'s body) as a
/// plain array, tested without rendering.
enum AuthRecoveryAccessibilityID {
  static let indicator = "authRecovery.indicator"

  static let sheetServerDisplay = "authRecovery.sheet.server"
  static let sheetTryOtherAddresses = "authRecovery.sheet.tryOtherAddresses"
  static let sheetUsernameField = "authRecovery.sheet.username"
  static let sheetPasswordField = "authRecovery.sheet.password"
  static let sheetAPITokenField = "authRecovery.sheet.apiToken"
  static let sheetSingleSignOnButton = "authRecovery.sheet.singleSignOn"
  static let sheetErrorMessage = "authRecovery.sheet.error"
  static let sheetCancelButton = "authRecovery.sheet.cancel"
  static let sheetSubmitButton = "authRecovery.sheet.submit"

  /// Top-to-bottom order inside the credential sheet: the fixed, read-only server identity leads,
  /// then the password-mode username/password pair, the API-token field, or the single-sign-on
  /// button, then the error message (shown only in `.failed`), and finally the two actions with
  /// Cancel leading Reconnect, matching `DestructivePurgeConfirmationView`'s
  /// cancel-before-destructive-action ordering.
  static let sheetOrder: [String] = [
    sheetServerDisplay,
    sheetTryOtherAddresses,
    sheetUsernameField,
    sheetPasswordField,
    sheetAPITokenField,
    sheetSingleSignOnButton,
    sheetErrorMessage,
    sheetCancelButton,
    sheetSubmitButton,
  ]
}
