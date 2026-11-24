import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

@Suite("Smart lists presentation")
struct SmartListsPresentationTests {
  // MARK: - Section

  @Test("the section draws only when available and there is a list or other content")
  func sectionDrawRules() {
    #expect(
      SmartListsPresentation.sectionIsDrawn(isAvailable: false, listCount: 2, hasOtherContent: true)
        == false)
    #expect(
      SmartListsPresentation.sectionIsDrawn(isAvailable: true, listCount: 0, hasOtherContent: true))
    #expect(
      SmartListsPresentation.sectionIsDrawn(isAvailable: true, listCount: 1, hasOtherContent: false))
    #expect(
      SmartListsPresentation.sectionIsDrawn(isAvailable: true, listCount: 0, hasOtherContent: false)
        == false)
  }

  @Test("New offers a blank list apart from the three templates")
  func templatesAreThree() {
    #expect(SmartListsPresentation.templates == [.newEpisodesThisWeek, .shortEpisodes, .downloaded])
    #expect(SmartListsPresentation.templates.contains(.blank) == false)
    #expect(SmartListsPresentation.templateTitle(.blank) == "New List")
  }

  @Test("the Smart Lists screen makes lists from its toolbar, a blank one first")
  func newIsInTheToolbarSource() throws {
    let screen = try ViewSourceScan.executableText(ofViewNamed: "EditSmartListsView")
    let menu = try #require(screen.range(of: "func newMenu("))
    let body = screen[menu.upperBound...].prefix(500)
    let blank = try #require(body.range(of: "create(.blank)"))
    let templates = try #require(body.range(of: "SmartListsPresentation.templates"))

    #expect(screen.contains("ToolbarItem(placement: .primaryAction) { newMenu(model) }"))
    #expect(blank.lowerBound < templates.lowerBound)
  }

  // MARK: - Home

  @Test("Home shows the section under All and Podcasts once a list exists")
  func homeSectionNeedsAList() {
    func kinds(_ filter: MediaFilter, count: Int) -> [HomeMoreSection] {
      HomeViewPresentation.sections(
        continueListening: [], recentlyAdded: [], downloaded: [], smartListCount: count,
        filter: filter
      ).map(\.kind)
    }

    #expect(kinds(.all, count: 2) == [.smartLists])
    #expect(kinds(.podcasts, count: 1) == [.smartLists])
    #expect(kinds(.audiobooks, count: 2).isEmpty)
    #expect(kinds(.ebooks, count: 2).isEmpty)
    #expect(kinds(.all, count: 0).isEmpty)
  }

  @Test("the Home section can be hidden, and its heading opens the Smart Lists screen")
  func homeSectionHidesAndRoutes() {
    let sections = HomeViewPresentation.sections(
      continueListening: [], recentlyAdded: [], downloaded: [], smartListCount: 1,
      hiddenSections: [.smartLists])

    #expect(sections.isEmpty)
    #expect(HomeViewPresentation.detailRoute(for: .smartLists, selectedFilter: .all) == .smartLists)
    #expect(HomeViewPresentation.route(forSmartListID: 7) == .smartList(id: 7))
  }

  // MARK: - Row

  @Test("a row is one spoken element, naming the playing list")
  func rowAccessibilityLabel() {
    #expect(
      SmartListsPresentation.rowAccessibilityLabel(
        name: "Commute", detail: "3 episodes", isActive: true) == "Commute, Playing, 3 episodes")
    #expect(
      SmartListsPresentation.rowAccessibilityLabel(name: "Commute", detail: nil, isActive: false)
        == "Commute")
  }

  @Test("a rule summary joins its words without a separator dot")
  func ruleSummaryHasNoSeparatorDot() {
    #expect(SmartListRuleSummary.text(for: .newReleases).contains("·") == false)
  }

  @Test("four covers make a grid, fewer show the first, none a placeholder")
  func mosaicLayout() {
    #expect(SmartListsPresentation.mosaicLayout(coverCount: 0) == .placeholder)
    #expect(SmartListsPresentation.mosaicLayout(coverCount: 1) == .single)
    #expect(SmartListsPresentation.mosaicLayout(coverCount: 3) == .single)
    #expect(SmartListsPresentation.mosaicLayout(coverCount: 4) == .grid)
  }

  @Test("the card's Play hint says the list plays on, only when Play would start a run")
  func playHint() {
    #expect(
      SmartListsPresentation.playHint(listName: "Commute", startsRun: true)
        == "Plays Commute from this episode.")
    #expect(SmartListsPresentation.playHint(listName: "Commute", startsRun: false) == nil)
    #expect(SmartListsPresentation.playHint(listName: nil, startsRun: true) == nil)
  }

  // MARK: - Editor

  @Test("the live count is announced as a match count")
  func announcement() {
    #expect(SmartListsPresentation.announcement(matchCount: 4) == "4 episodes match")
    #expect(SmartListsPresentation.announcement(matchCount: nil) == nil)
  }

  @Test("Updating shows follows the model's flag")
  func updatingShows() {
    #expect(SmartListsPresentation.listSubtitleWhileUpdating(isUpdating: true) == "Updating shows…")
    #expect(SmartListsPresentation.listSubtitleWhileUpdating(isUpdating: false) == nil)
  }

  @Test("the picker labels the shows that cannot take part")
  func availabilityNotes() {
    #expect(SmartListsPresentation.availabilityNote(.available) == nil)
    #expect(SmartListsPresentation.availabilityNote(.notFollowed) == "Not followed")
    #expect(
      SmartListsPresentation.availabilityNote(.notOnServer) == "Not available on this server")
  }

  // MARK: - Episode ref

  @Test("a list's row opens the card with the list, and the ref still equals the plain one")
  func refCarriesContext() {
    let context = NavigationModel.SmartListContext(listID: 7, name: "Commute")
    let withList = NavigationModel.PodcastEpisodeRef(
      itemID: "a", episodeID: "b", listContext: context)

    #expect(withList.listContext == context)
    #expect(withList == NavigationModel.PodcastEpisodeRef(itemID: "a", episodeID: "b"))
    #expect(CrossShowEpisodeSurface.smartListEpisodeRow.resolvedEpisodeRef?.listContext != nil)
  }

  @Test("the Smart Lists section is not in the root toolbar")
  func toolbarUnchanged() {
    #expect(PodcastsViewPresentation.rootToolbarItems == ["Add Podcast"])
  }

  // MARK: - Legibility

  /// The accent is near-white in the dark appearance, so an untinted switch draws a white thumb on
  /// a white track.
  @Test("every editor switch carries the brand tint")
  func controlsCarryTheBrandTint() throws {
    let editor = try ViewSourceScan.executableText(ofViewNamed: "SmartListEditorSheet")
    let toggles = ViewSourceScan.occurrences(of: ["Toggle("], in: editor)
    #expect(toggles > 0)
    #expect(ViewSourceScan.occurrences(of: [".tint(AppChrome.brandTint)"], in: editor) == toggles)
  }

  // MARK: - Play controls

  @Test("a list pauses only while its run plays, and resumes while its run is paused")
  func listPlayControl() {
    #expect(
      SmartListsPresentation.playControl(
        isActive: true, hasLoadedEpisode: true, isPlaybackIntended: true) == .pause)
    #expect(
      SmartListsPresentation.playControl(
        isActive: true, hasLoadedEpisode: true, isPlaybackIntended: false) == .resume)
    #expect(
      SmartListsPresentation.playControl(
        isActive: true, hasLoadedEpisode: false, isPlaybackIntended: false) == .start)
    #expect(
      SmartListsPresentation.playControl(
        isActive: false, hasLoadedEpisode: true, isPlaybackIntended: true) == .start)
    #expect(SmartListsPresentation.playControlTitle(.pause) == "Pause")
    #expect(SmartListsPresentation.playControlTitle(.resume) == "Resume")
    #expect(SmartListsPresentation.playControlLabel(.start, name: "Commute") == "Play Commute")
  }

  @Test("the Play button speaks for the loaded episode, else the next in line")
  func playTarget() {
    #expect(SmartListsPresentation.playTarget(in: [Int](), isLoaded: { _ in false }) == nil)
    let next = SmartListsPresentation.playTarget(in: [1, 2, 3], isLoaded: { _ in false })
    #expect(next?.episode == 1 && next?.isLoaded == false)
    let loaded = SmartListsPresentation.playTarget(in: [1, 2, 3], isLoaded: { $0 == 2 })
    #expect(loaded?.episode == 2 && loaded?.isLoaded == true)
  }

  // MARK: - Editor choices

  @Test("download status is one choice over the two stored switches")
  func downloadChoice() {
    #expect(SmartListDownloadChoice(.default) == .any)
    #expect(SmartListDownloadChoice(.downloaded) == .downloaded)

    var rules = SmartListRules.default
    SmartListDownloadChoice.notDownloaded.apply(to: &rules)
    #expect(rules.includeDownloaded == false)
    #expect(rules.includeNotDownloaded)
    SmartListDownloadChoice.any.apply(to: &rules)
    #expect(rules.includeDownloaded && rules.includeNotDownloaded)
    for choice in SmartListDownloadChoice.allCases {
      var rules = SmartListRules.default
      choice.apply(to: &rules)
      #expect(SmartListDownloadChoice(rules) == choice)
      #expect(throws: Never.self) { try rules.validate() }
    }
  }

  @Test("a tick means chosen under Only chosen and left out under All except")
  func showMarks() {
    #expect(SmartListShowChoice.isMarked(.included, scope: .only))
    #expect(SmartListShowChoice.isMarked(.priority, scope: .only))
    #expect(SmartListShowChoice.isMarked(.excluded, scope: .only) == false)
    #expect(SmartListShowChoice.isMarked(.excluded, scope: .allExcept))
    #expect(SmartListShowChoice.isMarked(.priority, scope: .allExcept) == false)
    #expect(SmartListShowChoice.isMarked(.included, scope: .all) == false)

    #expect(SmartListShowChoice.toggled(nil, scope: .only) == .included)
    #expect(SmartListShowChoice.toggled(.priority, scope: .only) == nil)
    #expect(SmartListShowChoice.toggled(.priority, scope: .allExcept) == .excluded)
    #expect(SmartListShowChoice.toggled(.excluded, scope: .allExcept) == nil)
    #expect(SmartListShowChoice.toggled(.priority, scope: .all) == .priority)
  }

  @Test("starring chooses a show, and unstarring leaves it chosen")
  func showStars() {
    #expect(SmartListShowChoice.priorityToggled(nil, scope: .all) == .priority)
    #expect(SmartListShowChoice.priorityToggled(.excluded, scope: .allExcept) == .priority)
    #expect(SmartListShowChoice.priorityToggled(.priority, scope: .only) == .included)
    #expect(SmartListShowChoice.priorityToggled(.priority, scope: .all) == nil)
  }

  @Test("the Shows row says what the scope and ticks come to")
  func showsSummary() {
    #expect(SmartListShowChoice.summary(scope: .all, roles: [.priority, nil]) == "All shows")
    #expect(SmartListShowChoice.summary(scope: .only, roles: [nil, nil]) == "None chosen")
    #expect(SmartListShowChoice.summary(scope: .only, roles: [.included, nil]) == "1 show")
    #expect(
      SmartListShowChoice.summary(scope: .only, roles: [.included, .priority, .excluded])
        == "2 shows")
    #expect(SmartListShowChoice.summary(scope: .allExcept, roles: [.included]) == "All shows")
    #expect(
      SmartListShowChoice.summary(scope: .allExcept, roles: [.excluded, .excluded])
        == "All except 2")
  }

  @Test("the Status row lists the statuses in, in order")
  func statusSummary() {
    #expect(SmartListEditorLabels.statusSummary(.default) == "Unplayed, In progress")
    #expect(
      SmartListEditorLabels.statusSummary(
        SmartListRules(includeUnplayed: false, includeInProgress: false, includePlayed: false))
        == "None")
  }

  @Test("a length reads in hours and minutes, and the wheels stay inside the rule")
  func lengths() {
    #expect(SmartListEditorLabels.length(minutes: 45) == "45 min")
    #expect(SmartListEditorLabels.length(minutes: 60) == "1 hr")
    #expect(SmartListEditorLabels.length(minutes: 90) == "1 hr 30 min")
    #expect(SmartListEditorLabels.clampedMinutes(hours: 10, minutes: 30, in: 1...600) == 600)
    #expect(SmartListEditorLabels.clampedMinutes(hours: 0, minutes: 0, in: 1...600) == 1)
    #expect(SmartListEditorLabels.clampedMinutes(hours: 1, minutes: 5, in: 0...599) == 65)
  }

  // MARK: - List screen title

  /// The list's own model reads the store before it knows the name, so the title arrived about a
  /// second after the push. The shared model already holds every list's name.
  @Test("a list's screen is titled from the shared lists before its own model loads")
  func listTitleFallsBackToTheSharedLists() {
    let lists = [
      SmartListSummary(
        id: 7, name: "Politics", rules: SmartListRules(), matchCount: 1,
        nextEpisodeTitle: nil, nextShowTitle: nil, isActive: false)
    ]
    #expect(SmartListsPresentation.listTitle(loaded: nil, listID: 7, lists: lists) == "Politics")
    #expect(SmartListsPresentation.listTitle(loaded: "Renamed", listID: 7, lists: lists) == "Renamed")
    #expect(SmartListsPresentation.listTitle(loaded: nil, listID: 8, lists: lists) == "")
  }

  // MARK: - List header

  @Test("each rule becomes a chip that starts with a capital")
  func ruleChipsAreCapitalised() {
    let rules = SmartListRules(
      includeDownloaded: true, includeNotDownloaded: false, sortOrder: .oldest)

    #expect(
      SmartListsPresentation.ruleChips(for: rules) == ["All shows", "Downloaded", "Oldest first"])
  }

  @Test("the rule chips are spoken as one control that opens the editor")
  func ruleChipsAccessibilityLabel() {
    #expect(
      SmartListsPresentation.rulesAccessibilityLabel(for: .default)
        == "Rules: All shows, newest first")
  }
}
