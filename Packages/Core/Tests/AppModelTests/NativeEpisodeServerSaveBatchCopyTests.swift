import Testing

@testable import AppModel

@Suite("Native episode server-save batch copy")
struct NativeEpisodeServerSaveBatchCopyTests {
  private typealias Copy = NativeEpisodeServerSaveBatchCopy

  @Test("limit and progress copy use the pinned strings")
  func limitAndProgressCopy() {
    #expect(
      Copy.limitExceeded(selected: 63)
        == "Select up to 50 episodes to save at once. 63 are selected.")
    #expect(Copy.progress(completed: 3, total: 12) == "Saving 3 of 12 to Audiobookshelf\u{2026}")
    #expect(Copy.cancelling(completed: 3, total: 12) == "Cancelling after 3 of 12\u{2026}")
    #expect(
      Copy.progressAccessibilityLabel(completed: 3, total: 12)
        == "Saving 3 of 12 episodes to Audiobookshelf")
  }

  @Test("summary covers requested, saved, and terminal outcomes")
  func summaryExamples() {
    #expect(Copy.summary(.init(requested: 5)) == "Requested 5 episodes")
    #expect(Copy.summary(.init(requested: 1)) == "Requested 1 episode")
    #expect(
      Copy.summary(.init(requested: 3, alreadySaved: 2)) == "2 already saved; requested 3")
    #expect(
      Copy.summary(.init(requested: 3, uncertain: 1, notAttempted: 2))
        == "Requested 3; 1 needs review; 2 not attempted")
    #expect(
      Copy.summary(.init(requested: 3, failed: 1, notAttempted: 2))
        == "Requested 3; 1 failed; 2 not attempted")
    #expect(Copy.summary(.init(requested: 2, skipped: 1)) == "Requested 2; 1 skipped")
    #expect(
      Copy.summary(.init(requested: 3, notAttempted: 4, cancelled: true))
        == "Cancelled: requested 3; 4 not attempted")
    #expect(Copy.summary(.init(alreadySaved: 4)) == "4 already saved")
    #expect(Copy.summary(.init()) == "Nothing to save")
  }

  @Test("confirmation and accessibility copy pluralize episodes")
  func confirmationAndAccessibilityPluralize() {
    #expect(Copy.allConfirmed(count: 1) == "Saved on server")
    #expect(Copy.allConfirmed(count: 5) == "Saved 5 episodes on server")
    #expect(
      Copy.progressAccessibilityLabel(completed: 1, total: 1)
        == "Saving 1 of 1 episode to Audiobookshelf")
  }
}
