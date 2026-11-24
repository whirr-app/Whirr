import AppModel
import DesignSystem
import ReaderCore
import SwiftUI

/// The running header and footer drawn in the page's top and bottom margins, as a printed book
/// has them. They replace the old full-width bars as the reader's constant sense of place.
struct ReaderPageFurniture: Equatable {
  /// The chapter, or the book outside any chapter. Nil on a chapter's opening page, where the
  /// book's own heading already names it.
  let runningHead: String?
  let bookTitle: String
  let footer: String
  /// Where a tap on the footer moves to. Nil when this page has only one readout to give.
  let nextFooterReadout: ReaderFooterReadout?

  /// The chrome answers which book this is; the page between taps answers where in it you are.
  func header(chromeVisible: Bool) -> String? {
    chromeVisible ? bookTitle : runningHead
  }

  /// Fixed-layout pages run edge to edge with no margin to draw in, scrolled text passes through
  /// the margins rather than stopping short of them, and nothing is shown until the restored page
  /// is.
  static func make(
    isReading: Bool,
    isReflowable: Bool,
    isScrollMode: Bool,
    bookTitle: String,
    footerReadout: ReaderFooterReadout,
    progress: ReaderProgressDisplay
  ) -> ReaderPageFurniture? {
    guard isReading, isReflowable, isScrollMode == false else { return nil }
    let available = footerReadouts(progress: progress)
    // The chosen readout, or the one a tap would have reached next when this page cannot give it.
    let shownIndex =
      available.firstIndex { $0.readout.cycleOrder >= footerReadout.cycleOrder } ?? 0
    return ReaderPageFurniture(
      runningHead: progress.isChapterOpening ? nil : progress.chapterTitle ?? bookTitle,
      bookTitle: bookTitle,
      footer: available[shownIndex].text,
      nextFooterReadout: available.count > 1
        ? available[(shownIndex + 1) % available.count].readout : nil)
  }

  /// What this page can say, in tap order. Percent is always known, so this is never empty.
  private static func footerReadouts(
    progress: ReaderProgressDisplay
  ) -> [(readout: ReaderFooterReadout, text: String)] {
    ReaderFooterReadout.allCases.compactMap { readout in
      let text: String? =
        switch readout {
        case .page: progress.pageText
        case .chapterTimeLeft: progress.chapterTimeRemainingText
        case .percent: progress.percentText
        }
      return text.map { (readout, $0) }
    }
  }
}

struct ReaderPageFurnitureView: View {
  /// Page-turn and chrome taps land on Readium's web view underneath; the header is only ink.
  static let isHitTestable = false

  /// The footer's own row takes a tap to change its readout, which then never reaches the page to
  /// turn it or raise the chrome. It takes none while the rail has its row, or with nothing to
  /// change to, so those taps fall through to the page as before.
  static func footerTakesTap(chromeVisible: Bool, canCycle: Bool) -> Bool {
    showsFooter(chromeVisible: chromeVisible) && canCycle
  }

  /// The progress rail sits in the footer row while the chrome shows, so the footer gives way to it
  /// rather than showing through under the glass.
  static func showsFooter(chromeVisible: Bool) -> Bool {
    chromeVisible == false
  }

  /// Room on each side of the header for the toolbar's close button, kept symmetric so the title
  /// stays centred on the page.
  static let headerSideClearance: CGFloat = 64
  /// The distance from the text to the edge of the page's content area.
  static let gapToPage: CGFloat = 14
  /// How far the footer sits above the bottom edge of the screen: clear of the home indicator
  /// rather than hugging the last line of text.
  static let footerEdgeClearance: CGFloat = 28
  /// How far the footer's tap target reaches past its text: enough to hit without aiming, while
  /// leaving the rest of the bottom margin to turn pages.
  static let footerTapOutset = CGSize(width: 16, height: 10)

  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let furniture: ReaderPageFurniture
  let chromeVisible: Bool
  let palette: ReaderThemePalette
  let onSelectFooterReadout: (ReaderFooterReadout) -> Void

  var body: some View {
    // Anchored to the renderer's fixed insets rather than the safe area, which the system bars
    // change as the chrome comes and goes: the furniture must hold still exactly as the page does.
    let insets =
      ReadiumEPUBRenderer.contentInsets[verticalSizeClass == .compact ? .compact : .regular]
      ?? (top: 0, bottom: 0)
    let header = furniture.header(chromeVisible: chromeVisible)
    VStack(spacing: 0) {
      Text(header ?? "")
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, Self.headerSideClearance)
        .frame(maxWidth: .infinity)
        .frame(height: insets.top - Self.gapToPage, alignment: .bottom)
        .contentTransition(.opacity)
        .animation(reduceMotion ? nil : .smooth, value: chromeVisible)
        .accessibilityHidden(header == nil)
        .allowsHitTesting(Self.isHitTestable)

      Spacer(minLength: 0)

      Text(furniture.footer)
        .lineLimit(1)
        .monospacedDigit()
        // The outset is taken back out of the edge clearance, so the text itself does not move.
        .padding(.horizontal, Self.footerTapOutset.width)
        .padding(.vertical, Self.footerTapOutset.height)
        .contentShape(Rectangle())
        .onTapGesture {
          if let next = furniture.nextFooterReadout { onSelectFooterReadout(next) }
        }
        .allowsHitTesting(
          Self.footerTakesTap(
            chromeVisible: chromeVisible, canCycle: furniture.nextFooterReadout != nil)
        )
        .padding(.bottom, Self.footerEdgeClearance - Self.footerTapOutset.height)
        .frame(maxWidth: .infinity)
        .frame(height: insets.bottom - Self.gapToPage, alignment: .bottom)
        .opacity(Self.showsFooter(chromeVisible: chromeVisible) ? 1 : 0)
        .animation(reduceMotion ? nil : .smooth, value: chromeVisible)
        // The progress control already speaks the page and percentage, so the readout and its
        // tap are a sighted convenience rather than another stop on every page.
        .accessibilityHidden(true)
    }
    .font(WhirrTypeToken.caption.font)
    .foregroundStyle(palette.secondaryForegroundColor)
    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    .ignoresSafeArea(edges: .all)
  }
}

extension ReaderFooterReadout {
  fileprivate var cycleOrder: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
