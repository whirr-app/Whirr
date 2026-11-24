import Foundation
import ReaderCore

@MainActor
extension ReaderModel {
  func loadPreferences() async throws -> ReaderPreferences {
    guard let json = try await preferencesStore.fetchPreferencesJSON() else {
      return ReaderPreferences()
    }
    return (try? JSONDecoder().decode(ReaderPreferences.self, from: Data(json.utf8)))
      ?? ReaderPreferences()
  }

  func preferencesWithCapability(
    _ value: ReaderPreferences,
    reflowable: Bool,
    preservingReflowControls: Bool = false
  ) -> ReaderPreferences {
    let source = preservingReflowControls && reflowable == false ? preferences : value
    return ReaderPreferences(
      theme: value.theme,
      fontFamily: source.fontFamily,
      fontSizeStep: source.fontSizeStep,
      lineSpacingStep: source.lineSpacingStep,
      marginsStep: source.marginsStep,
      readingMode: value.readingMode,
      // Alignment is a reflow control: it follows the same source as spacing and margins.
      textAlignment: source.textAlignment,
      wordSpacingStep: source.wordSpacingStep,
      letterSpacingStep: source.letterSpacingStep,
      paragraphSpacingStep: source.paragraphSpacingStep,
      hyphenation: source.hyphenation,
      publisherStyles: source.publisherStyles,
      footerReadout: value.footerReadout,
      reflowable: reflowable)
  }

  static func encode(_ preferences: ReaderPreferences) throws -> String {
    String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)
  }
}
