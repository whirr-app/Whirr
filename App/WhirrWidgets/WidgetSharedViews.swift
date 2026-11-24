import AppIntents
import SwiftUI
import UIKit
import WidgetKit
import WidgetProtocol

/// One entry at `.now`: the app reloads timelines whenever it publishes a new snapshot, so the
/// widget has no future states of its own to schedule.
struct ShelfEntry: TimelineEntry {
  let date: Date
  let state: WidgetSnapshotState
}

/// Shared by both Continue Listening widgets; they differ only in the families they draw.
struct ShelfProvider: TimelineProvider {
  func placeholder(in context: Context) -> ShelfEntry {
    ShelfEntry(date: .now, state: .unavailable)
  }

  func getSnapshot(in context: Context, completion: @escaping (ShelfEntry) -> Void) {
    // The widget gallery shows sample content rather than the listener's own shelf.
    let state: WidgetSnapshotState =
      context.isPreview ? .signedIn(WidgetSampleData.snapshot) : WidgetSnapshotReader.production.read()
    completion(ShelfEntry(date: .now, state: state))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<ShelfEntry>) -> Void) {
    let entry = ShelfEntry(date: .now, state: WidgetSnapshotReader.production.read())
    completion(Timeline(entries: [entry], policy: .never))
  }
}

/// Content drawn redacted for `.unavailable` and for the placeholder; the titles are invented.
enum WidgetSampleData {
  static let snapshot: WidgetSnapshot = {
    try! WidgetSnapshot(
      generatedAt: Date(timeIntervalSinceReferenceDate: 815_000_000),
      accountStamp: WidgetAccountStamp(
        accountIdentityHash: String(repeating: "a1", count: 32),
        serverIdentityHash: String(repeating: "0f", count: 32)),
      skipBackSeconds: 15,
      continueListening: [
        WidgetItem(
          token: "sample-1", kind: .book, title: "The Lantern Keepers",
          subtitle: "Author name", progressFraction: 0.42, remainingSeconds: 21_600),
        WidgetItem(
          token: "sample-2", kind: .serverEpisode, title: "Episode title goes here",
          subtitle: "Podcast name", progressFraction: 0.7, remainingSeconds: 1_080),
        WidgetItem(
          token: "sample-3", kind: .feedEpisode, title: "Another episode title",
          subtitle: "Podcast name", progressFraction: 0.15, remainingSeconds: 2_700),
        WidgetItem(
          token: "sample-4", kind: .serverEpisode, title: "One more episode title",
          subtitle: "Podcast name", progressFraction: 0.5, remainingSeconds: 1_500),
      ])
  }()
}

extension WidgetItem {
  /// The glyph that stands in for a cover and marks the kind on the Lock Screen.
  var kindSymbol: String { kind == .book ? "book.fill" : "headphones" }

  /// Opens the app on this title: an episode's card or a book's detail.
  var tapURL: URL? { WidgetTapDestination.item(token: token).url }
}

/// A row's cover and text, linked to its title when the widget is live. The placeholder draws
/// sample rows whose tokens pass validation, so it gets no link. Never put a play button inside:
/// a `Link` must not contain a `Button`. `systemSmall` ignores `Link`; it uses `widgetURL`.
struct WidgetItemLink<Label: View>: View {
  let item: WidgetItem
  let isInteractive: Bool
  @ViewBuilder let label: Label

  var body: some View {
    if isInteractive, let url = item.tapURL {
      Link(destination: url) { label }
    } else {
      label
    }
  }
}

/// The cover, or a glyph when the item has none or the file has since been pruned. Loaded per
/// draw and not cached, to stay inside the extension's memory budget.
struct WidgetCoverView: View {
  let item: WidgetItem
  let size: CGFloat

  var body: some View {
    cover
      .frame(width: size, height: size)
      .clipShape(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous))
      .privacySensitive()
      .accessibilityHidden(true)
  }

  @ViewBuilder private var cover: some View {
    if let image = WidgetSnapshotReader.production.cover(for: item) {
      Image(uiImage: image)
        .resizable()
        // The cover is what tells rows apart, so it keeps its colour in the clear and tinted
        // styles, as Apple's own media widgets do; text and controls take the accent instead.
        .widgetAccentedRenderingMode(.fullColor)
        .aspectRatio(contentMode: .fill)
    } else {
      ZStack {
        Rectangle().fill(.quaternary)
        Image(systemName: item.kindSymbol)
          .font(.system(size: size * 0.4))
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct WidgetProgressBar: View {
  let fraction: Double

  var body: some View {
    ProgressView(value: fraction)
      .progressViewStyle(.linear)
      .widgetAccentable()
      .accessibilityLabel("Progress")
      .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
  }
}

/// Play for `item`, or pause when it is the item currently playing. Without `isInteractive` it is
/// drawn as a plain glyph, so a placeholder offers nothing that would act. The smart list's play
/// (`startsListRun`) starts that list's run from `item`, so the list continues after it.
struct WidgetPlayButton: View {
  let item: WidgetItem
  let showsPause: Bool
  let isInteractive: Bool
  let diameter: CGFloat
  var startsListRun = false
  /// What VoiceOver reads for play; the item's title when `nil`.
  var playLabel: String?

  var body: some View {
    if !isInteractive {
      glyph
    } else if showsPause {
      Button(intent: PausePlaybackIntent()) { glyph }
        .buttonStyle(.plain)
        .accessibilityLabel("Pause")
    } else if startsListRun {
      Button(intent: PlaySmartListItemIntent(token: item.token)) { glyph }
        .buttonStyle(.plain)
        .accessibilityLabel(playLabel ?? "Play \(item.title)")
    } else {
      Button(intent: PlayWidgetItemIntent(token: item.token)) { glyph }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(item.title)")
    }
  }

  @Environment(\.widgetRenderingMode) private var renderingMode

  /// Outside full colour the system draws every view in one accent colour, so a glyph laid over
  /// a filled circle vanishes into it. The `.circle.fill` symbol cuts the glyph out of the circle
  /// instead, which survives any single-colour treatment (clear, tinted, Lock Screen).
  @ViewBuilder private var glyph: some View {
    if renderingMode == .fullColor {
      Image(systemName: showsPause ? "pause.fill" : "play.fill")
        .font(.system(size: diameter * 0.42, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: diameter, height: diameter)
        .background(.tint, in: Circle())
    } else {
      Image(systemName: showsPause ? "pause.circle.fill" : "play.circle.fill")
        .resizable()
        .scaledToFit()
        .frame(width: diameter, height: diameter)
        .widgetAccentable()
    }
  }
}
