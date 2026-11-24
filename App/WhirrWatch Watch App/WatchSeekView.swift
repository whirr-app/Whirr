import SwiftUI
import WatchPlayback

/// Moves the playhead of the title loaded here. The transport's skip buttons move seconds at a
/// time, and a received RSS episode has no phone to scrub it, so a whole-timeline control is the
/// only way back to the start of a long episode.
///
/// The Digital Crown drives the position rather than a `Slider`: watchOS draws a Slider as a bar
/// with − and + buttons, which reads as volume on this screen, and its drags never reached the
/// existing seek (the `watch-no-position-slider` source rule). The first row takes crown focus, so turning
/// the crown moves the playhead before it can scroll the list.
struct WatchSeekView: View {
  @Environment(WatchLibraryModel.self) private var model
  @Environment(WatchAudioEngine.self) private var audio
  @Environment(\.dismiss) private var dismiss

  /// The position the crown shows. It follows the engine until the listener moves it, then holds
  /// the chosen value until the seek has landed.
  @State private var position: Double = 0
  @State private var isScrubbing = false
  @State private var commitTask: Task<Void, Never>?

  private var duration: Double { audio.duration }
  private var chapterRows: [WatchDisplayFormatting.ChapterRow] {
    WatchDisplayFormatting.chapterRows(audio.chapters, duration: duration, position: position)
  }

  var body: some View {
    List {
      positionSection
      Section {
        Button {
          startOver()
        } label: {
          Label("Start from Beginning", systemImage: "arrow.uturn.backward")
        }
      }
      if chapterRows.isEmpty == false {
        chaptersSection
      }
    }
    .navigationTitle("Seek")
    .onAppear {
      position = WatchSeekPosition.clamped(audio.position, duration: duration)
    }
    .onChange(of: audio.position) { _, newValue in
      // The engine keeps ticking during a seek; its position must not drag the crown back.
      guard isScrubbing == false else { return }
      position = WatchSeekPosition.clamped(newValue, duration: duration)
    }
  }

  private var positionSection: some View {
    Section {
      positionControl
    } footer: {
      Text("Turn the Digital Crown to move.")
    }
  }

  private var positionControl: some View {
    VStack(alignment: .leading, spacing: 6) {
      GeometryReader { geometry in
        Capsule().fill(.white.opacity(0.2))
          .overlay(alignment: .leading) {
            Capsule().fill(WatchVisualStyle.accent)
              .frame(width: geometry.size.width * fraction)
          }
      }
      .frame(height: 6)
      .accessibilityHidden(true)
      HStack(spacing: 4) {
        Text(WatchDisplayFormatting.playerClock(position))
          .accessibilityLabel("\(WatchDisplayFormatting.playerClock(position)) elapsed")
        Spacer(minLength: 4)
        Text("−\(WatchDisplayFormatting.playerClock(remaining))")
          .accessibilityLabel(WatchDisplayFormatting.remaining(remaining))
      }
      .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
    }
    .frame(minHeight: 44)
    .focusable()
    .digitalCrownRotation(
      Binding(get: { position }, set: { move(to: $0) }),
      from: 0, through: max(duration, 1), by: WatchSeekPosition.crownStride(duration: duration),
      sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Position")
    .accessibilityValue(
      "\(WatchDisplayFormatting.playerClock(position)) of \(WatchDisplayFormatting.playerClock(duration))"
    )
    .accessibilityAdjustableAction { direction in
      let step = WatchSeekPosition.crownStride(duration: duration)
      move(to: position + (direction == .increment ? step : -step))
    }
  }

  private var chaptersSection: some View {
    Section {
      // The same list the Audiobookshelf player offers. A received copy carries its chapters
      // from the phone's file metadata, so a podcast with chapters seeks by name here too.
      NavigationLink {
        WatchChapterListView()
      } label: {
        Label("Chapters", systemImage: "list.bullet")
      }
    }
  }

  private var fraction: Double {
    let bounds = WatchSeekPosition.bounds(duration: duration)
    let span = bounds.upperBound - bounds.lowerBound
    guard span > 0 else { return 0 }
    return min(max((position - bounds.lowerBound) / span, 0), 1)
  }

  private var remaining: Double {
    max(0, duration - position)
  }

  /// Moves on the crown's own rhythm: it reports many small changes, and seeking on each one would
  /// restart the player repeatedly. Only the value the listener stops at is sought.
  private func move(to value: Double) {
    let clamped = WatchSeekPosition.clamped(value, duration: duration)
    position = clamped
    isScrubbing = true
    commitTask?.cancel()
    commitTask = Task {
      try? await Task.sleep(for: .milliseconds(300))
      guard Task.isCancelled == false else { return }
      await model.seek(to: clamped)
      // Follow the engine again once the seek has landed, so the bar keeps up with playback.
      isScrubbing = false
    }
  }

  private func startOver() {
    commitTask?.cancel()
    commitTask = nil
    isScrubbing = false
    position = 0
    Task {
      await model.seek(to: 0)
      dismiss()
    }
  }
}
