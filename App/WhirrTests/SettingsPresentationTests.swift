import AppModel
import Persistence
import SwiftUI
import SyncEngine
import Testing

@testable import Whirr

@Suite("Settings presentation")
struct SettingsPresentationTests {

  @Test("regular Settings uses fitted form sizing and compact Settings uses large")
  func regularSettingsUsesFittedFormAndCompactUsesLarge() throws {
    #expect(SheetViewPresentation.mode(for: .compact, role: .large) == .compactLarge)
    #expect(SheetViewPresentation.mode(for: .regular, role: .large) == .regularForm)
    #expect(SheetViewPresentation.mode(for: nil, role: .large) == .compactLarge)

    let text = try ViewSourceScan.libraryShellText()
    let settingsHost = try #require(
      Self.sheetHostWindows(in: text).first { $0.contains("SettingsView(") })
    #expect(settingsHost.contains("settingsPresentationBinding"))
    #expect(settingsHost.contains("root.finishSettingsPresentation()"))
    #expect(settingsHost.contains(".adaptiveSheetPresentation(role: .large)"))

    let modifierText = try ViewSourceScan.executableText(
      ofFileNamed: "SheetViewPresentationModifiers.swift")
    // Plain `.form`. Fitting a settings form to its ideal height collapses it, because a
    // scrolling form's ideal height is one row.
    #expect(modifierText.contains(".presentationSizing(.form)"))
    #expect(
      modifierText.contains(
        ".presentationSizing(.form.fitted(horizontal: false, vertical: true))") == false)
    #expect(modifierText.contains(".presentationDragIndicator(.hidden)"))
  }

  @Test("settings scopes its scheme to sheet content so interactive dismissal keeps the host stable")
  func colorSchemeDoesNotPublishThroughThePresentationHost() {
    #expect(SettingsViewPresentation.colorSchemeScope == .contentEnvironment)
  }

  /// The environment value repaints the form but never reaches the navigation bar, which is
  /// UIKit: after Light then Dark the title and close button stayed light on a dark sheet.
  @Test("settings hands its scheme to the navigation bar as well as the content")
  func navigationBarFollowsTheChosenScheme() throws {
    let text = try ViewSourceScan.executableText(ofViewNamed: "SettingsView")
    #expect(text.contains(".toolbarColorScheme(contentColorScheme, for: .navigationBar)"))
    #expect(text.contains(".environment(\\.colorScheme, contentColorScheme)"))
  }

  /// The footer's counts and the shared file were made when the screen opened; a restore left
  /// both describing the empty library it replaced.
  @Test("a finished restore prepares the backup again")
  func restoreRefreshesTheExport() throws {
    let text = try ViewSourceScan.executableText(ofViewNamed: "PodcastBackupsSettingsView")
    let confirm = try #require(text.range(of: "await restore.confirm()"))
    #expect(text[confirm.upperBound...].prefix(120).contains("await backup.prepareExport()"))
  }

  @Test("settings includes local playback shortcuts alongside the self-hoster essentials")
  func settingsKeepsOnlyUsefulSelfHosterSections() {
    #expect(
      SettingsSection.allCases
        == [.appearance, .destinations, .about])
  }

  /// The rows that push a sub-screen share one unheaded group. Each row already names its
  /// destination, and iOS Settings does not repeat that name as a header.
  @Test func destinationRowsShareOneUnheadedGroup() {
    #expect(SettingsSection.destinations.header == nil)
    #expect(
      SettingsDestination.allCases
        == [
          .homeScreen, .playback, .podcasts, .reduceAds, .downloads, .appleWatch,
          .libraries, .serverAccount,
        ])
  }

  /// Reduce Ads analyses downloaded podcast episodes in the background, so it sits as a root row
  /// beside Podcasts. Playback holds the controls that apply to books and podcasts alike.
  @Test func reduceAdsFollowsPodcasts() throws {
    let destinations = SettingsDestination.allCases
    let podcastsIndex = try #require(destinations.firstIndex(of: .podcasts))
    #expect(destinations[podcastsIndex + 1] == .reduceAds)
  }

  @Test("Apple Watch follows Downloads, and Libraries follows Apple Watch")
  func managementDestinationsFollowDownloads() throws {
    let destinations = SettingsDestination.allCases
    let downloadsIndex = try #require(destinations.firstIndex(of: .downloads))
    let librariesIndex = try #require(destinations.firstIndex(of: .libraries))
    let watchIndex = try #require(destinations.firstIndex(of: .appleWatch))

    #expect(watchIndex == downloadsIndex + 1)
    #expect(librariesIndex == watchIndex + 1)
  }

  /// The Podcasts destination greys out only on the same positive evidence that hides the Podcasts
  /// tab: a selection snapshot proving no accessible, included podcast library remains. `nil`
  /// (still loading) keeps the row enabled, so missing evidence never greys it out.
  @Test func podcastsDestinationDisablesOnlyOnProvenPodcastAbsence() {
    #expect(
      SettingsViewPresentation.isPodcastsDestinationEnabled(
        snapshot: nil, nativeSubscriptionsEnabled: false))
    #expect(
      SettingsViewPresentation.isPodcastsDestinationEnabled(
        snapshot: LibrarySelectionSnapshot(
          mode: .selected,
          libraries: [
            SelectableLibrary(
              serverLibraryID: "pods", name: "Podcasts", mediaType: "podcast",
              isAccessible: true, isIncluded: true)
          ]), nativeSubscriptionsEnabled: false))
    #expect(
      SettingsViewPresentation.isPodcastsDestinationEnabled(
        snapshot: LibrarySelectionSnapshot(
          mode: .selected,
          libraries: [
            SelectableLibrary(
              serverLibraryID: "books", name: "Books", mediaType: "book",
              isAccessible: true, isIncluded: true),
            SelectableLibrary(
              serverLibraryID: "pods", name: "Podcasts", mediaType: "podcast",
              isAccessible: true, isIncluded: false),
          ]), nativeSubscriptionsEnabled: false) == false)
    #expect(
      SettingsViewPresentation.isPodcastsDestinationEnabled(
        snapshot: LibrarySelectionSnapshot(
          mode: .selected,
          libraries: [
            SelectableLibrary(
              serverLibraryID: "pods", name: "Podcasts", mediaType: "podcast",
              isAccessible: false, isIncluded: true)
          ]), nativeSubscriptionsEnabled: false) == false)
    #expect(
      SettingsViewPresentation.isPodcastsDestinationEnabled(
        snapshot: LibrarySelectionSnapshot(
          mode: .selected,
          libraries: [
            SelectableLibrary(
              serverLibraryID: "books", name: "Books", mediaType: "book",
              isAccessible: true, isIncluded: true)
          ]), nativeSubscriptionsEnabled: true))
  }

  /// Downloads holds a screen's worth of content, too much for a single-line row in the root list.
  @Test func downloadsIsAPushedDestination() {
    #expect(SettingsDestination.allCases.contains(.downloads))
    #expect(
      SettingsSection.allCases.contains(where: { $0.header == SettingsCopy.downloadsRowTitle })
        == false)
  }

  /// The row that pushes the downloaded-items list sits on the Downloads screen, so it must not
  /// repeat that screen's title.
  @Test func downloadsScreenDoesNotRepeatItsTitleOnItsOwnRow() {
    #expect(SettingsCopy.manageDownloadsRowTitle != SettingsCopy.downloadsRowTitle)
    #expect(SettingsCopy.downloadsRowDetail.contains(SettingsCopy.downloadsRowTitle) == false)
  }

  /// Podcast auto-download policy keeps its own row rather than folding into `.downloads`. Policy
  /// ("what to fetch automatically") is separate from the manual-download opt-ins `.downloads`
  /// holds.
  @Test func settingsDestinationsIncludePodcasts() {
    #expect(SettingsDestination.allCases.contains(.podcasts))
  }

  @Test func settingsDestinationsIncludeServerAccount() {
    #expect(SettingsDestination.allCases.contains(.serverAccount))
  }

  @Test("the Home destination explains itself without repeating its own title")
  func homeScreenDestinationCopyIsNotRedundant() {
    #expect(
      SettingsCopy.homeScreenRowDetail.contains(SettingsCopy.homeScreenRowTitle) == false)
  }

  @Test("destination descriptions stay short enough for one line")
  func destinationDescriptionsAreConcise() {
    let details = [
      SettingsCopy.homeScreenRowDetail,
      SettingsCopy.playbackRowDetail,
      SettingsCopy.podcastsRowDetail,
      SettingsCopy.downloadsRowDetail,
      ServerAccountSettingsCopy.destinationDetail,
      ProblemReportCopy.rowDetail,
      SettingsCopy.acknowledgementsRowDetail,
    ]

    #expect(details.allSatisfy { $0.split(separator: " ").count <= 5 })
  }

  @Test("download management uses the same plural destination name from Home and Settings")
  func downloadDestinationNameIsConsistent() {
    #expect(SettingsCopy.downloadsRowTitle == HomeCopy.downloadedTitle)
  }

  /// Account removal also cancels in-progress background transfers, so the message names them.
  /// The literal is pinned: this copy is read before an irreversible action, so it changes only
  /// on purpose.
  @Test("logout confirmation is concise and explicit (owned by AppModel's SettingsCopy)")
  func logoutConfirmationIsConciseAndExplicit() {
    #expect(SettingsCopy.logoutTitle == "Log Out?")
    #expect(
      SettingsCopy.logoutMessage
        == "This signs you out, cancels any download still in progress, removes every downloaded book from this device, and discards any offline listening progress that hasn't yet synced to the server."
    )
  }

  private static func sheetHostWindows(in text: String) -> [Substring] {
    var starts: [String.Index] = []
    var searchStart = text.startIndex
    while let range = text.range(of: ".sheet(", range: searchStart..<text.endIndex) {
      starts.append(range.lowerBound)
      searchStart = range.upperBound
    }

    return starts.enumerated().map { index, start in
      let end = index + 1 < starts.count ? starts[index + 1] : text.endIndex
      return text[start..<end]
    }
  }
}
