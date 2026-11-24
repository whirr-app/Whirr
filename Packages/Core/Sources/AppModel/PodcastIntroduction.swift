import Foundation

/// The one-time Podcasts introduction sheet. Informational only: it grants no consent and
/// opens no CloudKit path. It teaches what the tab holds and nothing else; sync and subscription
/// transfer are explained in Settings > Podcasts next to their controls.
public enum PodcastIntroductionPresentation {
  /// Bump when the copy changes enough that existing users should see it again.
  public static let currentVersion = 3

  /// One row of the welcome sheet: a symbol, a short bold label and a single sentence.
  public struct Row: Equatable, Hashable, Sendable {
    public let systemImage: String
    public let title: String
    public let detail: String

    public init(systemImage: String, title: String, detail: String) {
      self.systemImage = systemImage
      self.title = title
      self.detail = detail
    }
  }

  public static func shouldPresent(seenVersion: Int?, nativeSubscriptionsEnabled: Bool) -> Bool {
    guard nativeSubscriptionsEnabled else { return false }
    return (seenVersion ?? 0) < currentVersion
  }

  public static func lede(hasServerAccount: Bool) -> String {
    hasServerAccount ? PodcastIntroductionCopy.serverLede : PodcastIntroductionCopy.deviceLede
  }

  public static func rows(hasServerAccount: Bool) -> [Row] {
    var result = [PodcastIntroductionCopy.followRow]
    if hasServerAccount {
      result.append(PodcastIntroductionCopy.libraryRow)
    }
    return result
  }
}

public enum PodcastIntroductionCopy {
  public static let title = "Podcasts in Whirr"
  public static let deviceLede = "Follow shows from anywhere, right on this device."
  public static let serverLede = "Follow shows from anywhere, alongside your Audiobookshelf library."
  public static let followRow = PodcastIntroductionPresentation.Row(
    systemImage: "plus.circle", title: "Follow any show.",
    detail: "Search for it or paste a feed address. Followed shows live on this device.")
  /// Only shown when an included Audiobookshelf podcast library exists; without one the tab has
  /// no server shows to describe.
  public static let libraryRow = PodcastIntroductionPresentation.Row(
    systemImage: "books.vertical", title: "Your library, too.",
    detail: "Audiobookshelf podcasts appear alongside them, with progress kept by your server.")
  public static let dismiss = "Continue"
}

public protocol PodcastIntroductionDefaults: AnyObject {
  func integerValue(forKey key: String) -> Int?
  func setIntegerValue(_ value: Int, forKey key: String)
}

extension UserDefaults: PodcastIntroductionDefaults {
  public func integerValue(forKey key: String) -> Int? {
    object(forKey: key) as? Int
  }

  public func setIntegerValue(_ value: Int, forKey key: String) {
    set(value, forKey: key)
  }
}

public protocol PodcastIntroductionMarking: Sendable {
  func seenVersion() -> Int?
  func markSeen()
}

/// Ordinary device-local marker. It may migrate with a device backup: re-showing the sheet after a
/// restore is harmless, unlike consent, so no install identity is involved. Keep the key out of
/// `ICloudSettingsSync.syncedKeys`.
public final class PodcastIntroductionPreference: PodcastIntroductionMarking, @unchecked Sendable {
  public static let storageKey = "podcasts.introduction.seenVersion"

  private let lock = NSLock()
  private let defaults: any PodcastIntroductionDefaults

  public init(defaults: any PodcastIntroductionDefaults) {
    self.defaults = defaults
  }

  public func seenVersion() -> Int? {
    lock.lock()
    defer { lock.unlock() }
    return defaults.integerValue(forKey: Self.storageKey)
  }

  public func markSeen() {
    lock.lock()
    defer { lock.unlock() }
    defaults.setIntegerValue(PodcastIntroductionPresentation.currentVersion, forKey: Self.storageKey)
  }
}

/// For hosts that must never show the sheet (UI harness, previews).
public struct AlreadySeenPodcastIntroduction: PodcastIntroductionMarking {
  public init() {}
  public func seenVersion() -> Int? { PodcastIntroductionPresentation.currentVersion }
  public func markSeen() {}
}
