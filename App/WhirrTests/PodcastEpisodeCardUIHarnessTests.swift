#if DEBUG
  import AppModel
  import Testing

  @testable import Whirr

  @Suite("Podcast episode-card UI harness")
  struct PodcastEpisodeCardUIHarnessTests {
    private var displayedNotes: String {
      PodcastEpisodeCardPresentation(context: HarnessPodcastFixtures.longNotesEpisodeContext).notes
        ?? ""
    }

    @Test("long-notes fixture ends with its sentinel")
    func longNotesFixtureEndsWithSentinel() {
      #expect(displayedNotes.hasSuffix(HarnessPodcastFixtures.longNotesSentinel))
    }

    @Test("long-notes fixture remains long enough for the reproduction")
    func longNotesFixtureExceedsEightThousandCharacters() {
      #expect(displayedNotes.count > 8_000)
    }

    @Test("episode-card screen routing keeps the player fallback")
    func episodeCardScreenRouting() {
      #expect(UIHarness.screen(for: "episode-card") == .episodeCard)
      #expect(UIHarness.screen(for: "not-a-screen") == .player)
    }
  }
#endif
