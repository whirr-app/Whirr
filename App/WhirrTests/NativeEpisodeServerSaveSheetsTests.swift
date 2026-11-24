import AppModel
import Testing

@testable import Whirr

/// The removal confirmation is identified by its episode. The sheets' composition rules (no save
/// dialog, a centred removal alert, opaque ids only) are source rules in
/// `Scripts/source-rules/podcasts-sheets.toml`.
@Suite struct NativeEpisodeServerSaveSheetsTests {
  @Test func removalConfirmationIsIdentifiedByItsEpisode() {
    let confirmation = NativeEpisodeServerSaveRemovalConfirmation(episodeID: "guid:9")
    #expect(confirmation.id == "guid:9")
    #expect(confirmation.episodeID == "guid:9")
  }
}
