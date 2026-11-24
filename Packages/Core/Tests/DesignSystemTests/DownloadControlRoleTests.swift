import Testing

@testable import DesignSystem

/// The item-detail toolbar bubble inherits the screen's `.tint(accent)`, the cover's extracted
/// colour. On a `trash` glyph that would read as an unexplained coloured icon rather than a
/// delete.
///
/// Roles say what each state means, and only `warning` turns that meaning into a colour.
@Suite("DownloadControlRole")
struct DownloadControlRoleTests {

  @Test("a completed download's control is destructive, not decorative")
  func completedControlIsDestructive() {
    #expect(DownloadControlRole.role(for: .completed) == .destructive)
  }

  /// Mid-removal is already destructive in intent, and it must not swap to a cover accent while
  /// the deletion runs.
  @Test("the mid-removal state stays destructive")
  func deletingStaysDestructive() {
    #expect(DownloadControlRole.role(for: .deleting) == .destructive)
  }

  @Test("a failed or interrupted transfer warns rather than beckons")
  func failureStatesWarn() {
    #expect(DownloadControlRole.role(for: .failed) == .warning)
    #expect(DownloadControlRole.role(for: .interrupted) == .warning)
    #expect(DownloadControlRole.role(for: .pausedAuth) == .warning)
  }

  @Test("inviting and in-flight states are ordinary")
  func invitingStatesAreOrdinary() {
    #expect(DownloadControlRole.role(for: .notDownloaded) == .ordinary)
    #expect(DownloadControlRole.role(for: .downloading) == .ordinary)
    #expect(DownloadControlRole.role(for: .queued) == .ordinary)
    #expect(DownloadControlRole.role(for: .waitingForWiFi) == .ordinary)
    #expect(DownloadControlRole.role(for: .paused) == .ordinary)
  }

  /// The tint table is narrower than the role table: a red trash does not sit well with an
  /// artwork-extracted palette, and the confirmation dialog the tap raises already carries the
  /// destructive colour. Orange is the only tint, so colour in this control means one thing.
  @Test("only the warning states are coloured")
  func onlyWarningStatesAreColoured() {
    for kind in DownloadControlKind.allCases {
      let isWarning = DownloadControlRole.role(for: kind) == .warning
      #expect(DownloadControlRole.tint(for: kind) == (isWarning ? .orange : .primary))
    }

    // Pinned so red cannot creep onto the destructive states.
    #expect(DownloadControlRole.tint(for: .completed) == .primary)
    #expect(DownloadControlRole.tint(for: .deleting) == .primary)
    #expect(DownloadControlRole.tint(for: .notDownloaded) == .primary)
    #expect(DownloadControlRole.tint(for: .pausedAuth) == .orange)
  }

  @Test("every control kind has a role")
  func everyKindHasARole() {
    for kind in DownloadControlKind.allCases {
      _ = DownloadControlRole.role(for: kind)
    }
  }
}
