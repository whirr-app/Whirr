import AppModel
import SwiftUI
import UIKit

/// A slim line above the text while the rest of the episode is still being made.
struct TranscriptProgressStrip: View {
  let model: EpisodeTranscriptModel
  let accent: TranscriptAccent
  let onTranscribe: () -> Void

  static func percent(_ fraction: Double) -> String {
    fraction.formatted(.percent.precision(.fractionLength(0)))
  }

  var body: some View {
    if let status {
      HStack(spacing: 14) {
        Image(systemName: status.symbol)
          .font(.title3)
          .foregroundStyle(accent.fill)
          .symbolEffect(.variableColor.iterative, isActive: status.isWorking)
          .frame(width: 28)
        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 8) {
            ForEach(Array(status.labels.enumerated()), id: \.offset) { index, label in
              Text(label)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(index == 0 ? Color.primary : Color(uiColor: .secondaryLabel))
            }
          }
          .accessibilityElement(children: .combine)
          ProgressView(value: status.fraction)
            .tint(accent.fill)
        }
        if case .offer = model.state {
          Button("Continue") { onTranscribe() }
            .transcriptPrimaryAction(accent, size: .regular)
        } else {
          Button("Stop Transcribing", systemImage: "xmark") { model.cancel() }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(.primary)
        }
      }
      .padding(14)
      .glassEffect(.regular, in: .rect(cornerRadius: 22))
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
  }

  /// `labels` are spaced apart as separate texts, with no separator character between them.
  struct Status: Equatable {
    let labels: [String]
    let symbol: String
    let fraction: Double
    var isWorking = false
  }

  private var status: Status? { Self.status(for: model.state) }

  static func status(for state: EpisodeTranscriptModel.State) -> Status? {
    switch state {
    case .generating(let fraction):
      Status(
        labels: ["Transcribing", percent(fraction)], symbol: "waveform", fraction: fraction,
        isWorking: true)
    case .held(.queued, let fraction):
      Status(labels: ["Waiting to start"], symbol: "hourglass", fraction: fraction)
    case .held(.paused, let fraction):
      Status(labels: ["Paused while the iPhone cools"], symbol: "pause.circle", fraction: fraction)
    case .needsAsset(let fraction):
      Status(labels: ["Getting ready"], symbol: "arrow.down.circle", fraction: fraction)
    case .offer(let fraction):
      Status(
        labels: ["Stopped at", percent(fraction)], symbol: "quote.bubble", fraction: fraction)
    case .loading, .unavailable, .ready, .failed: nil
    }
  }
}
