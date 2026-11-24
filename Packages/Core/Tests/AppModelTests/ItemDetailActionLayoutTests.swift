import Testing

@testable import AppModel

@Suite("ItemDetailActionLayout")
struct ItemDetailActionLayoutTests {
  @Test("orders Chapters, Play, and Read for a mixed title at standard sizes")
  func mixedTitleUsesHorizontalThreeControlLayout() {
    #expect(
      ItemDetailActionLayout.resolve(
        capability: .audioAndEbook,
        hasVisibleReadAction: true,
        isAccessibilitySize: false)
        == .horizontal([.chapters, .play, .read]))
  }

  @Test("stacks every mixed-title control with its label at accessibility sizes")
  func mixedTitleUsesStackedThreeControlLayoutAtAccessibilitySizes() {
    #expect(
      ItemDetailActionLayout.resolve(
        capability: .audioAndEbook,
        hasVisibleReadAction: true,
        isAccessibilitySize: true)
        == .stacked([.play, .chapters, .read]))
  }

  @Test("keeps the Chapters opener when a mixed title's Read action is unresolved")
  func mixedTitleWithoutReadActionStillHasChaptersAndPlay() {
    #expect(
      ItemDetailActionLayout.resolve(
        capability: .audioAndEbook,
        hasVisibleReadAction: false,
        isAccessibilitySize: false)
        == .horizontal([.chapters, .play]))
    #expect(
      ItemDetailActionLayout.resolve(
        capability: .audioAndEbook,
        hasVisibleReadAction: false,
        isAccessibilitySize: true)
        == .stacked([.play, .chapters]))
  }

  @Test("gives an ebook Chapters even when Read has not resolved")
  func ebookWithoutReadActionStillHasChapters() {
    #expect(
      ItemDetailActionLayout.resolve(
        capability: .ebook,
        hasVisibleReadAction: false,
        isAccessibilitySize: false)
        == .horizontal([.chapters]))
  }

  @Test("puts an ebook's Chapters before Read")
  func ebookUsesHorizontalChaptersAndReadLayout() {
    #expect(
      ItemDetailActionLayout.resolve(
        capability: .ebook,
        hasVisibleReadAction: true,
        isAccessibilitySize: false)
        == .horizontal([.chapters, .read]))
  }

  @Test("keeps audio-only titles to Chapters and Play")
  func audioOnlyUsesHorizontalTwoControlLayout() {
    #expect(
      ItemDetailActionLayout.resolve(
        capability: .audio,
        hasVisibleReadAction: false,
        isAccessibilitySize: false)
        == .horizontal([.chapters, .play]))
  }
}
