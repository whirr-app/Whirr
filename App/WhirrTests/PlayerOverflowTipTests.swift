import Testing

@testable import Whirr

@Suite("Player overflow feature tip")
struct PlayerOverflowTipTests {
  @Test func aBookOfferingLookBackCarriesItsTip() {
    #expect(PlayerOverflowTip.choice(includesLookBack: true, includesTranscript: false) == .lookBack)
  }

  @Test func anEpisodeOfferingTranscriptCarriesItsTip() {
    #expect(
      PlayerOverflowTip.choice(includesLookBack: false, includesTranscript: true) == .transcript)
  }

  @Test func aMenuWithNeitherEntryCarriesNoTip() {
    #expect(PlayerOverflowTip.choice(includesLookBack: false, includesTranscript: false) == nil)
  }
}
