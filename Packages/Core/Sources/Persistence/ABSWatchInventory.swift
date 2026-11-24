import Foundation

/// The Audiobookshelf half of one inventory, already matched to the signed-in account. `App` maps
/// the wire entries into these terms and resolves a title for each phone-origin entry, so a row
/// the phone lost can be re-adopted with something to show.
public struct ABSWatchInventory: Sendable, Equatable {
  public struct Entry: Sendable, Equatable {
    /// The Watch's group states in the store's terms. `receiving` covers queued, downloading and
    /// held for Wi-Fi, which the screen reads from the live projection instead.
    public enum State: Sendable, Equatable {
      case receiving
      case ready
      case removed
      case declined
      case failed
    }

    public let key: ABSWatchCopyKey
    /// The phone's revision for a phone-origin group; `nil` for one the Watch started.
    public let revision: Int64?
    public let state: State
    public let declineReason: RSSWatchDeclineReason?
    public let failureReason: ABSWatchFailureReason?
    public let committedBytes: Int64?
    /// What a re-adopted row is titled; ignored for a row the phone already has.
    public let title: String
    public let subtitle: String?

    public init(
      key: ABSWatchCopyKey, revision: Int64?, state: State,
      declineReason: RSSWatchDeclineReason? = nil, failureReason: ABSWatchFailureReason? = nil,
      committedBytes: Int64? = nil, title: String, subtitle: String? = nil
    ) {
      self.key = key
      self.revision = revision
      self.state = state
      self.declineReason = declineReason
      self.failureReason = failureReason
      self.committedBytes = committedBytes
      self.title = title
      self.subtitle = subtitle
    }

    public var isPhoneOrigin: Bool { revision != nil }
  }

  public let watchInstallID: String
  public let sequence: UInt64
  /// The account the Watch stamped the entries with, already equal to the phone's own.
  public let accountIdentityHash: String
  public let acknowledgedGeneration: UInt64
  public let entries: [Entry]

  public init(
    watchInstallID: String, sequence: UInt64, accountIdentityHash: String,
    acknowledgedGeneration: UInt64, entries: [Entry]
  ) {
    self.watchInstallID = watchInstallID
    self.sequence = sequence
    self.accountIdentityHash = accountIdentityHash
    self.acknowledgedGeneration = acknowledgedGeneration
    self.entries = entries
  }
}

public struct ABSWatchCopyInventoryOutcome: Sendable, Equatable {
  /// `false` for a late or repeated sequence from the same install: nothing was read from it.
  public let applied: Bool
  public let changedKeys: [ABSWatchCopyKey]
  public let installReplaced: Bool

  public init(applied: Bool, changedKeys: [ABSWatchCopyKey], installReplaced: Bool) {
    self.applied = applied
    self.changedKeys = changedKeys
    self.installReplaced = installReplaced
  }
}

public struct ABSWatchCopyObservation: Sendable, Equatable {
  public let copies: [ABSWatchCopy]
  public let set: ABSWatchCopySetState

  public init(copies: [ABSWatchCopy], set: ABSWatchCopySetState) {
    self.copies = copies
    self.set = set
  }
}
