import SyncEngine
import Testing

@testable import AppModel

/// The recovery indicator/sheet copy catalog, tested directly without constructing any view, as
/// `SetupFlowModelTests` does.
@Suite("Auth recovery copy")
struct AuthRecoveryCopyTests {

  @Test("the indicator distinguishes existing downloads from server actions")
  func indicatorDistinguishesExistingDownloadsFromServerActions() {
    #expect(
      AuthRecoveryCopy.indicatorMessage
        == "Existing downloads remain available. Reconnect to download or sync.")
  }

  @Test("indicator copy explains downloads remain available, and no string in the catalog uses forbidden wording")
  func recoveryIndicatorCopyExplainsDownloadsRemainAvailable() {
    let indicator = "\(AuthRecoveryCopy.indicatorTitle) \(AuthRecoveryCopy.indicatorMessage)".lowercased()
    #expect(indicator.contains("downloads"))
    #expect(
      indicator.contains("still here") || indicator.contains("available")
        || indicator.contains("ready to play"))

    for copy in AuthRecoveryCopy.allCopy {
      let lowercased = copy.lowercased()
      #expect(lowercased.contains("logout") == false, "forbidden wording in: \(copy)")
      #expect(lowercased.contains("account removed") == false, "forbidden wording in: \(copy)")
      #expect(lowercased.contains("downloads deleted") == false, "forbidden wording in: \(copy)")
    }
  }

  /// Whirr has no account switcher. The only way onto a different account is Log Out under
  /// Settings › Server & Account, so the copy names that control where it lives.
  @Test("the mismatch copy names the real Log Out control, not an account switcher")
  func accountMismatchNamesTheRealControl() {
    let recovery = AuthRecoveryCopy.errorMessage(for: .accountMismatch).text
    #expect(recovery.contains(SettingsCopy.confirmLogout))
    #expect(recovery.contains(ServerAccountSettingsCopy.destinationTitle))
    #expect(recovery.lowercased().contains("settings"))

    for text in [recovery, SetupFlowCopy.recoveryMessage(for: .accountMismatch).text] {
      #expect(text.lowercased().contains("switch") == false, "names a control that doesn't exist: \(text)")
    }
  }

  @Test("every AccountLifecycleError category gets distinct, non-empty recovery copy")
  func errorMessagesAreDistinctPerCategory() {
    let invalidCredentials = AuthRecoveryCopy.errorMessage(for: .invalidCredentials)
    let unreachable = AuthRecoveryCopy.errorMessage(for: .unreachable)
    let tlsUntrusted = AuthRecoveryCopy.errorMessage(for: .tlsUntrusted)
    let accountMismatch = AuthRecoveryCopy.errorMessage(for: .accountMismatch)
    let loginRateLimited = AuthRecoveryCopy.errorMessage(
      for: .loginRateLimited(retryAfter: 30))
    let localPersistenceFailed = AuthRecoveryCopy.errorMessage(for: .localPersistenceFailed)
    let localStateUnreadable = AuthRecoveryCopy.errorMessage(for: .localStateUnreadable)
    let keychainUnavailable = AuthRecoveryCopy.errorMessage(for: .keychainUnavailable)

    let texts = [
      invalidCredentials.text, unreachable.text, tlsUntrusted.text, accountMismatch.text,
      loginRateLimited.text, localPersistenceFailed.text, localStateUnreadable.text,
      keychainUnavailable.text,
    ]
    #expect(Set(texts).count == texts.count)
    #expect(texts.allSatisfy { $0.isEmpty == false })

    let keys = [
      invalidCredentials.key, unreachable.key, tlsUntrusted.key, accountMismatch.key,
      loginRateLimited.key, localPersistenceFailed.key, localStateUnreadable.key,
      keychainUnavailable.key,
    ]
    #expect(Set(keys).count == keys.count)
  }

  /// A build that cannot reach its Keychain access group will never succeed on retry, and the
  /// device is not at fault, so this must not inherit `.localPersistenceFailed`'s "unlock the
  /// device and free up space" instruction.
  @Test("an unavailable keychain names the build, not the device, and still reassures about downloads")
  func keychainUnavailableCopyNamesTheBuild() {
    let text = AuthRecoveryCopy.errorMessage(for: .keychainUnavailable).text.lowercased()

    #expect(text.contains("build") || text.contains("app"))
    #expect(text.contains("download"))
    #expect(text.contains("free space") == false)
    #expect(text.contains("unlock") == false)
  }

  @Test("rate-limited recovery copy says the attempt was not sent and gives a retry window")
  func rateLimitedCopySaysAttemptWasNotSentAndGivesRetryWindow() {
    let text = AuthRecoveryCopy.errorMessage(for: .loginRateLimited(retryAfter: 30)).text.lowercased()

    #expect(text.contains("not sent") || text.contains("wasn't sent"))
    #expect(text.contains("try again"))
    #expect(text.contains("30") && text.contains("second"))
    #expect(text.contains("wrong") == false)
    #expect(text.contains("password") == false)
    #expect(text.contains("credential") == false)
  }

  @Test("unreachable and invalid-credentials copy both say downloads remain available and permit retry")
  func unreachableAndInvalidCredentialsCopyPermitRetryAndReassureAboutDownloads() {
    for error in [AccountLifecycleError.unreachable, .invalidCredentials] {
      let text = AuthRecoveryCopy.errorMessage(for: error).text.lowercased()
      #expect(text.contains("download"))
      #expect(text.contains("try again") || text.contains("check your"))
    }
  }

  @Test("TLS-untrusted recovery copy is distinct from setup's and still names the certificate")
  func tlsUntrustedCopyNamesTheCertificate() {
    let text = AuthRecoveryCopy.errorMessage(for: .tlsUntrusted).text.lowercased()
    #expect(text.contains("certificate"))
  }
}
