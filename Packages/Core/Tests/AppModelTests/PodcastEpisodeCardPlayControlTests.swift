import Foundation
import Persistence
import Testing

@testable import AppModel

@Suite struct PodcastEpisodeCardPlayControlTests {
  @Test("an episode that is not the loaded one offers Play whatever the player is doing")
  func anEpisodeThatIsNotLoadedOffersPlay() {
    for isPlaybackIntended in [true, false] {
      let control = PodcastEpisodeCardPlayControl.resolve(
        isCurrentEpisode: false, isPlaybackIntended: isPlaybackIntended)

      #expect(control == .start)
      #expect(control.systemImage == "play.fill")
    }
  }

  @Test("the loaded episode playing names the tap")
  func theLoadedPlayingEpisodePauses() {
    let control = PodcastEpisodeCardPlayControl.resolve(
      isCurrentEpisode: true, isPlaybackIntended: true)

    #expect(control == .pause)
    // The glyph names the tap alongside the label, rather than reporting playback status.
    #expect(control.systemImage == "pause.fill")
    #expect(control.label(for: Self.presentation(progressSeconds: 1_080)) == PodcastCopy.pause)
    #expect(control.label(for: Self.presentation(progressSeconds: 0)) == PodcastCopy.pause)
  }

  @Test("the loaded episode paused offers the Resume label back")
  func theLoadedPausedEpisodeResumes() {
    let presentation = Self.presentation(progressSeconds: 1_080)
    let control = PodcastEpisodeCardPlayControl.resolve(
      isCurrentEpisode: true, isPlaybackIntended: false)

    #expect(control == .resume)
    #expect(control.systemImage == "play.fill")
    #expect(control.label(for: presentation) == PodcastCopy.resume)
  }

  @Test("the play/pause labels keep one width across a tap, at every progress and rate")
  func theLabelsAreStableAcrossATap() {
    let presentation = Self.presentation(progressSeconds: 1_080)

    // The satellites sit against this button; a label that grew or shrank on tap would shift
    // them under the thumb that had just pressed it.
    #expect(PodcastEpisodeCardPlayControl.pause.label(for: presentation) == "Pause")
    #expect(
      PodcastEpisodeCardPlayControl.pause.label(for: presentation.adjusted(forPlaybackRate: 1.5))
        == "Pause")
    #expect(PodcastEpisodeCardPlayControl.resume.label(for: presentation) == "Resume")
    #expect(
      PodcastEpisodeCardPlayControl.resume.label(for: presentation.adjusted(forPlaybackRate: 1.5))
        == "Resume")
  }

  @Test("start and resume both defer to the presentation's own play label")
  func startAndResumeUseThePresentationLabel() {
    let unstarted = Self.presentation(progressSeconds: 0)
    let partPlayed = Self.presentation(progressSeconds: 1_080)

    for control in [PodcastEpisodeCardPlayControl.start, .resume] {
      #expect(control.label(for: unstarted) == PodcastCopy.play)
      #expect(control.label(for: partPlayed) == partPlayed.playButtonLabel)
    }
  }

  /// The morph is a label/glyph swap inside one capsule, so the two non-playing states must be
  /// visually identical. Only the action differs (a fresh session vs. a resume).
  @Test("start and resume differ only in the action, never in what is drawn")
  func startAndResumeAreVisuallyIdentical() {
    let presentation = Self.presentation(progressSeconds: 1_080)

    #expect(
      PodcastEpisodeCardPlayControl.start.label(for: presentation)
        == PodcastEpisodeCardPlayControl.resume.label(for: presentation))
    #expect(
      PodcastEpisodeCardPlayControl.start.systemImage
        == PodcastEpisodeCardPlayControl.resume.systemImage)
    #expect(PodcastEpisodeCardPlayControl.start.startsNewSession)
    #expect(PodcastEpisodeCardPlayControl.resume.startsNewSession == false)
    #expect(PodcastEpisodeCardPlayControl.pause.startsNewSession == false)
  }

  private static func presentation(
    progressSeconds: Double = 0,
    durationSeconds: Double? = 1_800
  ) -> PodcastEpisodeCardPresentation {
    PodcastEpisodeCardPresentation(
      context: PodcastEpisodeContext(
        episode: PodcastEpisodeSummary(
          id: "episode", title: "Episode", subtitle: "Subtitle",
          episodeDescription: nil,
          seasonNumber: nil, episodeNumber: nil, episodeType: nil,
          durationSeconds: durationSeconds, sizeBytes: nil, publishedAt: nil,
          progressSeconds: progressSeconds, isPlayed: false, isFinished: false,
          downloadStatus: .notDownloaded, isAvailableOnServer: true),
        showTitle: "The Rest Is Politics: US", showAuthor: "Goalhanger",
        artworkURL: nil, artworkFeedURL: nil))
  }
}
