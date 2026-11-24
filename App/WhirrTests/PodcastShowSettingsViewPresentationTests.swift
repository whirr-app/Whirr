import AppModel
import Persistence
import Testing

@testable import Whirr

/// Model-level behaviour is pinned by `PodcastShowSettingsModelTests` in Core. These tests pin what
/// `PodcastShowSettingsView` itself commits to: the tri-state pickers' exact option sets, that the
/// read-only server section is never merged with the editable override sections, and that the
/// not-found state has explicit copy rather than a bare "Error".
@Suite("Podcast show settings presentation")
struct PodcastShowSettingsViewPresentationTests {
  @Test("Private feed credentials use explicit secure-storage copy")
  func privateFeedCredentialCopy() {
    #expect(PodcastShowSettingsViewPresentation.privateFeedFooter.contains("Keychain"))
    #expect(PodcastShowSettingsViewPresentation.privateFeedFooter.contains("URL") == false)
  }

  @Test("RSS show settings expose the Latest Episodes inclusion copy")
  func latestEpisodesInclusionCopy() {
    #expect(PodcastShowSettingsViewPresentation.includeInLatestFooter.contains("Home"))
    #expect(PodcastShowSettingsViewPresentation.includeInLatestFooter.contains("Podcasts"))
  }

  /// Every show says where it comes from, under a header distinct from the server section's.
  @Test func sourceHeaderIsDistinctFromTheServerHeader() {
    #expect(
      PodcastShowSourcePresentation.sectionHeader
        != PodcastShowSettingsViewPresentation.serverSectionHeader)
  }

  /// Tri-state by construction. A two-state toggle would pin every show on first render and make
  /// the global default decorative. Only Default, On and Off.
  @Test func showOverrideOffersExactlyDefaultOnOff() {
    #expect(
      PodcastShowSettingsViewPresentation.autoDownloadOverrideChoices == [
        .inherit, .enabled, .disabled,
      ])

    let labels = PodcastShowSettingsViewPresentation.autoDownloadOverrideChoices.map {
      PodcastDownloadCopy.autoDownloadOverrideLabel($0, effectiveIsEnabled: true)
    }
    #expect(labels == ["Default (On)", "On", "Off"])
    #expect(Set(labels).count == 3, "each choice reads distinctly")
  }

  /// The show-level Keep Latest picker offers the same five counts as the global screen, plus a
  /// leading "inherit the default" choice.
  @Test func keepLatestOffersTheNamedChoices() {
    #expect(
      PodcastShowSettingsViewPresentation.keepLatestOverrideChoices == [nil, 1, 3, 5, 10, 0])
  }

  /// The server diagnostic (the server's own RSS auto-download setting, a fact) must never
  /// visually merge with the editable override rows above it. One reads as a fact and the other
  /// as a control, so the sections need distinct identities.
  @Test func showSettingsKeepsServerStatusSeparate() {
    let serverHeader = PodcastShowSettingsViewPresentation.serverSectionHeader
    #expect(serverHeader == "Audiobookshelf Server")
    #expect(serverHeader.contains("Server"))
    // The override rows' own labels never claim to be the server section.
    for override in PodcastShowSettingsViewPresentation.autoDownloadOverrideChoices {
      let label = PodcastDownloadCopy.autoDownloadOverrideLabel(override, effectiveIsEnabled: true)
      #expect(label != serverHeader)
    }
  }

  /// A show that has vanished (removed from the library, soft-deleted, or never synced) gets copy
  /// that says what happened. A bare "Error" or "Not Found" leaves the user guessing why the screen
  /// is empty.
  @Test func showSettingsNotFoundCopyIsExplicit() {
    let title = PodcastShowSettingsViewPresentation.notFoundTitle
    let message = PodcastDownloadCopy.showSettingsNotFound

    #expect(title.isEmpty == false)
    #expect(title != "Error")
    #expect(title != "Not Found")
    #expect(message == "This show is no longer available.")
  }
}
