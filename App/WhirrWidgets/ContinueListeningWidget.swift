import SwiftUI
import WidgetKit
import WidgetProtocol

struct ContinueListeningWidget: Widget {
  static let kind = "com.remoteconcern.whirr.widget.continueListening"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: ShelfProvider()) { entry in
      ContinueListeningView(entry: entry)
        .containerBackground(for: .widget) { Color("WidgetBackground") }
    }
    .configurationDisplayName("Continue Listening")
    .description("Pick up where you left off.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}

struct ContinueListeningView: View {
  let entry: ShelfEntry
  @Environment(\.widgetFamily) private var family

  var body: some View {
    switch entry.state {
    case .unavailable:
      shelf(WidgetSampleData.snapshot, isInteractive: false)
        .redacted(reason: .placeholder)
    case .signedOut:
      message("Sign in to Whirr")
    case .signedIn(let snapshot):
      shelf(snapshot, isInteractive: true)
    }
  }

  @ViewBuilder
  private func shelf(_ snapshot: WidgetSnapshot, isInteractive: Bool) -> some View {
    if let presentation = WidgetShelfPresentation(snapshot: snapshot) {
      // The current item's column has its cover beside the play button, so it takes its tap from
      // the widget's own URL rather than a `Link`; a play button inside it still runs its intent.
      Group {
        switch family {
        case .systemSmall: SmallShelf(presentation: presentation, isInteractive: isInteractive)
        case .systemLarge: LargeShelf(presentation: presentation, isInteractive: isInteractive)
        default: MediumShelf(presentation: presentation, isInteractive: isInteractive)
        }
      }
      .widgetURL(isInteractive ? presentation.current.tapURL : nil)
    } else {
      message("Nothing in progress")
    }
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

private struct SmallShelf: View {
  let presentation: WidgetShelfPresentation
  let isInteractive: Bool

  var body: some View {
    let item = presentation.current
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top) {
        WidgetCoverView(item: item, size: 44)
        Spacer(minLength: 4)
        WidgetPlayButton(
          item: item, showsPause: presentation.showsPause(for: item), isInteractive: isInteractive,
          diameter: 34)
      }
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
      Spacer(minLength: 0)
      WidgetProgressBar(fraction: item.progressFraction)
      if let left = WidgetShelfPresentation.timeLeft(remainingSeconds: item.remainingSeconds) {
        Text(left)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct MediumShelf: View {
  let presentation: WidgetShelfPresentation
  let isInteractive: Bool

  var body: some View {
    let item = presentation.current
    HStack(alignment: .top, spacing: 14) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .top) {
          WidgetCoverView(item: item, size: 56)
          Spacer(minLength: 4)
          WidgetPlayButton(
            item: item, showsPause: presentation.showsPause(for: item), isInteractive: isInteractive,
            diameter: 34)
        }
        Text(item.title)
          .font(.footnote.weight(.semibold))
          .lineLimit(2)
          .privacySensitive()
        Spacer(minLength: 0)
        WidgetProgressBar(fraction: item.progressFraction)
        if let left = WidgetShelfPresentation.timeLeft(remainingSeconds: item.remainingSeconds) {
          Text(left)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 10) {
        ForEach(presentation.others.prefix(2), id: \.token) { other in
          HStack(spacing: 8) {
            WidgetItemLink(item: other, isInteractive: isInteractive) {
              HStack(spacing: 8) {
                WidgetCoverView(item: other, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                  Text(other.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .privacySensitive()
                  if let left = WidgetShelfPresentation.timeLeft(remainingSeconds: other.remainingSeconds) {
                    Text(left)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                }
              }
            }
            Spacer(minLength: 0)
            WidgetPlayButton(
              item: other, showsPause: false, isInteractive: isInteractive, diameter: 28)
          }
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

/// The current title large, then the rest of the shelf as rows: four in all, as the smart list
/// widget draws.
private struct LargeShelf: View {
  let presentation: WidgetShelfPresentation
  let isInteractive: Bool

  var body: some View {
    let item = presentation.current
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 14) {
        WidgetCoverView(item: item, size: 104)
        VStack(alignment: .leading, spacing: 4) {
          Text(item.title)
            .font(.subheadline.weight(.semibold))
            .lineLimit(3)
            .privacySensitive()
          if let subtitle = item.subtitle {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .privacySensitive()
          }
          Spacer(minLength: 0)
          HStack(alignment: .bottom) {
            if let left = WidgetShelfPresentation.timeLeft(remainingSeconds: item.remainingSeconds) {
              Text(left)
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            WidgetPlayButton(
              item: item, showsPause: presentation.showsPause(for: item), isInteractive: isInteractive,
              diameter: 40)
          }
        }
        .frame(height: 104)
      }
      WidgetProgressBar(fraction: item.progressFraction)

      if !presentation.others.isEmpty {
        Divider()
        ForEach(presentation.others.prefix(3), id: \.token) { other in
          HStack(spacing: 10) {
            WidgetItemLink(item: other, isInteractive: isInteractive) {
              HStack(spacing: 10) {
                WidgetCoverView(item: other, size: 44)
                VStack(alignment: .leading, spacing: 1) {
                  Text(other.title)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .privacySensitive()
                  if let left = WidgetShelfPresentation.timeLeft(remainingSeconds: other.remainingSeconds) {
                    Text(left)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                  }
                }
              }
            }
            Spacer(minLength: 4)
            WidgetPlayButton(
              item: other, showsPause: false, isInteractive: isInteractive, diameter: 30)
          }
        }
      }
      Spacer(minLength: 0)
    }
  }
}

#if DEBUG
  #Preview("Small", as: .systemSmall) {
    ContinueListeningWidget()
  } timeline: {
    ShelfEntry(date: .now, state: .signedIn(WidgetSampleData.snapshot))
    ShelfEntry(date: .now, state: .unavailable)
    ShelfEntry(date: .now, state: .signedOut)
  }

  #Preview("Medium", as: .systemMedium) {
    ContinueListeningWidget()
  } timeline: {
    ShelfEntry(date: .now, state: .signedIn(WidgetSampleData.snapshot))
    ShelfEntry(date: .now, state: .unavailable)
  }

  #Preview("Large", as: .systemLarge) {
    ContinueListeningWidget()
  } timeline: {
    ShelfEntry(date: .now, state: .signedIn(WidgetSampleData.snapshot))
    ShelfEntry(date: .now, state: .unavailable)
  }
#endif
