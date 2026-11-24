import Foundation
import Testing

@testable import Whirr

/// The top scroll-edge treatment (`adr/0010-tab-root-titles-stay-on-the-system-default.md`). The
/// role-to-style mapping is a pure value; which host claims which role is a call-site choice, so
/// those rules are source rules (`Scripts/source-rules/chrome.toml`).
@Suite("Root header chrome")
struct RootHeaderChromeTests {

  // MARK: - The pure part

  @Test("only an untitled root softens its top edge")
  func onlyAnUntitledRootSoftensItsTopEdge() {
    #expect(PrimaryScrollEdgePresentation.style(for: .untitledRoot) == .soft)
    #expect(PrimaryScrollEdgePresentation.style(for: .titled) == .hard)
    #expect(PrimaryScrollEdgePresentation.style(for: .selecting) == .hard)
  }

  /// The rule matters more than the three cases above: anything with chrome to keep legible over
  /// passing artwork is hard. Written over `allCases`, so a role added later cannot default into
  /// softness unnoticed.
  @Test("every role that carries chrome resolves hard")
  func everyRoleCarryingChromeResolvesHard() {
    for role in PrimaryScrollEdgeRole.allCases where role != .untitledRoot {
      #expect(
        PrimaryScrollEdgePresentation.style(for: role) == .hard,
        "\(role) carries chrome over content and must not soften its edge")
    }
  }
}
