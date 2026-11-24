import Testing

@testable import AppModel

@Suite struct AddFeedSheetPresentationTests {
  @Test func copyIsSourceNeutralAndFailuresAreDistinct() {
    #expect(AddFeedSheetPresentation.addressFieldPrompt.contains("link"))
    #expect(AddFeedSheetPresentation.addressFieldPrompt.contains("name"))
    // The idle state is where the field's two jobs are explained, so it names both.
    #expect(AddFeedSheetPresentation.idleMessage.contains("name"))
    #expect(AddFeedSheetPresentation.idleMessage.contains("link"))
    let messages = [
      AddFeedError.invalidAddress, .unreachable, .notAFeed, .alreadyFollowing, .couldNotFollow,
    ].map(AddFeedSheetPresentation.message)
    #expect(Set(messages).count == messages.count)
    #expect(messages.allSatisfy { $0.contains("RSS") == false })
  }

  @Test func directoryFollowFailuresNeverTalkAboutALinkTheUserDidNotPaste() {
    let failures: [AddFeedError] = [.invalidAddress, .unreachable, .notAFeed, .couldNotFollow]
    let messages = failures.map(AddFeedSheetPresentation.directoryFollowMessage)
    #expect(messages.allSatisfy { $0.contains("link") == false })
    #expect(messages.allSatisfy { $0.lowercased().hasSuffix("try again.") })
    #expect(
      AddFeedSheetPresentation.directoryFollowMessage(for: .notAFeed)
        != AddFeedSheetPresentation.directoryFollowMessage(for: .unreachable))
  }

  @Test func directorySearchFailureDescribesTheSearchNotALinkOrTheConnection() {
    let message = AddFeedSheetPresentation.directorySearchMessage(for: .unreachable)
    #expect(message.contains("link") == false)
    #expect(message.contains("connection") == false)
    #expect(message.contains("search"))
    #expect(message.contains("feed address"))
  }

  @Test func followControlLabelsNameTheShowForVoiceOver() {
    #expect(AddFeedSheetPresentation.followAccessibilityLabel(title: "Show") == "Follow Show")
    #expect(
      AddFeedSheetPresentation.followingAccessibilityLabel(title: "Show") == "Following Show")
  }

  @Test func episodeCountPluralizes() {
    #expect(AddFeedSheetPresentation.episodeCountText(1) == "1 episode")
    #expect(AddFeedSheetPresentation.episodeCountText(2) == "2 episodes")
  }

  @Test func embeddedCredentialNoticeNamesBothSafetyActions() {
    let notice = AddFeedSheetPresentation.extractedCredentialNotice
    #expect(notice.contains("removed from the link"))
    #expect(notice.contains("Keychain"))
  }
}
