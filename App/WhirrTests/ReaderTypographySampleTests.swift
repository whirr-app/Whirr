import ReaderCore
import Testing
import UIKit

@testable import Whirr

@Suite("Reader typography sample")
@MainActor
struct ReaderTypographySampleTests {
  private let text = "One two.\nThree four."

  private func attributes(
    _ preferences: ReaderPreferences, at index: Int = 0
  ) -> [NSAttributedString.Key: Any] {
    ReaderTypographySample.attributedSample(text, preferences: preferences, textColor: .black)
      .attributes(at: index, effectiveRange: nil)
  }

  private func paragraphStyle(_ preferences: ReaderPreferences) -> NSParagraphStyle? {
    attributes(preferences)[.paragraphStyle] as? NSParagraphStyle
  }

  @Test("the sample's size follows the typography font scale", arguments: [0, 4, 8])
  func fontSizeFollowsTheScale(step: Int) {
    let preferences = ReaderPreferences(fontSizeStep: step)
    let font = attributes(preferences)[.font] as? UIFont
    let expected =
      ReaderTypographySample.baseSize * ReaderTypography(preferences: preferences).fontScale
    #expect(abs((font?.pointSize ?? 0) - expected) < 0.001)
  }

  @Test("user spacing matches ReaderTypography at each step", arguments: 1...4)
  func userSpacingMatchesTheTypography(step: Int) {
    let preferences = ReaderPreferences(
      lineSpacingStep: step, textAlignment: .justify, wordSpacingStep: step,
      letterSpacingStep: step, paragraphSpacingStep: step, hyphenation: true,
      publisherStyles: false)
    let typography = ReaderTypography(preferences: preferences)
    let size = ReaderTypographySample.baseSize
    let style = paragraphStyle(preferences)

    #expect(abs((style?.minimumLineHeight ?? 0) - size * typography.lineHeight) < 0.001)
    #expect(style?.maximumLineHeight == style?.minimumLineHeight)
    #expect(abs((style?.paragraphSpacing ?? 0) - size * (typography.paragraphSpacing ?? 0)) < 0.001)
    #expect(style?.alignment == .justified)
    #expect(style?.hyphenationFactor == 1)

    let letterKern = attributes(preferences, at: 0)[.kern] as? CGFloat
    #expect(abs((letterKern ?? 0) - size * (typography.letterSpacing ?? 0)) < 0.001)
    // Word spacing is kerning on the space character, on top of the letter spacing.
    let spaceKern = attributes(preferences, at: 3)[.kern] as? CGFloat
    let expectedSpace = size * ((typography.letterSpacing ?? 0) + (typography.wordSpacing ?? 0))
    #expect(abs((spaceKern ?? 0) - expectedSpace) < 0.001)
  }

  @Test("with publisher styles on, the sample leaves spacing to the book as the page does")
  func publisherStylesLeaveSpacingAlone() {
    let preferences = ReaderPreferences(
      lineSpacingStep: 4, textAlignment: .justify, wordSpacingStep: 4, letterSpacingStep: 4,
      paragraphSpacingStep: 4, hyphenation: true, publisherStyles: true)
    let style = paragraphStyle(preferences)

    #expect(style?.minimumLineHeight == 0)
    #expect(style?.alignment == .natural)
    #expect(style?.hyphenationFactor == 0)
    #expect((attributes(preferences)[.kern] as? CGFloat ?? 0) == 0)
  }

  @Test("the passage is never taller than the sample offers it")
  func passageHeightIsCappedAtTheOfferedHeight() {
    // An overflowing passage was clipped from view but still lay over the controls below the
    // pinned sample and took their touches.
    #expect(ReaderTypographySample.textHeight(fitted: 900, offered: 120) == 120)
    #expect(ReaderTypographySample.textHeight(fitted: 80, offered: 120) == 80)
    #expect(ReaderTypographySample.textHeight(fitted: 900, offered: nil) == 900)
  }

  @Test("the book's sample is the first two substantial paragraphs, bounded")
  func sampleParagraphsAreSelectedFromTheBook() {
    let long = String(repeating: "word ", count: 30)
    #expect(
      ReadiumEPUBRenderer.sampleParagraphs(from: ["Chapter 1", long, "Short.", long, long])
        == "\(long.trimmingCharacters(in: .whitespaces))\n\(long.trimmingCharacters(in: .whitespaces))"
    )
    #expect(ReadiumEPUBRenderer.sampleParagraphs(from: ["Chapter 1", "Short."]) == nil)

    let huge = String(repeating: "word ", count: 400)
    let bounded = ReadiumEPUBRenderer.sampleParagraphs(from: [huge]) ?? ""
    #expect(bounded.count <= ReadiumEPUBRenderer.sampleCharacterLimit + 1)
    #expect(bounded.hasSuffix("…"))
  }
}
