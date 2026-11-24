import Foundation
import Persistence
import ReaderCore

/// All reader-facing copy is kept in AppModel so views never need to translate a domain outcome.
public enum ReaderCopy {
  public static let downloadFailed = "This book could not be downloaded. Try again."

  /// The server served a file that disagreed with the details it reported for it. Does not say
  /// "try again": the mismatch reproduces on every attempt, as each re-reads the same server-side
  /// metadata. A library scan clears it, after which the server reports the file it now holds.
  public static let downloadRejected =
    "The file the server sent doesn't match the details it reported for this book. "
    + "Re-scanning the library on your server usually fixes this."

  /// Defers to `ItemDownloadCopy`: a download parked for Wi-Fi is the same condition whether the
  /// reader or item detail describes it, and the Wi-Fi line names the Settings toggle that
  /// releases it.
  public static func downloadHeld(_ reason: ReaderDownloadHold) -> String {
    switch reason {
    case .waitingForWiFi: ItemDownloadCopy.waitingForWiFi
    case .paused: ItemDownloadCopy.paused
    case .pausedAuth: ItemDownloadCopy.pausedAuth
    }
  }

  public static let resumeDownload = "Resume download"
  public static let drmProtected = "This book is protected and cannot be opened here."
  public static let unopenable = "This book could not be opened. Download it again to retry."
  public static let publicationServerFailure =
    "The reader could not start. Check your connection and try again."
  public static let advertisedButUnavailable = "This book is advertised, but its EPUB is unavailable."
  public static let ebookIdentityNotFetched = "Checking this book's file with the server…"
  public static let noEpub = "No EPUB is available for this item."

  // Reader chrome
  public static let chapters = "Chapters"
  public static let tableOfContents = "Table of contents"
  public static let search = "Search"
  public static let searchPrompt = "Search this book"
  public static let searchNothingTyped = "Type a word or phrase to search this book."
  public static let searchSearching = "Searching…"
  public static let searchNoMatches = "No matches found."
  public static let searchFailed = "Search could not be completed. Try again."
  public static let searchResultLimit = "Showing the first 500 matches."
  public static let closeReader = "Close reader"
  public static let showReaderControls = "Show reader controls"
  public static let hideReaderControls = "Hide reader controls"
  public static func readerControlsActionLabel(chromeVisible: Bool) -> String {
    chromeVisible ? hideReaderControls : showReaderControls
  }
  /// The panel's title. Its trigger keeps the longer `readerAppearance` label, which VoiceOver
  /// needs from a button on the reading page but is too wordy for a title bar.
  public static let appearance = "Appearance"
  public static let customise = "Customise"
  public static let resetTypography = "Reset to defaults"
  /// Shown in the appearance sample when the open book offers no text at the reading position.
  public static let typographySampleFallback =
    "The lamps along the harbour came on one by one, and the water took each of them and broke "
    + "it into a hundred pieces. She stood at the rail a long while, reading the town by its lights.\n"
    + "By morning the boat would be gone, and with it the last excuse she had for staying."
  public static let readerAppearance = "Reader appearance"
  public static let readingProgress = "Reading progress"
  public static let readingPosition = "Reading position"
  public static let readerMenu = "Reader menu"
  public static let markAsFinished = "Mark as finished"
  public static let markBookAsFinished = "Mark book as finished"
  public static let markAsFinishedHint = "Marks this eBook as finished."

  public static let contents = "Contents"

  public static let font = "Font"
  public static let readerFont = "Reader font"
  public static let fontSize = "Font size"
  public static let lineSpacing = "Line spacing"
  public static let wordSpacing = "Word spacing"
  public static let letterSpacing = "Letter spacing"
  public static let paragraphSpacing = "Paragraph spacing"
  public static let hyphenation = "Hyphenation"
  public static let publisherStyles = "Publisher styles"
  public static let margins = "Margins"
  public static let themes = "Themes"
  public static let readerTheme = "Reader theme"
  public static let brightness = "Brightness"
  public static let readerBrightness = "Screen brightness"

  public static let light = "Light"
  public static let lightTheme = "Light theme"
  public static let sepia = "Sepia"
  public static let sepiaTheme = "Sepia theme"
  public static let dark = "Dark"
  public static let darkTheme = "Dark theme"

  public static let publisher = "Publisher"
  public static let publisherFont = "Publisher font"
  public static let serif = "Serif"
  public static let serifFont = "Serif font"
  public static let sansSerif = "Sans serif"
  public static let sansSerifFont = "Sans serif font"
  public static let monospaced = "Monospaced"
  public static let monospacedFont = "Monospaced font"
  public static let openDyslexic = "OpenDyslexic"
  public static let openDyslexicFont = "OpenDyslexic font"

  public static let pages = "Pages"
  public static let scroll = "Scroll"
  public static let readingMode = "Reading mode"
  public static let publisherDefault = "Publisher default"
  public static let left = "Left"
  public static let justify = "Justify"
  public static let on = "On"
  public static let off = "Off"
  public static let fixedLayoutUnavailable = "Not available for fixed-layout books"
  public static let publisherStylesFooter =
    "Turn off publisher styles to adjust text alignment, spacing, and hyphenation"

  public static let layout = "Layout"
  public static let typography = "Typography"
  public static let textAlignment = "Text alignment"
  public static let publisherDefaultAlignment = "Publisher's alignment"
  public static let leftAlignment = "Left-aligned text"
  public static let justifiedAlignment = "Justified text"

  /// Joined-cell glyphs, and the labels VoiceOver speaks in their place.
  public static let decreaseGlyph = "−"
  public static let increaseGlyph = "+"
  /// The text-size pair is a small and a large "A"; the size difference is the whole label.
  public static let decreaseFontSizeGlyph = "A"
  public static let increaseFontSizeGlyph = "A"
  public static let decreaseFontSize = "Decrease font size"
  public static let increaseFontSize = "Increase font size"
  public static let decreaseLineSpacing = "Decrease line spacing"
  public static let increaseLineSpacing = "Increase line spacing"
  public static let decreaseWordSpacing = "Decrease word spacing"
  public static let increaseWordSpacing = "Increase word spacing"
  public static let decreaseLetterSpacing = "Decrease letter spacing"
  public static let increaseLetterSpacing = "Increase letter spacing"
  public static let decreaseParagraphSpacing = "Decrease paragraph spacing"
  public static let increaseParagraphSpacing = "Increase paragraph spacing"
  public static let decreaseMargins = "Decrease margins"
  public static let increaseMargins = "Increase margins"

  /// The size control's value: the publisher's size is 100%, scaled by the rendered font scale.
  public static func fontSizeValue(step: Int) -> String {
    let scale = ReaderTypography(preferences: ReaderPreferences(fontSizeStep: step)).fontScale
    return "\(Int((scale * 100).rounded()))%"
  }

  /// Spacing is spoken as a word, not a multiplier or em value: the live sample shows the effect,
  /// and a number such as "1.4" means nothing to a reader.
  private static let spacingValues = ["Default", "Slightly wider", "Wider", "Much wider", "Widest"]

  private static func spacingWord(step: Int) -> String {
    spacingValues[min(max(step, 0), spacingValues.count - 1)]
  }

  public static func lineSpacingValue(step: Int) -> String { spacingWord(step: step) }

  public static func wordSpacingValue(step: Int) -> String { spacingWord(step: step) }

  public static func letterSpacingValue(step: Int) -> String { spacingWord(step: step) }

  public static func paragraphSpacingValue(step: Int) -> String { spacingWord(step: step) }

  private static let marginsValues = ["Default", "Narrow", "Medium", "Wide", "Widest"]

  /// Margins as a named width rather than a step count, as the reference shows.
  public static func marginsValue(step: Int) -> String {
    marginsValues[min(max(step, 0), marginsValues.count - 1)]
  }

  public static func progressPercent(_ progress: Double) -> String {
    "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
  }

  /// Renders the reader's live screen-brightness slider as a whole percentage.
  public static func brightnessValue(_ brightness: Double) -> String {
    progressPercent(brightness)
  }

  /// Renders the rail's page copy only when both one-based page values are valid.
  public static func progressPageText(page: Int?, pageCount: Int?) -> String? {
    guard let page, let pageCount, page > 0, pageCount > 0 else { return nil }
    return "Page \(page) of \(pageCount)"
  }

  /// The reading position shown above the rail. The compact form drops "Page" so the chapter
  /// estimate still fits beside it on a phone-width rail.
  public static func readoutPosition(
    percentText: String, page: Int?, pageCount: Int?, isCompact: Bool
  ) -> String {
    guard let page, let pageCount, page > 0, pageCount > 0 else { return percentText }
    let pageText = isCompact ? "\(page) of \(pageCount)" : "Page \(page) of \(pageCount)"
    return "\(pageText) · \(percentText)"
  }

  /// The rail's undo offer after a seek. Names the page left behind so the choice is informed,
  /// falling back to the percentage for a book without a positions list.
  public static func backToPosition(page: Int?, percentText: String) -> String {
    guard let page, page > 0 else { return "Back to \(percentText)" }
    return "Back to page \(page)"
  }

  public static let dismissReturnOffer = "Dismiss"

  /// Unhedged, unlike the book estimate: it sits beside the position in the rail's narrow readout,
  /// where "About" costs the width that decides whether it fits.
  public static func chapterTimeRemaining(seconds: Double) -> String? {
    timeRemaining(seconds: seconds, location: "chapter", hedge: "")
  }

  public static func bookTimeRemaining(seconds: Double) -> String? {
    timeRemaining(seconds: seconds, location: "book", hedge: "About ")
  }

  private static func timeRemaining(seconds: Double, location: String, hedge: String) -> String? {
    guard seconds.isFinite, seconds >= 60 else { return nil }

    let totalMinutes = Int((seconds / 60).rounded())
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0, minutes > 0 {
      return "\(hedge)\(hours) hr \(minutes) min left in \(location)"
    }
    if hours > 0 {
      return "\(hedge)\(hours) hr left in \(location)"
    }
    return "\(hedge)\(totalMinutes) min left in \(location)"
  }

  /// Produces the rail's single VoiceOver utterance from its independent display strings.
  public static func progressAccessibilityValue(
    percentText: String, pageText: String?
  ) -> String {
    let spokenPercent =
      percentText.hasSuffix("%")
      ? "\(percentText.dropLast()) percent"
      : percentText
    return [readingProgress, spokenPercent, pageText]
      .compactMap { $0 }
      .joined(separator: ", ")
  }

  /// The chapter row's spoken value. The visible label is a bare number, which VoiceOver would
  /// read without saying what it counts.
  public static func tocPageValue(_ pageLabel: String) -> String {
    "Page \(pageLabel)"
  }

  /// Renders a publication position as a page label. Positions are one-based already (Readium's
  /// `Locator.position` is documented as ">= 1"), so this does not shift the value.
  public static func pageLabel(forPosition position: Int) -> String {
    "\(position)"
  }

  public static func progressText(
    progress: Double,
    chapterTitle: String?,
    page: Int?,
    pageCount: Int?,
    bookTimeRemainingText: String? = nil
  ) -> String {
    let percent = progressPercent(progress)
    var components = [percent]
    if let chapterTitle, pageCount != nil || page != nil {
      components.append(chapterTitle)
      if let pageText = progressPageText(page: page, pageCount: pageCount) {
        components.append(pageText)
      }
    }
    if let bookTimeRemainingText {
      components.append(bookTimeRemainingText)
    }
    return components.joined(separator: " · ")
  }
}
