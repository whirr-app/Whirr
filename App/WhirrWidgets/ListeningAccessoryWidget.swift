import SwiftUI
import WidgetKit
import WidgetProtocol

/// Lock Screen accessories draw no title, subtitle or cover: they are visible without unlocking.
struct ListeningAccessoryWidget: Widget {
  static let kind = "com.remoteconcern.whirr.widget.listeningAccessory"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: ShelfProvider()) { entry in
      ListeningAccessoryView(entry: entry)
        .containerBackground(for: .widget) { Color.clear }
    }
    .configurationDisplayName("Listening Progress")
    .description("Progress and time left in what you are listening to.")
    .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
  }
}

struct ListeningAccessoryView: View {
  let entry: ShelfEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    switch entry.state {
    case .unavailable:
      content(for: WidgetShelfPresentation(snapshot: WidgetSampleData.snapshot)?.current)
        .redacted(reason: .placeholder)
    case .signedOut:
      content(for: nil, fallback: "Whirr")
    case .signedIn(let snapshot):
      let current = WidgetShelfPresentation(snapshot: snapshot)?.current
      content(for: current, fallback: "Nothing in progress")
        .widgetURL(current?.tapURL)
    }
  }

  @ViewBuilder
  private func content(for item: WidgetItem?, fallback: String = "Whirr") -> some View {
    switch family {
    case .accessoryCircular:
      circular(item)
    case .accessoryInline:
      inline(item, fallback: fallback)
    default:
      rectangular(item, fallback: fallback)
    }
  }

  private func circular(_ item: WidgetItem?) -> some View {
    ZStack {
      AccessoryWidgetBackground()
      if let item {
        Gauge(value: item.progressFraction) {
          Text("Progress")
        } currentValueLabel: {
          Image(systemName: item.kindSymbol)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
      } else {
        Image(systemName: "headphones")
          .font(.title3)
          .widgetAccentable()
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Listening progress")
    .accessibilityValue(spokenProgress(item))
  }

  private func rectangular(_ item: WidgetItem?, fallback: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Label {
        Text(item.flatMap(WidgetShelfPresentation.accessorySummary(for:)) ?? fallback)
      } icon: {
        Image(systemName: item?.kindSymbol ?? "headphones")
      }
      .font(.headline)
      .widgetAccentable()
      if let item {
        Gauge(value: item.progressFraction) { Text("Progress") }
          .gaugeStyle(.accessoryLinearCapacity)
          .accessibilityLabel("Progress")
          .accessibilityValue("\(percent(item)) percent")
      }
    }
  }

  private func inline(_ item: WidgetItem?, fallback: String) -> some View {
    Label(
      item.flatMap(WidgetShelfPresentation.accessorySummary(for:)) ?? fallback,
      systemImage: item?.kindSymbol ?? "headphones")
  }

  private func percent(_ item: WidgetItem) -> Int {
    Int((item.progressFraction * 100).rounded())
  }

  private func spokenProgress(_ item: WidgetItem?) -> String {
    guard let item else { return "" }
    let left = WidgetShelfPresentation.timeLeft(remainingSeconds: item.remainingSeconds)
    return ["\(percent(item)) percent", left].compactMap { $0 }.joined(separator: ", ")
  }
}

#if DEBUG
  #Preview("Circular", as: .accessoryCircular) {
    ListeningAccessoryWidget()
  } timeline: {
    ShelfEntry(date: .now, state: .signedIn(WidgetSampleData.snapshot))
    ShelfEntry(date: .now, state: .signedOut)
  }

  #Preview("Rectangular", as: .accessoryRectangular) {
    ListeningAccessoryWidget()
  } timeline: {
    ShelfEntry(date: .now, state: .signedIn(WidgetSampleData.snapshot))
    ShelfEntry(date: .now, state: .unavailable)
  }

  #Preview("Inline", as: .accessoryInline) {
    ListeningAccessoryWidget()
  } timeline: {
    ShelfEntry(date: .now, state: .signedIn(WidgetSampleData.snapshot))
  }
#endif
