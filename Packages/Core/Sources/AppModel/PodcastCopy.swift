import Foundation
import Persistence

public enum PodcastCopy {
  public static let unknownDate = "Date unknown"
  public static let unknownDuration = "Duration unknown"
  public static let notPlayed = "Not played"
  public static let played = "Played"
  public static let untitledEpisode = "Untitled episode"
  public static let actionFailed = "Couldn't complete that episode action. Try again."
  public static let unsubscribeFailed = "Couldn't unsubscribe. Try again."
  public static let unsubscribePlaybackStopFailed =
    "Playback couldn't be stopped. Stop playback, then try to unfollow again."
  public static let availableOnServer = "Available on server"
  public static let unavailableOnServer = "Unavailable on server"
  public static let autoDownloadOn = "Server auto-download on"
  public static let autoDownloadOff = "Server auto-download off"

  public static func lastChecked(_ relativeDate: String) -> String {
    "Last checked \(relativeDate)"
  }

  /// "Last checked 2 hours ago", formatted once so every footer agrees.
  public static func lastCheckedSentence(_ date: Date, now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.unitsStyle = .full
    return lastChecked(formatter.localizedString(for: date, relativeTo: now))
  }

  private static let dateFormatStyle: Date.FormatStyle = {
    var style = Date.FormatStyle()
      .year(.defaultDigits)
      .month(.abbreviated)
      .day(.defaultDigits)
      .locale(Locale(identifier: "en_US_POSIX"))
    style.calendar = Calendar(identifier: .gregorian)
    style.timeZone = TimeZone(secondsFromGMT: 0)!
    return style
  }()

  /// Every absolute episode date surface: published dates on Home, detail, Search, Downloads and
  /// the Watch. Pinned to POSIX/GMT so one instant renders one calendar day everywhere; grouping by
  /// local day stays `dayHeading(for:now:calendar:)`.
  public static func podcastPublishedDate(_ date: Date) -> String {
    date.formatted(dateFormatStyle)
  }

  public static let today = "Today"
  public static let yesterday = "Yesterday"

  /// The heading an episode list files `date` under, in the listener's own calendar: "Today",
  /// "Yesterday", a weekday name for the rest of the past week, then the date (with its year
  /// only when that differs from now's). A feed's clock running ahead files under today rather than
  /// a heading from the future.
  public static func dayHeading(for date: Date, now: Date, calendar: Calendar) -> String {
    let day = calendar.startOfDay(for: date)
    let today = calendar.startOfDay(for: now)
    let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
    switch daysAgo {
    case ...0: return Self.today
    case 1: return Self.yesterday
    case 2...6: return date.formatted(dayHeadingStyle(calendar).weekday(.wide))
    default:
      var style = dayHeadingStyle(calendar).month(.abbreviated).day(.defaultDigits)
      if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
        style = style.year(.defaultDigits)
      }
      return date.formatted(style)
    }
  }

  private static func dayHeadingStyle(_ calendar: Calendar) -> Date.FormatStyle {
    var style = Date.FormatStyle(date: .omitted, time: .omitted)
      .locale(Locale(identifier: "en_US_POSIX"))
    style.calendar = calendar
    style.timeZone = calendar.timeZone
    return style
  }

  public static func duration(seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds > 0 else { return unknownDuration }
    return DurationText.long(seconds)
  }

  public static func progress(seconds: Double, isFinished: Bool) -> String {
    if isFinished { return played }
    guard seconds.isFinite, seconds > 0 else { return notPlayed }
    return "\(duration(seconds: seconds)) played"
  }

  /// The episode card's remaining-time line, e.g. "12 min left", in `duration(seconds:)`'s shape.
  /// The input is media seconds; the helper converts it to listening seconds first, and names the
  /// rate whenever it is not 1×.
  public static func remaining(seconds: Double, playbackRate: Double = 1.0) -> String {
    let listening = listeningSeconds(seconds, playbackRate: playbackRate)
    // Nothing left is a real answer here, unlike an unknown length: ad subtraction can reach it.
    let text = listening > 0 ? "\(duration(seconds: listening)) left" : "0 min left"
    return text + rateSuffix(playbackRate)
  }

  /// The spoken form of `remaining(seconds:playbackRate:)`: same figure, with the rate read as
  /// words so VoiceOver never says "×".
  public static func spokenRemaining(seconds: Double, playbackRate: Double = 1.0) -> String {
    let listening = listeningSeconds(seconds, playbackRate: playbackRate)
    let text = listening > 0 ? "\(duration(seconds: listening)) left" : "0 min left"
    return text + spokenRateSuffix(playbackRate)
  }

  private static func listeningSeconds(_ seconds: Double, playbackRate: Double) -> Double {
    ItemDetailDurationPresentation.remainingSeconds(
      durationSeconds: seconds, progressSeconds: 0, playbackRate: playbackRate) ?? seconds
  }

  private static func rateSuffix(_ playbackRate: Double) -> String {
    let rate = ItemDetailDurationPresentation.normalizedPlaybackRate(playbackRate)
    guard rate != 1 else { return "" }
    return " at \(PlaybackRateCopy.display(rate))"
  }

  private static func spokenRateSuffix(_ playbackRate: Double) -> String {
    let rate = ItemDetailDurationPresentation.normalizedPlaybackRate(playbackRate)
    guard rate != 1 else { return "" }
    return " at \(PlaybackRateCopy.spoken(rate))"
  }

  /// The card's primary action, named as a verb alone: "Play" when untouched, "Resume" once
  /// partway through. The remainder belongs to `metadataLine`, beside the progress bar.
  public static let play = "Play"
  public static let resume = "Resume"

  /// The same button while playing (`PodcastEpisodeCardPlayControl`). Names the tap, not the
  /// state. No remainder keeps the label one width across a play/pause tap, so the row's
  /// satellites do not shift.
  public static let pause = "Pause"

  public static func state(_ state: PodcastShowModel.State) -> String {
    switch state {
    case .loading: "Loading episodes…"
    case .empty: "No episodes are cached yet."
    case .loaded: ""
    case .refreshing: "Refreshing episodes…"
    case .staleOffline: "Showing cached episodes. We can't reach the server right now."
    case .recoverableError: "Couldn't load episodes. Check your connection and try again."
    case .partiallyDecoded: "Some episode information couldn't be loaded."
    }
  }
}

public struct PodcastEpisodePresentation: Sendable, Equatable {
  public let dateText: String
  public let durationText: String
  public let progressText: String
  public let accessibilityLabel: String

  public init(episode: PodcastEpisodeSummary) {
    dateText = episode.publishedAt.map(PodcastCopy.podcastPublishedDate) ?? PodcastCopy.unknownDate
    durationText = PodcastCopy.duration(seconds: episode.durationSeconds)
    progressText = PodcastCopy.progress(
      seconds: episode.progressSeconds, isFinished: episode.isFinished)
    accessibilityLabel = [
      episode.title.isEmpty ? PodcastCopy.untitledEpisode : episode.title,
      episode.subtitle,
      dateText,
      durationText,
      progressText,
    ].compactMap { $0 }.joined(separator: ", ")
  }
}
