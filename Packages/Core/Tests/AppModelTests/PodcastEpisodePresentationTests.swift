import Foundation
import Persistence
import Testing

@testable import AppModel

@Suite struct PodcastEpisodePresentationTests {
  @Test("unknown date and duration use centralized copy")
  func unknownValues() {
    let episode = fixture(publishedAt: nil, duration: nil)
    let presentation = PodcastEpisodePresentation(episode: episode)
    #expect(presentation.dateText == PodcastCopy.unknownDate)
    #expect(presentation.durationText == PodcastCopy.unknownDuration)
  }

  @Test("date duration progress and accessibility copy are deterministic")
  func deterministicCombinedCopy() {
    let episode = fixture(
      publishedAt: Date(timeIntervalSince1970: 1_704_067_200),
      duration: 3_661,
      progress: 1_800)
    let presentation = PodcastEpisodePresentation(episode: episode)
    // The literal, not `presentation.dateText`: asserting the label contains its own field is
    // self-referential and holds under any locale, calendar, or time zone the formatter picks up.
    // 1_704_067_200 is 2024-01-01T00:00:00Z; the gregorian/en_US_POSIX/GMT pins make this string
    // the only correct answer on any host.
    #expect(presentation.dateText == "Jan 1, 2024")
    #expect(presentation.durationText == "1 hr 1 min")
    #expect(presentation.progressText == "30 min played")
    #expect(
      presentation.accessibilityLabel
        == "Fixture episode, A subtitle, Jan 1, 2024, 1 hr 1 min, 30 min played")
  }

  @Test("podcast date formatting is shared and stable under the host locale")
  func sharedDateFormattingIsIdenticalAndPOSIXStable() {
    let date = Date(timeIntervalSince1970: 1_704_067_200)
    let episode = fixture(publishedAt: date, duration: 1_200)
    let homeEpisode = HomePodcastEpisode(
      itemID: "show", showTitle: "Fixture show", showAuthor: nil,
      episodeID: "episode", title: "Fixture episode", subtitle: "A subtitle",
      publishedAt: date, durationSeconds: 1_200)

    let episodePresentation = PodcastEpisodePresentation(episode: episode)
    let homePresentation = HomePodcastEpisodePresentation(episode: homeEpisode)

    #expect(episodePresentation.dateText == homePresentation.dateText)
    #expect(episodePresentation.dateText == PodcastCopy.podcastPublishedDate(date))
    // The test host is en_GB rather than en_US_POSIX, where an unpinned medium date is "1 Jan
    // 2024". The shared helper must keep the POSIX result stable.
    #expect(episodePresentation.dateText == "Jan 1, 2024")
  }

  @Test("podcast dates stay pinned across calendar and daylight-saving boundaries")
  func boundaryDatesUseThePinnedGMTCalendar() {
    let dates: [(Date, String)] = [
      (utcDate(year: 2024, month: 1, day: 31), "Jan 31, 2024"),
      (utcDate(year: 2024, month: 2, day: 1), "Feb 1, 2024"),
      (utcDate(year: 2023, month: 12, day: 31), "Dec 31, 2023"),
      (utcDate(year: 2024, month: 1, day: 1), "Jan 1, 2024"),
      // 2024-06-15T23:30:00Z is June 16 in common UTC+ time zones.
      (utcDate(year: 2024, month: 6, day: 15, hour: 23, minute: 30), "Jun 15, 2024"),
      // This is immediately after the 2024 US spring DST transition in New York.
      (utcDate(year: 2024, month: 3, day: 10, hour: 7, minute: 30), "Mar 10, 2024"),
    ]

    for (date, expected) in dates {
      #expect(PodcastCopy.podcastPublishedDate(date) == expected)
    }
  }

  @Test("nonfinite values and finished state never produce misleading numeric copy")
  func nonfiniteValues() {
    let episode = PodcastEpisodeSummary(
      id: "episode", title: "", subtitle: nil, episodeDescription: nil, seasonNumber: nil,
      episodeNumber: nil, episodeType: nil, durationSeconds: .infinity, sizeBytes: nil,
      publishedAt: nil, progressSeconds: .nan, isPlayed: true, isFinished: true,
      downloadStatus: .completed, isAvailableOnServer: true)
    let presentation = PodcastEpisodePresentation(episode: episode)
    #expect(presentation.durationText == PodcastCopy.unknownDuration)
    #expect(presentation.progressText == PodcastCopy.played)
    #expect(presentation.accessibilityLabel.contains(PodcastCopy.untitledEpisode))
    #expect(presentation.accessibilityLabel.contains("nan") == false)
  }

  @Test("a cross-show episode carries the show row's listening state")
  func crossShowEpisodeCarriesListeningState() {
    let presentation = HomePodcastEpisodePresentation(
      episode: homeEpisode(progress: 1_380, isFinished: false))

    #expect(
      presentation.listening
        == PodcastEpisodeListeningState(
          progressSeconds: 1_380, durationSeconds: 3_600, isFinished: false))
  }

  @Test("a displayed position replaces the persisted one in every progress reading")
  func displayedPositionReplacesThePersistedOne() {
    let presentation = HomePodcastEpisodePresentation(
      episode: homeEpisode(progress: 0, isFinished: false), progressSeconds: 1_380)

    #expect(
      presentation.listening
        == PodcastEpisodeListeningState(
          progressSeconds: 1_380, durationSeconds: 3_600, isFinished: false))
    #expect(presentation.accessibilityLabel.hasSuffix("37 min left"))
  }

  @Test("a cross-show episode speaks its progress only once started")
  func crossShowEpisodeSpeaksProgressOnlyWhenStarted() {
    let unplayed = HomePodcastEpisodePresentation(episode: homeEpisode(progress: 0, isFinished: false))
    let started = HomePodcastEpisodePresentation(
      episode: homeEpisode(progress: 1_380, isFinished: false))
    let finished = HomePodcastEpisodePresentation(episode: homeEpisode(progress: 0, isFinished: true))

    #expect(unplayed.accessibilityLabel == "Fixture episode, Fixture show, Jan 1, 2024, 1 hr")
    #expect(
      started.accessibilityLabel
        == "Fixture episode, Fixture show, Jan 1, 2024, 1 hr, 37 min left")
    #expect(
      finished.accessibilityLabel == "Fixture episode, Fixture show, Jan 1, 2024, 1 hr, Played")
  }

  // MARK: - The card row's one time fact

  @Test("an unplayed episode's time line is its duration")
  func unplayedTimeTextIsTheDuration() {
    let presentation = HomePodcastEpisodePresentation(
      episode: homeEpisode(progress: 0, isFinished: false))

    #expect(presentation.timeText == "1 hr")
  }

  @Test("a started episode's time line is what is left, not what was played")
  func startedTimeTextIsTheRemainder() {
    let presentation = HomePodcastEpisodePresentation(
      episode: homeEpisode(progress: 1_380, isFinished: false))

    #expect(presentation.timeText == "37 min left")
  }

  @Test("the remainder is listening time at the show's speed, as the episode sheet says it")
  func remainderFollowsThePlaybackRate() {
    let presentation = HomePodcastEpisodePresentation(
      episode: homeEpisode(progress: 1_380, isFinished: false), playbackRate: 1.5)

    #expect(presentation.timeText == PodcastCopy.remaining(seconds: 2_220, playbackRate: 1.5))
    #expect(presentation.timeText == "24 min left at 1.5×")
  }

  @Test("a finished episode's time line says played")
  func finishedTimeTextSaysPlayed() {
    let presentation = HomePodcastEpisodePresentation(
      episode: homeEpisode(progress: 0, isFinished: true))

    #expect(presentation.timeText == PodcastCopy.played)
  }

  @Test("a started episode of unknown length falls back to what was played")
  func startedWithoutDurationFallsBackToPlayed() {
    let presentation = HomePodcastEpisodePresentation(
      episode: homeEpisode(progress: 1_380, isFinished: false, duration: nil))

    #expect(presentation.timeText == "23 min played")
  }

  private func homeEpisode(
    progress: Double, isFinished: Bool, duration: Double? = 3_600
  ) -> HomePodcastEpisode {
    HomePodcastEpisode(
      itemID: "show", showTitle: "Fixture show", showAuthor: nil,
      episodeID: "episode", title: "Fixture episode", subtitle: nil,
      publishedAt: Date(timeIntervalSince1970: 1_704_067_200), durationSeconds: duration,
      progressSeconds: progress, isFinished: isFinished)
  }

  private func fixture(
    publishedAt: Date?,
    duration: Double?,
    progress: Double = 0
  ) -> PodcastEpisodeSummary {
    PodcastEpisodeSummary(
      id: "episode", title: "Fixture episode", subtitle: "A subtitle",
      episodeDescription: nil, seasonNumber: nil, episodeNumber: nil, episodeType: nil,
      durationSeconds: duration, sizeBytes: nil, publishedAt: publishedAt,
      progressSeconds: progress, isPlayed: progress > 0, isFinished: false,
      downloadStatus: .notDownloaded, isAvailableOnServer: true)
  }

  private func utcDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int = 0,
    minute: Int = 0
  ) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(
      from: DateComponents(
        calendar: calendar, timeZone: calendar.timeZone,
        year: year, month: month, day: day, hour: hour, minute: minute))!
  }
}
