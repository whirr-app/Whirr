import Foundation
import Persistence

/// Where a show's episodes come from, as Show Settings names it. Derived from the item id alone
/// (`PodcastSourceIdentity`), never from which sections happen to be present, so the answer is the
/// same on a show the server has said nothing about and on a feed that has not refreshed yet.
public enum PodcastShowSource: Sendable, Equatable {
  case audiobookshelf
  case rssFeed
}

public enum PodcastShowSourceField: Sendable, Equatable, Hashable {
  case source
  case feedURL
}

public struct PodcastShowSourceRow: Sendable, Equatable, Identifiable {
  public let field: PodcastShowSourceField
  public let label: String
  public let value: String

  public var id: PodcastShowSourceField { field }

  public init(field: PodcastShowSourceField, label: String, value: String) {
    self.field = field
    self.label = label
    self.value = value
  }
}

/// The read-only "Source" section of Show Settings. Present for every show: an ABS show says so
/// (and is followed further down by the server's own settings), an RSS show says so and names the
/// feed it is followed from.
public struct PodcastShowSourceSection: Sendable, Equatable {
  public let rows: [PodcastShowSourceRow]
  public let footer: String

  public init(rows: [PodcastShowSourceRow], footer: String) {
    self.rows = rows
    self.footer = footer
  }
}

/// Pure mapping from a show's source (plus, for a feed, its URL and last refresh) to the section.
/// It knows nothing about the server section: an RSS show never gets one, and this type supplies
/// the device-side facts instead.
public enum PodcastShowSourcePresentation {
  public static let sectionHeader = "Source"
  public static let sourceLabel = "Source"
  public static let feedURLLabel = "Feed"

  public static func source(itemID: String) -> PodcastShowSource? {
    guard let identity = PodcastSourceIdentity(itemId: itemID) else { return nil }
    switch identity.source {
    case .abs: return .audiobookshelf
    case .rss: return .rssFeed
    }
  }

  public static func sourceValue(_ source: PodcastShowSource) -> String {
    switch source {
    case .audiobookshelf: "Audiobookshelf"
    case .rssFeed: "RSS Feed"
    }
  }

  /// `feedURL` and `lastChecked` are only meaningful for `.rssFeed` and are ignored otherwise. An
  /// ABS show's last check belongs to the server section, which reports it in the server's terms.
  public static func section(
    source: PodcastShowSource,
    feedURL: URL? = nil,
    lastChecked: Date? = nil,
    now: Date
  ) -> PodcastShowSourceSection {
    var rows = [
      PodcastShowSourceRow(field: .source, label: sourceLabel, value: sourceValue(source))
    ]
    switch source {
    case .audiobookshelf:
      return PodcastShowSourceSection(rows: rows, footer: audiobookshelfFooter)
    case .rssFeed:
      if let feedURL {
        rows.append(
          PodcastShowSourceRow(field: .feedURL, label: feedURLLabel, value: feedURL.absoluteString))
      }
      return PodcastShowSourceSection(
        rows: rows, footer: rssFeedFooter(lastChecked: lastChecked, now: now))
    }
  }

  static let audiobookshelfFooter = "Synced from your Audiobookshelf library."

  /// The show screen's one-line answer for every show. Both kinds are named because they sit side
  /// by side in the Library once a feed is saved to the server.
  public static let rssFeedShowCaption = "Followed on this device"
  public static let audiobookshelfShowCaption = "On your Audiobookshelf server"

  public static func showCaption(itemID: String) -> String? {
    switch source(itemID: itemID) {
    case .rssFeed: rssFeedShowCaption
    case .audiobookshelf: audiobookshelfShowCaption
    case nil: nil
    }
  }

  /// Names the device as the owner, so a feed never sends the user to the web app to change
  /// settings the server does not have.
  static let rssFeedOwnership =
    "Followed directly on this device. It is not on your Audiobookshelf server."

  public static func rssFeedFooter(lastChecked: Date?, now: Date) -> String {
    guard let lastChecked else { return rssFeedOwnership }
    return "\(PodcastCopy.lastCheckedSentence(lastChecked, now: now)). \(rssFeedOwnership)"
  }
}
