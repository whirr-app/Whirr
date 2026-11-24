import AppModel
import DesignSystem
import SwiftUI

/// The reading position and chapter estimate written above the progress rail while the chrome
/// shows, where the page's running footer gives way to the bar. While a finger is on the rail it
/// names the page a release would land on instead, with that page's chapter in place of the
/// estimate: the chapter is what a reader aims a scrub at, and the estimate belongs to a page they
/// have not reached.
struct ReaderProgressReadout: Equatable {
  struct Line: Equatable {
    let position: String
    let trailing: String?
  }

  /// Widest first. The bar draws the first line that fits the rail, so a narrow rail shortens the
  /// page before it drops the trailing text, and drops that before it truncates anything.
  let lines: [Line]
  var isScrubbing = false

  static func make(progress: ReaderProgressDisplay) -> ReaderProgressReadout {
    make(progress: progress, trailing: progress.chapterTimeRemainingText, isScrubbing: false)
  }

  static func make(scrubbing preview: ReaderProgressDisplay) -> ReaderProgressReadout {
    make(progress: preview, trailing: preview.chapterTitle, isScrubbing: true)
  }

  private static func make(
    progress: ReaderProgressDisplay, trailing: String?, isScrubbing: Bool
  ) -> ReaderProgressReadout {
    let full = ReaderCopy.readoutPosition(
      percentText: progress.percentText, page: progress.page, pageCount: progress.pageCount,
      isCompact: false)
    let compact = ReaderCopy.readoutPosition(
      percentText: progress.percentText, page: progress.page, pageCount: progress.pageCount,
      isCompact: true)
    let positions = full == compact ? [full] : [full, compact]
    var lines: [Line] = []
    if let trailing {
      lines += positions.map { Line(position: $0, trailing: trailing) }
    }
    lines += positions.map { Line(position: $0, trailing: nil) }
    return ReaderProgressReadout(lines: lines, isScrubbing: isScrubbing)
  }
}

struct ReaderProgressReadoutView: View {
  let readout: ReaderProgressReadout
  let palette: ReaderThemePalette

  var body: some View {
    ViewThatFits(in: .horizontal) {
      ForEach(readout.lines.indices, id: \.self) { index in
        let line = readout.lines[index]
        HStack(spacing: 8) {
          Text(line.position)
          if let trailing = line.trailing {
            Spacer(minLength: 0)
            Text(trailing)
          }
        }
        .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .font(WhirrTypeToken.caption2.font)
    .monospacedDigit()
    .foregroundStyle(
      readout.isScrubbing ? palette.foregroundColor : palette.secondaryForegroundColor
    )
    .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    // The rail's own accessibility value already speaks the position.
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }
}

/// Stacks the readout above the rail's track and centres the pair, not the track alone, in the
/// rail's touch target, so the text and the hairline sit as one element inside the glass capsule.
struct ReaderRailReadoutPlacement: ViewModifier {
  let readout: ReaderProgressReadout
  let palette: ReaderThemePalette

  @ScaledMetric(relativeTo: .caption2) private var readoutHeight: CGFloat = 13
  private let gap: CGFloat = 6

  func body(content: Content) -> some View {
    content
      // The track sits at the target's centre; the readout rests just above it. Moving both down
      // by half the readout's extent puts the pair's centre on the target's centre.
      .overlay(alignment: .center) {
        ReaderProgressReadoutView(readout: readout, palette: palette)
          .alignmentGuide(VerticalAlignment.center) { $0[.bottom] + gap }
      }
      .offset(y: (readoutHeight + gap) / 2)
  }
}
