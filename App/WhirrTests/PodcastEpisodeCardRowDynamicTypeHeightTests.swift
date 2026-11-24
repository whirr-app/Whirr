import DesignSystem
import SwiftUI
import Testing
import UIKit

/// The iOS half of the episode card's one-height contract. `PodcastEpisodeCardRowHeightTests`
/// pins it in the package on macOS; this measures the same row with iOS fonts at every Dynamic
/// Type size, because that is where a line that wraps at one size and not another shows up.
@MainActor
@Suite("Podcast episode card row height across Dynamic Type")
struct PodcastEpisodeCardRowDynamicTypeHeightTests {
  private static let width: CGFloat = 370

  @Test("content never changes the card's height at any text size", arguments: DynamicTypeSize.allCases)
  func contentNeverChangesHeight(size: DynamicTypeSize) {
    let longTitle =
      "720. Revolution in the Soviet Empire: Revenge of the Nations, and what came after it"
    let longShow = "The Rest Is History: an extremely long podcast name that cannot fit"
    let variants: [(String, PodcastEpisodeCardRow<Color>)] = [
      ("baseline", row()),
      ("one-word title", row(title: "Ok")),
      ("long title", row(title: longTitle)),
      ("long show", row(showTitle: longShow)),
      ("undated", row(dateText: nil)),
      ("started", row(progressText: "36 min left", progressFraction: 0.3)),
      ("downloaded", row(downloadedLabel: "Downloaded")),
      ("checking for ads", row(downloadedLabel: "Downloaded", isCheckingForAds: true)),
      ("selecting", row(isSelecting: true)),
      (
        "everything at once",
        row(
          title: longTitle, showTitle: longShow, dateText: nil, progressText: "11 hr 58 min left",
          progressFraction: 0.3, downloadedLabel: "Downloaded")
      ),
    ]

    let baseline = height(of: variants[0].1, size: size)
    #expect(baseline > 0)
    for (name, variant) in variants {
      #expect(height(of: variant, size: size) == baseline, "\(name) changed the height at \(size)")
    }
  }

  private func height(of row: PodcastEpisodeCardRow<Color>, size: DynamicTypeSize) -> CGFloat {
    let host = UIHostingController(
      rootView: row.frame(width: Self.width).environment(\.dynamicTypeSize, size))
    return host.sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude)).height
  }

  private func row(
    title: String = "329. How close is a global markets crash?",
    showTitle: String = "The Rest Is Money",
    dateText: String? = "Nov 7, 2026",
    isSelecting: Bool = false,
    progressText: String? = nil,
    progressFraction: Double? = nil,
    downloadedLabel: String? = nil,
    isCheckingForAds: Bool = false
  ) -> PodcastEpisodeCardRow<Color> {
    PodcastEpisodeCardRow(
      title: title,
      showTitle: showTitle,
      dateText: dateText,
      durationText: "48 min",
      accessibilityLabel: title,
      coverSize: PodcastEpisodeCardRowMetrics.coverSize,
      isSelecting: isSelecting,
      progressText: progressText,
      progressFraction: progressFraction,
      downloadedLabel: downloadedLabel,
      isCheckingForAds: isCheckingForAds,
      cover: { Color.gray },
      onSelect: {},
      onPlay: {})
  }
}
