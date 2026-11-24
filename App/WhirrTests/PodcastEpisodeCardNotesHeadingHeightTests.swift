import AppModel
import SwiftUI
import Testing
import UIKit

@testable import Whirr

/// The episode card's no-layout-shift rule for the ad-skip status: the "Show notes" heading row is
/// the same height whatever the status says, and whether or not the label is drawn, at every text
/// size.
@MainActor
@Suite("Podcast episode card notes heading height")
struct PodcastEpisodeCardNotesHeadingHeightTests {
  /// The card's content width on a 320-point and a 393-point phone, less its 20-point padding.
  private static let widths: [CGFloat] = [280, 353]

  private static let statuses: [(AdSkipEpisodeStatus, AdSkipPauseReason?)] = [
    (.none, nil),
    (.queued, nil),
    (.checking, nil),
    (.waiting(.conditions), .notCharging),
    (.waiting(.conditions), .lowPowerMode),
    (.waiting(.conditions), .warm),
    (.waiting(.speechModel), nil),
    (ready(1), nil),
    (ready(12), nil),
    (ready(0), nil),
    (.failed, nil),
  ]

  /// A ready status with `count` skips, whose own times do not matter to the row's height.
  private static func ready(_ count: Int) -> AdSkipEpisodeStatus {
    .ready(
      AdSkipBreaks(
        breaks: (0..<count).map {
          AdSkipBreaks.Break(start: Double($0) * 10, end: Double($0) * 10 + 5, endsItem: false)
        }))
  }

  @Test("no status changes the row's height at any text size", arguments: DynamicTypeSize.allCases)
  func statusNeverChangesHeight(size: DynamicTypeSize) {
    for width in Self.widths {
      let baseline = height(content: nil, showsLabel: true, width: width, size: size)
      #expect(baseline > 0)
      #expect(
        baseline == labelHeight(width: width, size: size),
        "the row is not one line of the label at \(size), width \(width)")
      for (status, reason) in Self.statuses {
        let content = AdSkipCardStatusPresentation.content(for: status, pauseReason: reason)
        for showsLabel in [true, false] {
          #expect(
            height(content: content, showsLabel: showsLabel, width: width, size: size) == baseline,
            "\(status), label \(showsLabel), changed the height at \(size), width \(width)")
        }
      }
    }
  }

  private func height(
    content: AdSkipCardStatusPresentation.Content?, showsLabel: Bool, width: CGFloat,
    size: DynamicTypeSize
  ) -> CGFloat {
    let ink = AnyShapeStyle(.secondary)
    return measure(
      PodcastEpisodeCardNotesHeading(showsLabel: showsLabel, secondaryInk: ink) {
        AdSkipCardStatusText(content: content, secondaryInk: ink)
      }, width: width, size: size)
  }

  /// The label alone, with no status, for measuring its height.
  private func labelHeight(width: CGFloat, size: DynamicTypeSize) -> CGFloat {
    measure(Text("Show notes").font(.footnote.weight(.semibold)), width: width, size: size)
  }

  private func measure(_ view: some View, width: CGFloat, size: DynamicTypeSize) -> CGFloat {
    let host = UIHostingController(
      rootView: view.frame(width: width, alignment: .leading).environment(\.dynamicTypeSize, size))
    return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
  }
}
