import DesignSystem
import ReaderCore
import SwiftUI
import UIKit

/// The customise page's live sample: a large "Aa" and a passage set in the reader's current
/// typography, after Books. TextKit draws it, from the same `ReaderTypography` mapping the page is
/// rendered from, so every control's effect shows here as it is made.
struct ReaderTypographySample: View {
  /// The sample's body size before the font scale, standing in for the publication's own.
  static let baseSize: CGFloat = 17
  /// The sample is pinned above the controls, so its height is fixed: a sample that grew with the
  /// text size would move the slider being dragged out from under the finger.
  static let height: CGFloat = 200
  static let fadeHeight: CGFloat = 32

  let text: String
  let preferences: ReaderPreferences
  let palette: ReaderThemePalette

  var body: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.small) {
      Text("Aa")
        .font(.system(size: 44, weight: .regular, design: .serif))
        .foregroundStyle(palette.foregroundColor)
        .accessibilityHidden(true)
      SampleTextView(
        attributedText: Self.attributedSample(
          text, preferences: preferences, textColor: UIColor(palette.foregroundColor))
      )
      // Wider margins narrow the column on the page; the sample narrows with it.
      .padding(
        .horizontal,
        WhirrSpacing.small * (ReaderTypography(preferences: preferences).pageMargins - 1) * 2)
    }
    .padding(.vertical, WhirrSpacing.small)
    .frame(height: Self.height, alignment: .top)
    .clipped()
    // Text past the fixed height fades out rather than stopping at a hard edge mid-line.
    .mask {
      VStack(spacing: 0) {
        Rectangle()
        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
          .frame(height: Self.fadeHeight)
      }
    }
    .animation(.smooth, value: preferences)
    .accessibilityElement(children: .combine)
  }

  /// The passage's height: its natural height, capped at what the sample offers. `clipped()` hides
  /// overflow but does not bound hit-testing, so an overflowing passage lay invisibly over the rows
  /// beneath the pinned sample and took their touches.
  static func textHeight(fitted: CGFloat, offered: CGFloat?) -> CGFloat {
    min(fitted, offered ?? fitted)
  }

  /// The passage as TextKit attributes. ReadiumCSS applies the reader's own line height, spacing,
  /// alignment, and hyphenation only while publisher styles are off, so the sample does the same.
  static func attributedSample(
    _ text: String, preferences: ReaderPreferences, textColor: UIColor
  ) -> NSAttributedString {
    let typography = ReaderTypography(preferences: preferences)
    let size = baseSize * typography.fontScale
    let usesReaderTypography = preferences.publisherStyles == false
    let paragraph = NSMutableParagraphStyle()
    var letterSpacing: CGFloat = 0
    var wordSpacing: CGFloat = 0

    if usesReaderTypography {
      // CSS line-height is a multiple of the font size, not of the font's natural line height.
      paragraph.minimumLineHeight = size * typography.lineHeight
      paragraph.maximumLineHeight = size * typography.lineHeight
      paragraph.paragraphSpacing = size * (typography.paragraphSpacing ?? 0)
      paragraph.alignment =
        switch preferences.textAlignment {
        case .publisherDefault: .natural
        case .left: .left
        case .justify: .justified
        }
      paragraph.hyphenationFactor = preferences.hyphenation ? 1 : 0
      letterSpacing = size * (typography.letterSpacing ?? 0)
      wordSpacing = size * (typography.wordSpacing ?? 0)
    } else {
      paragraph.paragraphSpacing = size * 0.5
    }

    let result = NSMutableAttributedString(
      string: text,
      attributes: [
        .font: font(for: preferences.fontFamily, size: size),
        .foregroundColor: textColor,
        .paragraphStyle: paragraph,
        .kern: letterSpacing,
      ])
    if wordSpacing != 0 {
      let string = text as NSString
      var location = 0
      while location < string.length {
        let range = string.range(
          of: " ", range: NSRange(location: location, length: string.length - location))
        guard range.location != NSNotFound else { break }
        result.addAttribute(.kern, value: letterSpacing + wordSpacing, range: range)
        location = range.location + range.length
      }
    }
    return result
  }

  /// The nearest UIKit face to each Readium font choice. OpenDyslexic ships inside Readium's web
  /// assets rather than as an app font, so the sample falls back to the system face for it.
  private static func font(for family: ReaderCore.ReaderFontFamily, size: CGFloat) -> UIFont {
    let system = UIFont.systemFont(ofSize: size)
    switch family {
    case .publisherDefault, .serif:
      return system.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) }
        ?? system
    case .sansSerif:
      return system
    case .monospaced:
      return .monospacedSystemFont(ofSize: size, weight: .regular)
    case .openDyslexic:
      return UIFont(name: "OpenDyslexic", size: size) ?? system
    }
  }
}

/// A non-editable, non-scrolling TextKit view sized to its text at the proposed width, and no
/// taller than the height offered.
private struct SampleTextView: UIViewRepresentable {
  let attributedText: NSAttributedString

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView()
    view.isEditable = false
    view.isSelectable = false
    view.isScrollEnabled = false
    // The sample only shows text; it never takes a touch meant for the controls around it.
    view.isUserInteractionEnabled = false
    view.backgroundColor = .clear
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    view.attributedText = attributedText
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
    let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
    let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    return CGSize(
      width: width,
      height: ReaderTypographySample.textHeight(fitted: fitted.height, offered: proposal.height))
  }
}
