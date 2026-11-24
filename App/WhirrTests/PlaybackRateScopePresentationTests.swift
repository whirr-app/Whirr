import Testing

@testable import Whirr

/// The wording is the speed controls' discoverability: the card pins one title, Settings holds the
/// default, and this copy tells a listener which is which.
@Suite("Playback rate scope presentation")
struct PlaybackRateScopePresentationTests {

  @Test("an episode id is what makes a scope a show rather than a book")
  func kindFollowsEpisodeIdentity() {
    #expect(PlaybackRateScopePresentation.Kind.resolve(episodeID: nil) == .book)
    #expect(PlaybackRateScopePresentation.Kind.resolve(episodeID: "episode-1") == .show)
  }

  // MARK: - The card header

  @Test("the menu names one title, because that is the only thing its presets can write")
  func menuHeaderAlwaysNamesTheTitle() {
    #expect(PlaybackRateScopePresentation.menuHeader(kind: .book) == "Speed for This Book")
    #expect(PlaybackRateScopePresentation.menuHeader(kind: .show) == "Speed for This Show")
  }

  // MARK: - A Focus in charge

  @Test("the menu says when a Focus is setting the speed")
  func menuHeaderNamesTheFocus() {
    #expect(
      PlaybackRateScopePresentation.menuHeader(kind: .book, focusRate: 0.9) == "Speed Set by Focus")
    #expect(
      PlaybackRateScopePresentation.menuHeader(kind: .show, focusRate: nil) == "Speed for This Show")
  }

  @Test("Settings › Playback mentions Focus filters in its existing footer")
  func defaultSpeedFooterMentionsFocus() {
    #expect(
      PlaybackRateScopePresentation.defaultSpeedFooter
        == "Used by titles without their own speed. A Focus filter can change the speed while that Focus is on."
    )
  }

  @Test("the filter's summary in Settings › Focus")
  func focusFilterSummary() {
    #expect(PlaybackSpeedFocusFilterCopy.summary(rate: 0.9, skipsTitlesWithOwnSpeed: nil) == "0.9×")
    #expect(PlaybackSpeedFocusFilterCopy.summary(rate: 0.9, skipsTitlesWithOwnSpeed: false) == "0.9×")
    #expect(
      PlaybackSpeedFocusFilterCopy.summary(rate: 0.9, skipsTitlesWithOwnSpeed: true)
        == "0.9× · Keeps custom speeds")
    #expect(PlaybackSpeedFocusFilterCopy.summary(rate: nil, skipsTitlesWithOwnSpeed: true) == "No changes")
    #expect(
      PlaybackSpeedFocusFilterCopy.summary(rate: 0.9, skipsTitlesWithOwnSpeed: nil, trim: .off)
        == "0.9× · Trim off")
    #expect(
      PlaybackSpeedFocusFilterCopy.summary(rate: 0.9, skipsTitlesWithOwnSpeed: true, trim: .low)
        == "0.9× · Keeps custom speeds · Trim low")
    #expect(
      PlaybackSpeedFocusFilterCopy.summary(
        rate: nil, skipsTitlesWithOwnSpeed: nil, trim: .high, keepsCustomTrim: true)
        == "Trim high · Keeps custom trim")
    #expect(
      PlaybackSpeedFocusFilterCopy.summary(rate: nil, skipsTitlesWithOwnSpeed: nil, keepsCustomTrim: true)
        == "No changes")
    #expect(
      PlaybackSpeedFocusFilterCopy.summary(
        rate: 0.9, skipsTitlesWithOwnSpeed: nil, trim: .off, sleepTimer: .m30)
        == "0.9× · Trim off · Sleep timer 30 min")
    #expect(
      PlaybackSpeedFocusFilterCopy.summary(rate: nil, skipsTitlesWithOwnSpeed: nil, sleepTimer: .m5)
        == "Sleep timer 5 min")
  }

  // MARK: - Settings → Playback's default row

  @Test("the default-speed choices are the listener's shortcuts, with no inherit entry")
  func defaultSpeedChoicesAreTheShortcuts() {
    let presets = PlaybackRatePresetConfiguration(rates: [1, 1.25, 1.5]).encoded

    #expect(
      PlaybackRateScopePresentation.defaultSpeedChoices(
        encodedPresets: presets, currentRate: 1.25) == [1, 1.25, 1.5])
  }

  @Test("a default fine-tuned outside the shortcuts still has a row to select")
  func defaultSpeedChoicesCarryAnOffPresetDefault() {
    let presets = PlaybackRatePresetConfiguration(rates: [1, 1.25, 1.5]).encoded

    #expect(
      PlaybackRateScopePresentation.defaultSpeedChoices(
        encodedPresets: presets, currentRate: 1.35) == [1, 1.25, 1.5, 1.35])
  }

  // MARK: - Show Settings

  @Test("the show speed menu leads with inherit and names the value being inherited")
  func showSpeedChoicesLeadWithInherit() {
    let choices = PlaybackRateScopePresentation.showSpeedChoices(
      encodedPresets: "1,1.5,2", currentRate: nil)

    #expect(choices == [nil, 1, 1.5, 2])
    #expect(
      PlaybackRateScopePresentation.showSpeedLabel(nil, defaultRate: 1.5) == "Default (1.5×)")
    #expect(PlaybackRateScopePresentation.showSpeedLabel(1.8, defaultRate: 1.5) == "1.8×")
  }

  /// A show set to a non-preset speed in the player must still show it here. Without the trailing
  /// entry the picker has no row to select and would read as inheriting.
  @Test("a show's own non-preset speed is offered so it can be displayed at all")
  func showSpeedChoicesCarryANonPresetCurrentValue() {
    #expect(
      PlaybackRateScopePresentation.showSpeedChoices(encodedPresets: "1,1.5,2", currentRate: 1.35)
        == [nil, 1, 1.5, 2, 1.35])
    // Already a preset: offered once, not twice.
    #expect(
      PlaybackRateScopePresentation.showSpeedChoices(encodedPresets: "1,1.5,2", currentRate: 1.5)
        == [nil, 1, 1.5, 2])
  }
}
