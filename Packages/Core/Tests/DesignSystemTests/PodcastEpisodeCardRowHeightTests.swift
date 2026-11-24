#if canImport(AppKit)
  import AppKit
  import SwiftUI
  import Testing

  @testable import DesignSystem

  /// Every episode card in a list is one height, whatever it says. The row's own constants
  /// (`titleLineLimit`, `showTitleLineLimit`, `metadataLineLimit`) are the mechanism; this suite
  /// is the contract, measured on a laid-out row so a later line, font or spacing change that lets
  /// content decide the height fails here rather than on a device.
  @Suite("Podcast episode card row height")
  @MainActor
  struct PodcastEpisodeCardRowHeightTests {
    private static let width: CGFloat = 370

    @Test("content never changes the card's height")
    func contentNeverChangesHeight() {
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
        ("long time", row(durationText: "11 hr 59 min", progressText: "11 hr 58 min left")),
        ("downloaded", row(downloadedLabel: "Downloaded")),
        ("checking for ads", row(downloadedLabel: "Downloaded", isCheckingForAds: true)),
        ("playing", row(isPlaying: true)),
        ("selecting", row(isSelecting: true)),
        (
          "everything at once",
          row(
            title: longTitle, showTitle: longShow, dateText: nil, progressText: "36 min left",
            progressFraction: 0.3, downloadedLabel: "Downloaded")
        ),
      ]

      let baseline = height(of: variants[0].1)
      #expect(baseline > 0)
      for (name, variant) in variants {
        #expect(height(of: variant) == baseline, "\(name) changed the card's height")
      }
    }

    private func height(of row: PodcastEpisodeCardRow<Color>) -> CGFloat {
      let host = NSHostingView(rootView: row.frame(width: Self.width))
      return host.fittingSize.height
    }

    private func row(
      title: String = "329. How close is a global markets crash?",
      showTitle: String = "The Rest Is Money",
      dateText: String? = "Nov 7, 2026",
      durationText: String = "48 min",
      isPlaying: Bool = false,
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
        durationText: durationText,
        accessibilityLabel: title,
        coverSize: PodcastEpisodeCardRowMetrics.coverSize,
        isPlaying: isPlaying,
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
#endif
