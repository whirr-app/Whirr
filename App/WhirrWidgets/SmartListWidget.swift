import AppIntents
import SwiftUI
import WidgetKit
import WidgetProtocol

/// One smart list, chosen in Edit Widget: its name, how many episodes match, the first four, and
/// one play button that starts the list from the top. Medium draws the four as a grid, large as
/// rows.
struct SmartListWidget: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: SmartListWidgetIntent.widgetKind, intent: SmartListWidgetIntent.self,
      provider: SmartListProvider()
    ) { entry in
      SmartListWidgetView(entry: entry)
        .containerBackground(for: .widget) { Color("WidgetBackground") }
    }
    .configurationDisplayName("Smart List")
    .description("Episodes from one of your smart lists.")
    .supportedFamilies([.systemMedium, .systemLarge])
  }
}

struct SmartListEntry: TimelineEntry {
  let date: Date
  let presentation: WidgetSmartListPresentation
}

struct SmartListProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> SmartListEntry {
    SmartListEntry(date: .now, presentation: .unavailable)
  }

  func snapshot(for configuration: SmartListWidgetIntent, in context: Context) async -> SmartListEntry {
    // The widget gallery shows sample content rather than the listener's own lists.
    if context.isPreview {
      return SmartListEntry(date: .now, presentation: .list(SmartListSampleData.list, isPlaying: false))
    }
    return entry(for: configuration)
  }

  func timeline(for configuration: SmartListWidgetIntent, in context: Context) async -> Timeline<SmartListEntry> {
    // The app reloads timelines whenever it writes either file.
    Timeline(entries: [entry(for: configuration)], policy: .never)
  }

  private func entry(for configuration: SmartListWidgetIntent) -> SmartListEntry {
    let snapshotState = WidgetSnapshotReader.production.read()
    let snapshot: WidgetSnapshot? =
      switch snapshotState {
      case .unavailable: nil
      case .signedOut: .signedOut(generatedAt: .now)
      case .signedIn(let snapshot): snapshot
      }
    let presentation = WidgetSmartListPresentation(
      snapshot: snapshot, lists: WidgetSmartListsReader.production.read(),
      configuredListID: configuration.list.flatMap { WidgetSmartListID.parse($0.id) })
    return SmartListEntry(date: .now, presentation: presentation)
  }
}

struct SmartListWidgetView: View {
  let entry: SmartListEntry
  @Environment(\.widgetFamily) private var family

  private static let rowLimit = WidgetSmartListLimits.maxItemsPerList

  var body: some View {
    switch entry.presentation {
    case .unavailable:
      content(SmartListSampleData.list, presentation: entry.presentation, isInteractive: false)
        .redacted(reason: .placeholder)
    case .signedOut:
      message("Sign in to Whirr", symbol: "headphones", url: nil)
    case .noLists:
      message("Create a smart list in Whirr", symbol: "line.3.horizontal.decrease", url: nil)
    case .deleted:
      message("This list was deleted", symbol: "line.3.horizontal.decrease", url: nil)
    case .list(let list, _):
      content(list, presentation: entry.presentation, isInteractive: true)
    }
  }

  private func content(
    _ list: WidgetSmartList, presentation: WidgetSmartListPresentation, isInteractive: Bool
  ) -> some View {
    let items = Array(list.items.prefix(Self.rowLimit))
    // The placeholder draws sample rows, so its button is drawn from the sample's first row.
    let top = isInteractive ? presentation.playFromTop : items.first
    return VStack(alignment: .leading, spacing: family == .systemMedium ? 8 : 10) {
      header(list, top: top, showsPause: presentation.showsListPause, isInteractive: isInteractive)
      if items.isEmpty {
        Text("Nothing in this list right now")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if family == .systemMedium {
        grid(items, isInteractive: isInteractive)
        Spacer(minLength: 0)
      } else {
        ForEach(items, id: \.token) { item in
          row(item, isInteractive: isInteractive)
        }
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    // Anywhere outside a row's link opens the list's screen.
    .widgetURL(isInteractive ? WidgetTapDestination.smartList(id: list.id).url : nil)
  }

  private func header(
    _ list: WidgetSmartList, top: WidgetItem?, showsPause: Bool, isInteractive: Bool
  ) -> some View {
    HStack(alignment: .center, spacing: 8) {
      // One line, so medium's grid keeps two full rows under it.
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(list.name)
          .font(.headline)
          .lineLimit(1)
          .privacySensitive()
        if let count = WidgetSmartListPresentation.countText(list.matchCount) {
          Text(count)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .layoutPriority(-1)
        }
      }
      Spacer(minLength: 8)
      if let top {
        WidgetPlayButton(
          item: top, showsPause: showsPause, isInteractive: isInteractive,
          diameter: family == .systemMedium ? 28 : 34, startsListRun: true,
          playLabel: "Play \(list.name)")
      }
    }
  }

  /// Four cells in two columns; each cell is its episode's link.
  private func grid(_ items: [WidgetItem], isInteractive: Bool) -> some View {
    Grid(horizontalSpacing: 12, verticalSpacing: 8) {
      ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { start in
        GridRow {
          cell(items[start], isInteractive: isInteractive)
          if start + 1 < items.count {
            cell(items[start + 1], isInteractive: isInteractive)
          } else {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
          }
        }
      }
    }
  }

  private func cell(_ item: WidgetItem, isInteractive: Bool) -> some View {
    WidgetItemLink(item: item, isInteractive: isInteractive) {
      HStack(spacing: 8) {
        WidgetCoverView(item: item, size: 40)
        Text(item.title)
          .font(.caption.weight(.semibold))
          .lineLimit(2)
          .privacySensitive()
        Spacer(minLength: 0)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func row(_ item: WidgetItem, isInteractive: Bool) -> some View {
    WidgetItemLink(item: item, isInteractive: isInteractive) {
      HStack(spacing: 10) {
        WidgetCoverView(item: item, size: 48)
        VStack(alignment: .leading, spacing: 1) {
          Text(item.title)
            .font(.footnote.weight(.semibold))
            .lineLimit(2)
            .privacySensitive()
          if let subtitle = item.subtitle {
            Text(subtitle)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .privacySensitive()
          }
          if let left = WidgetShelfPresentation.timeLeft(remainingSeconds: item.remainingSeconds) {
            Text(left)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        Spacer(minLength: 0)
      }
    }
  }

  private func message(_ text: String, symbol: String, url: URL?) -> some View {
    VStack(spacing: 8) {
      Image(systemName: symbol)
        .font(.title)
        .widgetAccentable()
      Text(text)
        .font(.subheadline.weight(.medium))
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .widgetURL(url)
  }
}

/// An invented list for the placeholder, the gallery and previews.
enum SmartListSampleData {
  static let list: WidgetSmartList = {
    let items = (1...4).map { index in
      try! WidgetItem(
        token: "sample-list-\(index)", kind: .feedEpisode, title: "Episode title goes here",
        subtitle: "Podcast name", progressFraction: 0, remainingSeconds: 2_400)
    }
    return try! WidgetSmartList(id: 1, name: "Smart list", matchCount: 12, items: items)
  }()
}

#if DEBUG
  #Preview("Medium", as: .systemMedium) {
    SmartListWidget()
  } timeline: {
    SmartListEntry(date: .now, presentation: .list(SmartListSampleData.list, isPlaying: false))
    SmartListEntry(date: .now, presentation: .unavailable)
  }

  #Preview("Large", as: .systemLarge) {
    SmartListWidget()
  } timeline: {
    SmartListEntry(date: .now, presentation: .list(SmartListSampleData.list, isPlaying: false))
    SmartListEntry(date: .now, presentation: .unavailable)
    SmartListEntry(date: .now, presentation: .signedOut)
    SmartListEntry(date: .now, presentation: .noLists)
    SmartListEntry(date: .now, presentation: .deleted)
  }
#endif
