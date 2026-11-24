import AppModel
import Persistence
import SwiftUI

/// Pure copy derivation for the item-detail play control. Keeping the time arithmetic out of the
/// SwiftUI view makes the compact label deterministic while the live view supplies the current or
/// retained playback position.
enum ItemDetailPlayButtonPresentation {
  /// How the primary control carries its own play/pause change. The first tap on a cold title
  /// starts a session asynchronously, so the resulting state lands outside the tap's transaction
  /// and would snap, while a second tap (a synchronous toggle) rides the button style's press
  /// animation. Declaring the transition here makes both taps look the same.
  nonisolated enum Motion: Equatable {
    case animated
    case reduced

    var controlAnimation: Animation? {
      switch self {
      case .animated: .snappy(duration: 0.28)
      case .reduced: nil
      }
    }

    var textTransition: ContentTransition {
      switch self {
      case .animated: .interpolate
      case .reduced: .identity
      }
    }

    var symbolTransition: ContentTransition {
      switch self {
      case .animated: .symbolEffect(.replace)
      case .reduced: .identity
      }
    }
  }

  nonisolated static func motion(reduceMotion: Bool) -> Motion {
    reduceMotion ? .reduced : .animated
  }

  /// Whether the control should act on a tap. A cold first tap spends a moment in `.preparing`,
  /// and a second tap during it would start the same session twice.
  ///
  /// Not `.disabled`: under `.glassProminent` that drops the fill and tint, so the button blinks
  /// out for a few frames. Refusing the tap keeps the chrome.
  nonisolated static func acceptsTap(phase: PlaybackModel.Phase, isActive: Bool) -> Bool {
    (phase == .preparing && isActive) == false
  }

  /// The control's verb and, for a title nobody has started, its runtime. A finished title is
  /// offered as a new listen from the beginning rather than as a resume.
  ///
  /// Only `Play` carries the runtime; once there is a playhead the remainder is `remainingLabel`'s,
  /// so the label keeps one width as the playhead moves. `unstartedDurationText` is gated by the
  /// caller (`ItemDetailDurationPresentation.showsDuration`): `nil` for an ebook or unknown
  /// runtime gives the bare verb.
  static func label(
    isActive: Bool,
    isPlaying: Bool,
    positionSeconds: Double,
    isFinished: Bool,
    durationSeconds: Double?,
    playbackRate: Double = 1.0,
    unstartedDurationText: String? = nil
  ) -> String {
    if isPlaying { return "Pause" }
    if isFinished { return "Play Again" }
    if isActive || positionSeconds > 0 { return "Resume" }
    guard let unstartedDurationText, unstartedDurationText.isEmpty == false else { return "Play" }
    return "Play · \(unstartedDurationText)"
  }

  static func symbolName(isPlaying: Bool, isFinished: Bool) -> String {
    if isPlaying { return "pause.fill" }
    if isFinished { return "arrow.counterclockwise" }
    return "play.fill"
  }

  /// The playhead the detail page prints for `item`: the live player position while this title is
  /// the loaded one, the last displayed bookmark while it is merely the displayed one, and the
  /// synced row's progress otherwise. Resolved here once so the play button and the stat line
  /// (the page's two live-playhead readers) cannot drift apart.
  static func displayedPositionSeconds(item: ItemSummary, playback: PlaybackModel) -> Double {
    playback.listPositionSeconds(
      itemID: item.serverItemId, episodeID: nil, persisted: item.progressSeconds)
  }

  /// The hero's stat line lead, present when the bar is: the remainder of a part-played title. An
  /// unstarted title has no stat (its runtime rides on the Play verb) and a finished one is told
  /// by the artwork's badge. The total lives in Details in every state.
  static func heroStatLead(
    positionSeconds: Double,
    durationSeconds: Double?,
    isFinished: Bool,
    playbackRate: Double = 1.0
  ) -> String? {
    guard isFinished == false else { return nil }
    return remainingLabel(
      positionSeconds: positionSeconds, durationSeconds: durationSeconds,
      playbackRate: playbackRate)
  }

  /// The fill fraction for the detail progress bar, present only while the title is genuinely
  /// part-played: `0 < fraction < 1`. Unstarted, finished, overrun, and unknown-duration titles all
  /// render no bar, the same policy `PodcastEpisodeCardPresentation.remainingProgressFraction`
  /// applies to the episode card.
  nonisolated static func progressFraction(
    positionSeconds: Double,
    durationSeconds: Double?,
    isFinished: Bool
  ) -> Double? {
    guard isFinished == false else { return nil }
    guard let durationSeconds, durationSeconds > 0 else { return nil }
    let fraction = positionSeconds / durationSeconds
    guard fraction > 0, fraction < 1 else { return nil }
    return fraction
  }

  /// Nil below a whole percent: "0% complete" states nothing, and a title reads that for its first
  /// several minutes. The bar already shows where the reader is, and the remainder beside it how
  /// much is left.
  nonisolated static func progressPercentLabel(fraction: Double) -> String? {
    let clamped = fraction.isNaN ? 0 : min(max(fraction, 0), 1)
    let percent = Int((clamped * 100).rounded())
    guard percent > 0 else { return nil }
    return "\(percent)% complete"
  }

  static func ebookRemainingLabel(
    for state: ReadAffordanceState, isFinished: Bool
  ) -> String? {
    guard isFinished == false else { return nil }
    return ReaderDetailCopy.detailReadingRemaining(for: state)
  }

  static func ebookProgressFraction(
    for state: ReadAffordanceState, isFinished: Bool
  ) -> Double? {
    guard isFinished == false else { return nil }
    return ReaderDetailCopy.detailReadingFraction(for: state)
  }

  /// "3 hrs, 20 min left": the remainder, gated on `progressFraction` so the figure and the bar
  /// appear and disappear together.
  static func remainingLabel(
    positionSeconds: Double,
    durationSeconds: Double?,
    playbackRate: Double = 1.0
  ) -> String? {
    guard
      progressFraction(
        positionSeconds: positionSeconds, durationSeconds: durationSeconds, isFinished: false)
        != nil,
      let remainingSeconds = ItemDetailDurationPresentation.remainingSeconds(
        durationSeconds: durationSeconds, progressSeconds: positionSeconds,
        playbackRate: playbackRate)
    else { return nil }

    let totalMinutes = Int((remainingSeconds / 60).rounded())
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60

    let time: String =
      if hours > 0, minutes > 0 {
        "\(hours) \(hours == 1 ? "hr" : "hrs"), \(minutes) min"
      } else if hours > 0 {
        "\(hours) \(hours == 1 ? "hr" : "hrs")"
      } else {
        "\(minutes) min"
      }

    return "\(time) left"
  }
}
