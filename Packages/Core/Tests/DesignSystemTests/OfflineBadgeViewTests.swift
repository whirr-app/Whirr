import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Offline badge view")
@MainActor
struct OfflineBadgeViewTests {

  @Test(
    "browse row badges use icon-only glyphs while retaining their full accessibility labels",
    arguments: [
      ("Finished", "checkmark.circle.fill"),
      ("Downloaded", "arrow.down.circle.fill"),
    ]
  )
  func rowBadgeStyleIsIconOnlyWithFullAccessibilityLabel(label: String, systemImage: String) {
    let badge = OfflineBadgeView(label: label, systemImage: systemImage, style: .row)

    #expect(badge.style == .row)
    #expect(badge.isIconOnly)
    #expect(badge.showsLabel == false)
    #expect(badge.accessibilityLabel == label)
    #expect(badge.systemImage == systemImage)
  }

  @Test("item-detail badges remain labelled")
  func itemDetailBadgeStyleRemainsLabelled() {
    let badge = OfflineBadgeView(label: "Downloaded", systemImage: "arrow.down.circle.fill", style: .detail)

    #expect(badge.style == .detail)
    #expect(badge.isIconOnly == false)
    #expect(badge.showsLabel)
    #expect(badge.accessibilityLabel == "Downloaded")
  }
}
