import AppModel
import DesignSystem
import Persistence
import Testing

@testable import Whirr

/// `ItemDetailDownloadBubblePresentation` derives the toolbar download bubble's tap behaviour from
/// `DownloadControlKind` alone, as a pure derivation tested without rendering.
struct ItemDetailDownloadBubblePresentationTests {
  // Toolbar order is load-bearing: the bookmark and bubble hide until resolved and a trailing
  // group grows leftward, so both must precede the ellipsis. (What the action row may draw is
  // fenced by `Scripts/source-rules/item.toml`.)
  @Test("the trailing toolbar orders the bookmark, the download bubble, then the overflow")
  func secondaryActionsShareTheToolbarGroup() throws {
    let source = try ViewSourceScan.source(declaring: "ItemDetailView")
    let itemDetailText = try ViewSourceScan.executableText(of: source)

    let bookmark = try #require(itemDetailText.range(of: "savedToolbarButton(actions: actions)"))
    let bubble = try #require(itemDetailText.range(of: "ItemDetailDownloadBubbleView("))
    let overflow = try #require(itemDetailText.range(of: "overflowMenu(item: item"))
    #expect(bookmark.lowerBound < bubble.lowerBound)
    #expect(bubble.lowerBound < overflow.lowerBound)
  }

  @Test("an ebook keeps its Chapters opener while its reader affordance is unresolved")
  func ebookKeepsChaptersWhenReaderActionIsUnavailable() {
    #expect(
      ItemDetailActionLayout.resolve(
        capability: .ebook,
        hasVisibleReadAction: false,
        isAccessibilitySize: false)
        == .horizontal([.chapters]))
  }

  /// Every glyph the bubble draws is unenclosed. An enclosed symbol spends its bounding box on the
  /// ring and draws the mark small, so `arrow.down.circle` sat a size below the bare bookmark,
  /// trash and ellipsis beside it, and became a bare `arrow.down` once a transfer started.
  @Test("no toolbar bubble glyph is enclosed")
  func bubbleGlyphsAreUnenclosed() {
    for kind in DownloadControlKind.allCases {
      guard let systemImage = ItemDetailDownloadBubblePresentation.systemImage(for: kind) else {
        continue
      }
      #expect(
        ItemDetailDownloadBubblePresentation.isEnclosed(systemImage) == false,
        "\(kind) draws \(systemImage), which is enclosed")
    }

    #expect(ItemDetailDownloadBubblePresentation.systemImage(for: .notDownloaded) == "arrow.down")
    #expect(
      ItemDetailDownloadBubblePresentation.systemImage(for: .notDownloaded)
        == ItemDetailDownloadBubblePresentation.systemImage(for: .downloading),
      "starting a download must not change the glyph's size")

    // The table still recognises an enclosed form, so the check above cannot pass by failing to
    // detect one.
    #expect(ItemDetailDownloadBubblePresentation.isEnclosed("arrow.down.circle"))
    #expect(ItemDetailDownloadBubblePresentation.isEnclosed("lock.circle"))
  }

  /// Only the ring branch is sized: `DownloadProgressRing` strokes a circle, which has no intrinsic
  /// size. The plain glyph must not inherit that box or its `.imageScale(.medium)`, or it draws a
  /// step smaller than its neighbours in the toolbar group.
  @Test("only the progress ring is given a fixed size")
  func onlyTheProgressRingIsSized() throws {
    let source = try ViewSourceScan.source(declaring: "ItemDetailDownloadBubbleView")
    let text = try ViewSourceScan.executableText(of: source)

    let ring = try #require(text.range(of: "DownloadProgressRing("))
    let sized = try #require(text.range(of: ".frame(width: 22, height: 22)"))
    #expect(ring.lowerBound < sized.lowerBound)
  }

  @Test("the finished badge drops scale and spring motion under Reduce Motion")
  func finishedBadgeMotionRespectsReduceMotion() {
    #expect(ItemDetailViewPresentation.finishedBadgeMotion(reduceMotion: false) == .scaleAndFade)
    #expect(ItemDetailViewPresentation.finishedBadgeMotion(reduceMotion: true) == .fadeOnly)
  }

  @Test("download symbols replace immediately under Reduce Motion")
  func downloadSymbolMotionRespectsReduceMotion() {
    #expect(ItemDetailDownloadBubblePresentation.symbolMotion(reduceMotion: false) == .replace)
    #expect(ItemDetailDownloadBubblePresentation.symbolMotion(reduceMotion: true) == .immediate)
  }

  @Test("not-yet-downloaded taps directly to start a download, with nothing to remove yet")
  func notDownloadedIsDirectWithNoRemove() {
    #expect(ItemDetailDownloadBubblePresentation.tapBehavior(for: .notDownloaded) == .direct)
    #expect(ItemDetailDownloadBubblePresentation.exposesSecondaryRemove(for: .notDownloaded) == false)
  }

  @Test("paused-family states tap directly to resume, and expose a reachable remove action")
  func pausedFamilyIsDirectWithRemove() {
    let pausedFamily: [DownloadControlKind] = [.paused, .pausedAuth, .interrupted, .failed]
    for kind in pausedFamily {
      #expect(ItemDetailDownloadBubblePresentation.tapBehavior(for: kind) == .direct)
      #expect(ItemDetailDownloadBubblePresentation.exposesSecondaryRemove(for: kind) == true)
    }
  }

  @Test("in-flight download states open a menu of actions")
  func inFlightStatesOpenMenu() {
    let inFlight: [DownloadControlKind] = [.waitingForWiFi, .queued, .downloading]
    for kind in inFlight {
      #expect(ItemDetailDownloadBubblePresentation.tapBehavior(for: kind) == .menu)
      #expect(ItemDetailDownloadBubblePresentation.exposesSecondaryRemove(for: kind) == false)
    }
  }

  @Test("a completed download becomes a trash control that offers deletion")
  func completedOffersDeletion() {
    #expect(ItemDetailDownloadBubblePresentation.tapBehavior(for: .completed) == .confirm)
    #expect(ItemDetailDownloadBubblePresentation.exposesSecondaryRemove(for: .completed) == false)
    #expect(ItemDetailDownloadBubblePresentation.systemImage(for: .completed) == "trash")
    #expect(ItemDetailDownloadBubblePresentation.primaryActionLabel(for: .completed) == "Remove Download")
  }

  @Test("an active download shows its download glyph inside the progress ring")
  func activeDownloadUsesTheDownloadGlyphWithProgress() {
    #expect(ItemDetailDownloadBubblePresentation.primaryActionLabel(for: .downloading) == "Pause")
    #expect(ItemDetailDownloadBubblePresentation.systemImage(for: .downloading) == "arrow.down")
    #expect(
      ItemDetailDownloadBubblePresentation.menuAccessibilityHint(for: .downloading)
        == "Shows options to pause or remove this download.")

    for kind in DownloadControlKind.allCases where kind != .downloading {
      #expect(ItemDetailDownloadBubblePresentation.primaryActionLabel(for: kind) != "Pause")
    }
  }

  @Test("a mid-removal download disables the bubble entirely")
  func deletingDisables() {
    #expect(ItemDetailDownloadBubblePresentation.tapBehavior(for: .deleting) == .disabled)
    #expect(ItemDetailDownloadBubblePresentation.exposesSecondaryRemove(for: .deleting) == false)
  }

  @Test("every kind maps to exactly one tap behavior")
  func everyKindHasABehavior() {
    let behaviors = DownloadControlKind.allCases.map(ItemDetailDownloadBubblePresentation.tapBehavior(for:))
    #expect(behaviors.count == DownloadControlKind.allCases.count)
  }

  @Test("a mixed item that is not downloaded offers audiobook, ebook, then both")
  func mixedNotDownloadedOffersAllFormatsInOrder() {
    let options = ItemDetailDownloadBubblePresentation.downloadOptions(
      for: .notDownloaded,
      formatStatus: ItemFormatDownloadStatus(),
      category: .audiobook,
      hasReadableEbook: true)

    #expect(options.map(\.label) == ["Download Audiobook", "Download eBook", "Download Both"])
    #expect(
      ItemDetailDownloadBubblePresentation.tapBehavior(
        for: .notDownloaded, status: .notDownloaded, formatStatus: ItemFormatDownloadStatus(),
        category: .audiobook, hasReadableEbook: true) == .menu)
  }

  @Test("a mixed item with only audio local offers the missing ebook and removal")
  func mixedAudioOnlyOffersEbookAndRemove() {
    let options = ItemDetailDownloadBubblePresentation.downloadOptions(
      for: .completed,
      formatStatus: ItemFormatDownloadStatus(audio: .completed),
      category: .audiobook,
      hasReadableEbook: true)

    #expect(options.map(\.label) == ["Download eBook"])
    #expect(
      ItemDetailDownloadBubblePresentation.tapBehavior(
        for: .completed, status: .completed,
        formatStatus: ItemFormatDownloadStatus(audio: .completed), category: .audiobook,
        hasReadableEbook: true) == .menu)
    #expect(
      ItemDetailDownloadBubblePresentation.formatMenuRemoveLabel(
        for: .completed, options: options) == "Remove Download")
  }

  @Test("a mixed item with only ebook local offers the missing audiobook and removal")
  func mixedEbookOnlyOffersAudiobookAndRemove() {
    let options = ItemDetailDownloadBubblePresentation.downloadOptions(
      for: .completed,
      formatStatus: ItemFormatDownloadStatus(ebook: .completed),
      category: .audiobook,
      hasReadableEbook: true)

    #expect(options.map(\.label) == ["Download Audiobook"])
    #expect(
      ItemDetailDownloadBubblePresentation.tapBehavior(
        for: .completed, status: .completed,
        formatStatus: ItemFormatDownloadStatus(ebook: .completed), category: .audiobook,
        hasReadableEbook: true) == .menu)
    #expect(
      ItemDetailDownloadBubblePresentation.formatMenuRemoveLabel(
        for: .completed, options: options) == "Remove Download")
  }

  @Test("a mixed item with both formats local offers removal without format downloads")
  func mixedBothCompletedOffersOnlyRemoval() {
    let status = ItemFormatDownloadStatus(audio: .completed, ebook: .completed)

    #expect(
      ItemDetailDownloadBubblePresentation.downloadOptions(
        for: .completed, formatStatus: status, category: .audiobook, hasReadableEbook: true
      ).isEmpty)
    #expect(
      ItemDetailDownloadBubblePresentation.formatMenuRemoveLabel(
        for: .completed, options: []) == nil)
    #expect(
      ItemDetailDownloadBubblePresentation.tapBehavior(
        for: .completed, status: .completed, formatStatus: status, category: .audiobook,
        hasReadableEbook: true) == .confirm)
    #expect(ItemDetailDownloadBubblePresentation.primaryActionLabel(for: .completed) == "Remove Download")
  }

  @Test("single-format and podcast items keep the one-tap download")
  func singleFormatItemsKeepDirectDownload() {
    for (category, hasReadableEbook) in [
      (ItemMediaCategory.audiobook, false),
      (.ebook, true),
      (.podcast, false),
    ] {
      #expect(
        ItemDetailDownloadBubblePresentation.downloadOptions(
          for: .notDownloaded, formatStatus: ItemFormatDownloadStatus(), category: category,
          hasReadableEbook: hasReadableEbook
        ).isEmpty)
      #expect(ItemDetailDownloadBubblePresentation.tapBehavior(for: .notDownloaded) == .direct)
    }
  }

  @Test("a PDF-sidecar audiobook never exposes ebook or both options")
  func pdfSidecarAudiobookKeepsDirectAudioDownload() {
    let options = ItemDetailDownloadBubblePresentation.downloadOptions(
      for: .notDownloaded,
      formatStatus: ItemFormatDownloadStatus(),
      category: .audiobook,
      hasReadableEbook: false)

    #expect(options.isEmpty)
    #expect(
      ItemDetailDownloadBubblePresentation.tapBehavior(
        for: .notDownloaded, status: .notDownloaded,
        formatStatus: ItemFormatDownloadStatus(), category: .audiobook,
        hasReadableEbook: false) == .direct)
  }

  @Test("mixed in-flight states retain their item-level menu behavior")
  func mixedInFlightStatesStayItemLevel() {
    let formatStatus = ItemFormatDownloadStatus(audio: .downloading(progressFraction: 0.4))

    #expect(
      ItemDetailDownloadBubblePresentation.downloadOptions(
        for: .downloading(progressFraction: 0.4), formatStatus: formatStatus,
        category: .audiobook, hasReadableEbook: true
      ).isEmpty)
    #expect(
      ItemDetailDownloadBubblePresentation.tapBehavior(
        for: .downloading, status: .downloading(progressFraction: 0.4),
        formatStatus: formatStatus, category: .audiobook, hasReadableEbook: true) == .menu)
  }
}
