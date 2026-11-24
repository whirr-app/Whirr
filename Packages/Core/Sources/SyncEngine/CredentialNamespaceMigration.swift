import ABSApi
import CoreSupport
import Persistence

/// Copies the one pre-namespace token pair into the account's stable credential namespace.
///
/// The App runs this once per process entry point (`AppEnvironment.init`,
/// `PodcastBackgroundRefreshHardware.handle`), after the database opens and before anything reads
/// tokens. Not part of `AccountLifecycleService.init`: a Keychain read there runs several times
/// per launch and would consume a store's first failure before the login path can classify it.
public enum CredentialNamespaceMigration {
  private static let logger = CoreLogging.logger(category: "account")

  public enum Step: Sendable, Equatable {
    case load
    case save
    case verify
    case clearLegacy
  }

  public enum Outcome: Sendable, Equatable {
    case noAccount
    case alreadyMigrated
    case nothingToMigrate
    case migrated
    case failed(step: Step)
  }

  /// Logs its own outcome, so callers may discard it. Only the outcome's case name is logged.
  public static func run(
    accountDAO: AccountDAO, tokenStore: any TokenStoring
  ) -> Outcome {
    let outcome = migrate(accountDAO: accountDAO, tokenStore: tokenStore)
    switch outcome {
    case .noAccount, .alreadyMigrated, .nothingToMigrate:
      break
    case .migrated:
      logger.notice("credential namespace migration moved the legacy pair")
    case .failed(let step):
      logger.error(
        "credential namespace migration failed at \(String(describing: step), privacy: .public)")
    }
    return outcome
  }

  private static func migrate(
    accountDAO: AccountDAO, tokenStore: any TokenStoring
  ) -> Outcome {
    let account: AccountRecord
    do {
      guard let fetched = try accountDAO.fetch() else { return .noAccount }
      account = fetched
    } catch {
      return .failed(step: .load)
    }

    let namespaceAccount: TokenAccount
    let legacyAccount: TokenAccount
    do {
      namespaceAccount = try account.credentialTokenAccount
      if try tokenStore.load(for: namespaceAccount) != nil {
        if let leftover = try? TokenAccount(serverURL: try account.activeServerURL, userID: account.serverUserId) {
          sweepLeftover(leftover, from: tokenStore)
        }
        return .alreadyMigrated
      }
      legacyAccount = try TokenAccount(serverURL: try account.activeServerURL, userID: account.serverUserId)
    } catch {
      return .failed(step: .load)
    }

    let legacyTokens: TokenPair
    do {
      guard let tokens = try tokenStore.load(for: legacyAccount) else {
        return .nothingToMigrate
      }
      legacyTokens = tokens
    } catch {
      return .failed(step: .load)
    }

    do {
      try tokenStore.save(legacyTokens, for: namespaceAccount)
    } catch {
      try? tokenStore.clear(for: namespaceAccount)
      return .failed(step: .save)
    }

    do {
      guard try tokenStore.load(for: namespaceAccount) == legacyTokens else {
        try? tokenStore.clear(for: namespaceAccount)
        return .failed(step: .verify)
      }
    } catch {
      try? tokenStore.clear(for: namespaceAccount)
      return .failed(step: .verify)
    }

    do {
      try tokenStore.clear(for: legacyAccount)
    } catch {
      try? tokenStore.clear(for: namespaceAccount)
      return .failed(step: .clearLegacy)
    }
    return .migrated
  }

  /// An earlier run whose legacy clear and compensating namespace clear both failed leaves a
  /// live pair under the legacy key, which nothing reads and only account removal would sweep.
  private static func sweepLeftover(_ legacyAccount: TokenAccount, from tokenStore: any TokenStoring) {
    do {
      guard try tokenStore.load(for: legacyAccount) != nil else { return }
      try tokenStore.clear(for: legacyAccount)
      logger.notice("credential namespace migration swept a leftover legacy pair")
    } catch {
      logger.error("credential namespace migration could not sweep a leftover legacy pair")
    }
  }
}
