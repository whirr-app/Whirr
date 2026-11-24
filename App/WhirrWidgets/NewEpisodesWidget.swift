import SwiftUI
import WidgetKit
import WidgetProtocol

struct NewEpisodesWidget: Widget {
  static let kind = "com.remoteconcern.whirr.widget.newEpisodes"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: ShelfProvider()) { entry in
      NewEpisodesView(entry: entry)
        .containerBackground(for: .widget) { Color("WidgetBackground") }
    }
    .configurationDisplayName("New Episodes")
    .description("The latest episodes from your podcasts.")
    .supportedFamilies([.systemMedium, .systemLarge])
  }
}

struct NewEpisodesView: View {
  let entry: ShelfEntry
  @Environment(\.widgetFamily) private var family

  private var rowLimit: Int { family == .systemLarge ? 4 : 2 }

  var body: some View {
    switch entry.state {
    case .unavailable:
      rows(Array(WidgetNewEpisodesSampleData.episodes.prefix(rowLimit)), snapshot: nil)
        .redacted(reason: .placeholder)
    case .signedOut:
      message("Sign in to Whirr")
    case .signedIn(let snapshot):
      if snapshot.latestEpisodes.isEmpty {
        message("No new episodes")
      } else {
        rows(Array(snapshot.latestEpisodes.prefix(rowLimit)), snapshot: snapshot)
      }
    }
  }

  /// `snapshot` is `nil` for the placeholder, whose rows offer nothing that would act.
  private func rows(_ items: [WidgetItem], snapshot: WidgetSnapshot?) -> some View {
    let playing = snapshot?.nowPlaying.flatMap { $0.isPlaying ? $0.token : nil }
    return VStack(alignment: .leading, spacing: 10) {
      ForEach(items, id: \.token) { item in
        HStack(spacing: 10) {
          WidgetItemLink(item: item, isInteractive: snapshot != nil) {
            HStack(spacing: 10) {
              WidgetCoverView(item: item, size: 44)
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
              }
            }
          }
          Spacer(minLength: 4)
          WidgetPlayButton(
            item: item, showsPause: item.token == playing, isInteractive: snapshot != nil,
            diameter: 32)
        }
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    // Anywhere outside a row's link opens the full list.
    .widgetURL(snapshot != nil ? WidgetTapDestination.latestEpisodes.url : nil)
  }

  private func message(_ text: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: "headphones")
        .font(.title)
        .widgetAccentable()
      Text(text)
        .font(.subheadline.weight(.medium))
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Invented episodes for the placeholder and previews.
enum WidgetNewEpisodesSampleData {
  static let episodes: [WidgetItem] = (1...4).map { index in
    try! WidgetItem(
      token: "sample-new-\(index)", kind: .feedEpisode, title: "Episode title goes here",
      subtitle: "Podcast name", progressFraction: 0, remainingSeconds: 2_400)
  }

  static let snapshot: WidgetSnapshot = {
    let base = WidgetSampleData.snapshot
    return try! WidgetSnapshot(
      generatedAt: base.generatedAt, accountStamp: base.accountStamp,
      skipBackSeconds: base.skipBackSeconds, continueListening: base.continueListening,
      latestEpisodes: episodes)
  }()
}

#if DEBUG
  #Preview("Medium", as: .systemMedium) {
    NewEpisodesWidget()
  } timeline: {
    ShelfEntry(date: .now, state: .signedIn(WidgetNewEpisodesSampleData.snapshot))
    ShelfEntry(date: .now, state: .unavailable)
    ShelfEntry(date: .now, state: .signedOut)
  }

  #Preview("Large", as: .systemLarge) {
    NewEpisodesWidget()
  } timeline: {
    ShelfEntry(date: .now, state: .signedIn(WidgetNewEpisodesSampleData.snapshot))
    ShelfEntry(date: .now, state: .unavailable)
  }
#endif
