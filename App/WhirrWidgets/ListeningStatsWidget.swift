import SwiftUI
import WidgetKit
import WidgetProtocol

struct StatsEntry: TimelineEntry {
  let date: Date
  let state: WidgetSnapshotState
}

/// Today and the streak are derived from the entry's date, so the timeline carries a second entry
/// at the next midnight and the figures roll over without the app running.
struct ListeningStatsProvider: TimelineProvider {
  func placeholder(in context: Context) -> StatsEntry {
    StatsEntry(date: .now, state: .unavailable)
  }

  func getSnapshot(in context: Context, completion: @escaping (StatsEntry) -> Void) {
    let state: WidgetSnapshotState =
      context.isPreview
      ? .signedIn(WidgetStatsSampleData.snapshot(now: .now)) : WidgetSnapshotReader.production.read()
    completion(StatsEntry(date: .now, state: state))
  }

  /// Two entries, then `.atEnd`: the entry at midnight redraws with the new day, and the reload
  /// after it re-reads the snapshot (the app also reloads timelines whenever it publishes).
  func getTimeline(in context: Context, completion: @escaping (Timeline<StatsEntry>) -> Void) {
    let state = WidgetSnapshotReader.production.read()
    let now = Date.now
    let midnight = WidgetStatsPresentation.nextMidnight(after: now, calendar: .current)
    completion(
      Timeline(
        entries: [StatsEntry(date: now, state: state), StatsEntry(date: midnight, state: state)],
        policy: .atEnd))
  }
}

struct ListeningStatsWidget: Widget {
  static let kind = "com.remoteconcern.whirr.widget.listeningStats"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: ListeningStatsProvider()) { entry in
      ListeningStatsView(entry: entry)
        .containerBackground(for: .widget) { Color("WidgetBackground") }
    }
    .configurationDisplayName("Listening Stats")
    .description("Today's listening and your streak.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

struct ListeningStatsView: View {
  let entry: StatsEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    switch entry.state {
    case .unavailable:
      content(WidgetStatsSampleData.stats(now: entry.date))
        .redacted(reason: .placeholder)
    case .signedOut:
      message("Sign in to Whirr")
    case .signedIn(let snapshot):
      // The pre-stats message links there too: the Stats screen is what fills the widget.
      Group {
        if let stats = snapshot.stats {
          content(stats)
        } else {
          message("Open Whirr's stats to see your listening here")
        }
      }
      .widgetURL(WidgetTapDestination.listeningStats.url)
    }
  }

  private func content(_ stats: WidgetStats) -> some View {
    let presentation = WidgetStatsPresentation(
      stats: stats, now: entry.date, calendar: .current)
    return Group {
      if family == .systemSmall {
        SmallStats(presentation: presentation)
      } else {
        MediumStats(presentation: presentation)
      }
    }
  }

  private func message(_ text: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: "chart.bar.fill")
        .font(.title)
        .widgetAccentable()
      Text(text)
        .font(.subheadline.weight(.medium))
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct StreakLabel: View {
  let days: Int

  var body: some View {
    Label {
      Text(days == 1 ? "1 day streak" : "\(days) day streak")
    } icon: {
      Image(systemName: "flame.fill")
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(days > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    .widgetAccentable(days > 0)
  }
}

private struct TodayFigure: View {
  let presentation: WidgetStatsPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Today")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(WidgetStatsPresentation.durationText(seconds: presentation.todaySeconds))
        .font(.title2.weight(.bold))
        .minimumScaleFactor(0.7)
        .lineLimit(1)
    }
  }
}

private struct OutdatedNote: View {
  let presentation: WidgetStatsPresentation

  var body: some View {
    if presentation.isOutdated {
      Text("As of \(presentation.fetchedAt.formatted(.dateTime.day().month(.abbreviated)))")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}

private struct SmallStats: View {
  let presentation: WidgetStatsPresentation

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      TodayFigure(presentation: presentation)
      Spacer(minLength: 0)
      StreakLabel(days: presentation.streakDays)
      OutdatedNote(presentation: presentation)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct MediumStats: View {
  let presentation: WidgetStatsPresentation

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        TodayFigure(presentation: presentation)
        VStack(alignment: .leading, spacing: 2) {
          Text("Last 7 days")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(WidgetStatsPresentation.durationText(seconds: presentation.lastSevenDaysSeconds))
            .font(.footnote.weight(.semibold))
        }
        Spacer(minLength: 0)
        StreakLabel(days: presentation.streakDays)
        OutdatedNote(presentation: presentation)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      WeekStrip(days: presentation.lastSevenDays)
        .frame(maxWidth: .infinity)
    }
  }
}

/// Seven bars scaled to the week's longest day; a day under the streak threshold is dimmed.
private struct WeekStrip: View {
  let days: [WidgetStatsPresentation.Day]

  var body: some View {
    let longest = max(days.map(\.seconds).max() ?? 0, 1)
    HStack(alignment: .bottom, spacing: 6) {
      ForEach(Array(days.enumerated()), id: \.offset) { _, day in
        VStack(spacing: 4) {
          GeometryReader { proxy in
            VStack {
              Spacer(minLength: 0)
              RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(day.listened ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                .frame(height: max(4, proxy.size.height * day.seconds / longest))
                .widgetAccentable(day.listened)
            }
          }
          Text(day.date.formatted(.dateTime.weekday(.narrow)))
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Listening over the last 7 days")
  }
}

/// Invented figures, dated relative to `now` so the sample always looks current.
enum WidgetStatsSampleData {
  static func stats(now: Date, calendar: Calendar = .current) -> WidgetStats {
    let seconds: [Double] = [2_100, 3_400, 0, 1_800, 4_200, 900, 2_700, 1_500]
    let days = seconds.enumerated().reversed().map { offset, value in
      let day = calendar.date(byAdding: .day, value: -offset, to: now) ?? now
      let parts = calendar.dateComponents([.year, .month, .day], from: day)
      let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
      return try! WidgetStats.Day(date: key, seconds: value)
    }
    return try! WidgetStats(
      days: days, streakDaysBeforeWindow: 0, totalSeconds: 360_000, fetchedAt: now)
  }

  static func snapshot(now: Date) -> WidgetSnapshot {
    let base = WidgetSampleData.snapshot
    return try! WidgetSnapshot(
      generatedAt: base.generatedAt, accountStamp: base.accountStamp,
      skipBackSeconds: base.skipBackSeconds, continueListening: base.continueListening,
      stats: stats(now: now))
  }
}

#if DEBUG
  #Preview("Small", as: .systemSmall) {
    ListeningStatsWidget()
  } timeline: {
    StatsEntry(date: .now, state: .signedIn(WidgetStatsSampleData.snapshot(now: .now)))
    StatsEntry(date: .now, state: .unavailable)
    StatsEntry(date: .now, state: .signedOut)
  }

  #Preview("Medium", as: .systemMedium) {
    ListeningStatsWidget()
  } timeline: {
    StatsEntry(date: .now, state: .signedIn(WidgetStatsSampleData.snapshot(now: .now)))
    StatsEntry(date: .now, state: .unavailable)
  }
#endif
