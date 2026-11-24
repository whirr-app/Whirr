import Testing

@testable import AdSkip

@Suite struct ShowLanguagePolicyTests {
  @Test(arguments: [nil, "en", "en-GB", "EN-us", "en_US", " en ", ""])
  func analysesEnglishAndUntaggedShows(tag: String?) {
    #expect(ShowLanguagePolicy.isAnalysable(languageTag: tag))
  }

  @Test(arguments: ["fr", "de-DE", "eng", "english", "enx", "en-", "es-en"])
  func skipsEveryOtherTag(tag: String) {
    #expect(ShowLanguagePolicy.isAnalysable(languageTag: tag) == false)
  }
}
