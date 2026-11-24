import Foundation
import Persistence

/// One label/value line in the item's publication details.
public struct ItemDetailAboutRow: Sendable, Equatable {
  public let label: String
  public let value: String

  public init(label: String, value: String) {
    self.label = label
    self.value = value
  }
}

/// The item's publication details, kept separate from the App-side view that lays them out.
public enum ItemDetailAboutPresentation {
  /// ABS descriptions arrive as HTML, exactly like podcast feed synopses, so they go through the
  /// same `FeedHTML.plainText` door rather than rendering their tags.
  public static func trimmed(_ description: String?) -> String? {
    PodcastShowPresentation.synopsis(from: description)
  }

  /// Only the fields the item actually has. Duration is preformatted by the App target because
  /// its formatter is presentation-specific and does not belong in Core.
  public static func rows(
    for item: ItemSummary,
    formattedDuration: String?,
    formattedAudioDownloadSize: String? = nil,
    formattedEbookDownloadSize: String? = nil
  ) -> [ItemDetailAboutRow] {
    var rows: [ItemDetailAboutRow] = []
    if ItemDetailDurationPresentation.showsDuration(
      category: item.category, durationSeconds: item.durationSeconds)
    {
      appendRow(&rows, label: "Duration", value: formattedDuration)
    }
    if item.category == .audiobook, item.hasReadableEbook {
      appendRow(&rows, label: "Audiobook download", value: formattedAudioDownloadSize)
      appendRow(&rows, label: "eBook download", value: formattedEbookDownloadSize)
    } else if item.category == .audiobook {
      appendRow(&rows, label: "Download size", value: formattedAudioDownloadSize)
    } else if item.hasReadableEbook {
      appendRow(&rows, label: "Download size", value: formattedEbookDownloadSize)
    }
    return rows
  }

  private static func appendRow(_ rows: inout [ItemDetailAboutRow], label: String, value: String?) {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      value.isEmpty == false
    else {
      return
    }
    rows.append(ItemDetailAboutRow(label: label, value: value))
  }
}
