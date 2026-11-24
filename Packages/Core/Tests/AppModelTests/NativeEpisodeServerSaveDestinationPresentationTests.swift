import SyncEngine
import Testing

@testable import AppModel

/// The destination sheet's shape is decided here, from the coordinator's opaque prompt and the
/// surface's display-only podcast name. What these pin: one library with one folder is an
/// explanation with one confirming action rather than a one-row list, a real choice keeps the
/// picker, an empty catalogue explains itself, and every commit value is still an opaque id.
@Suite("Native episode server-save destination presentation")
struct NativeEpisodeServerSaveDestinationPresentationTests {
  private let podcasts = NativeEpisodeServerSaveLibraryChoice(
    libraryID: "lib-1", displayName: "Podcasts",
    folders: [NativeEpisodeServerSaveFolderChoice(folderID: "folder-1", displayName: "Podcasts")])

  @Test("one library with one folder is a creation sheet, not a one-row picker")
  func soleDestinationIsACreationSheet() {
    let presentation = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [podcasts]), podcastName: "Night Vale")

    guard case .createInSoleDestination(let destination) = presentation.layout else {
      Issue.record("Expected the sole destination layout, got \(presentation.layout)")
      return
    }
    #expect(destination.choice == .libraryAndFolder(libraryID: "lib-1", folderID: "folder-1"))
    #expect(presentation.soleDestinationChoice == destination.choice)
    #expect(destination.name == "Podcasts")
    #expect(presentation.title == NativeEpisodeServerSaveCopy.saveAction)
    #expect(
      presentation.explanation
        == "Create \u{2018}Night Vale\u{2019} in Podcasts and save this episode. Future episodes "
        + "from this podcast will save there directly.")
    let action = presentation.primaryAction
    #expect(action?.title == "Create show and save episode")
    #expect(action?.accessibilityLabel == "Create \u{2018}Night Vale\u{2019} in Podcasts and save this episode")
    #expect(action?.hint == NativeEpisodeServerSaveCopy.futureEpisodesHint)
  }

  @Test("the creation sentence emphasises the show and the destination and nothing else")
  func soleDestinationRunsEmphasiseNames() {
    let presentation = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [podcasts]), podcastName: "Night Vale")

    #expect(
      presentation.soleDestinationRuns == [
        .plain("Create "),
        .emphasised("\u{2018}Night Vale\u{2019}"),
        .plain(" in "),
        .emphasised("Podcasts"),
        .plain(" and save this episode."),
      ])
    #expect(presentation.soleDestinationFooter == NativeEpisodeServerSaveCopy.futureEpisodesHint)
    // The runs and footer are the explanation, not a second copy of it.
    let joined = presentation.soleDestinationRuns?.map(\.text).joined() ?? ""
    #expect(joined + " " + (presentation.soleDestinationFooter ?? "") == presentation.explanation)
    #expect(presentation.systemImage == NativeEpisodeServerSaveCopy.saveSystemImage)

    let unnamed = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [podcasts]), podcastName: nil)
    #expect(unnamed.soleDestinationRuns?.first == .plain("This will create this podcast in "))
    #expect(unnamed.soleDestinationRuns?.contains(.emphasised("Podcasts")) == true)
    #expect(unnamed.soleDestinationFooter?.contains("the same podcast") == true)
  }

  @Test("only the sole destination has runs; pickers draw plain prose")
  func pickersHaveNoRuns() {
    let two = NativeEpisodeServerSaveLibraryChoice(
      libraryID: "lib-2", displayName: "Archive",
      folders: [
        NativeEpisodeServerSaveFolderChoice(folderID: "a", displayName: "A"),
        NativeEpisodeServerSaveFolderChoice(folderID: "b", displayName: "B"),
      ])
    let presentation = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [two]), podcastName: "Night Vale")
    #expect(presentation.soleDestinationRuns == nil)
    #expect(presentation.soleDestinationFooter == nil)
  }

  @Test("without a podcast name the creation sheet still explains what it will create")
  func soleDestinationWithoutAName() {
    let presentation = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [podcasts]), podcastName: nil)

    #expect(
      presentation.explanation
        == "This will create this podcast in Podcasts and save this episode. Future episodes from "
        + "the same podcast will save there directly.")
    #expect(
      presentation.primaryAction?.accessibilityLabel
        == "Create this podcast in Podcasts and save this episode")
  }

  @Test("a library and folder with different names are both named, library first")
  func soleDestinationNamesBothLevelsWhenTheyDiffer() {
    let library = NativeEpisodeServerSaveLibraryChoice(
      libraryID: "lib-1", displayName: "My Shows",
      folders: [NativeEpisodeServerSaveFolderChoice(folderID: "folder-1", displayName: "podcasts")])
    let presentation = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [library]), podcastName: nil)

    guard case .createInSoleDestination(let destination) = presentation.layout else {
      Issue.record("Expected the sole destination layout")
      return
    }
    #expect(destination.name == "My Shows \u{203A} podcasts")
    #expect(NativeEpisodeServerSaveCopy.destinationName(library: "Podcasts", folder: "podcasts") == "Podcasts")
  }

  @Test("more than one folder keeps a picker that previews library › folder › podcast")
  func multipleDestinationsKeepThePicker() {
    let two = NativeEpisodeServerSaveLibraryChoice(
      libraryID: "lib-2", displayName: "Archive",
      folders: [
        NativeEpisodeServerSaveFolderChoice(folderID: "folder-2", displayName: "Old"),
        NativeEpisodeServerSaveFolderChoice(folderID: "folder-3", displayName: "New"),
      ])
    let empty = NativeEpisodeServerSaveLibraryChoice(
      libraryID: "lib-3", displayName: "Unconfigured", folders: [])
    let presentation = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [podcasts, two, empty]), podcastName: "Night Vale")

    guard case .chooseDestination(let libraries) = presentation.layout else {
      Issue.record("Expected the destination picker, got \(presentation.layout)")
      return
    }
    // A library with no configured folder offers nothing to tap and is not listed as a choice.
    #expect(libraries.map(\.libraryID) == ["lib-1", "lib-2"])
    #expect(presentation.primaryAction == nil)
    #expect(presentation.soleDestinationChoice == nil)
    #expect(presentation.explanation == NativeEpisodeServerSaveCopy.chooseDestinationExplanation)
    #expect(presentation.explanation.contains("No matching show exists on Audiobookshelf"))
    #expect(
      presentation.destinationPreview(library: two, folder: two.folders[1])
        == "Archive \u{203A} New \u{203A} Night Vale")
    #expect(
      presentation.folderRowAccessibilityLabel(library: two, folder: two.folders[0])
        == "Create \u{2018}Night Vale\u{2019} in Archive \u{203A} Old and save this episode")
  }

  @Test("one library with several folders is still a real choice")
  func oneLibraryWithSeveralFoldersIsAChoice() {
    let library = NativeEpisodeServerSaveLibraryChoice(
      libraryID: "lib-1", displayName: "Podcasts",
      folders: [
        NativeEpisodeServerSaveFolderChoice(folderID: "a", displayName: "A"),
        NativeEpisodeServerSaveFolderChoice(folderID: "b", displayName: "B"),
      ])
    let presentation = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [library]), podcastName: nil)

    guard case .chooseDestination(let libraries) = presentation.layout else {
      Issue.record("Expected the destination picker")
      return
    }
    #expect(libraries == [library])
  }

  @Test("no configured folder anywhere is an explanation, never a blank sheet")
  func emptyCatalogueExplainsItself() {
    let empty = NativeEpisodeServerSaveLibraryChoice(
      libraryID: "lib-3", displayName: "Podcasts", folders: [])

    let one = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [empty]), podcastName: "Night Vale")
    guard case .unavailable(let explanation) = one.layout else {
      Issue.record("Expected the unavailable layout")
      return
    }
    #expect(explanation.contains("Podcasts has no folder configured on Audiobookshelf"))
    #expect(one.explanation == explanation)
    #expect(one.primaryAction == nil)

    let none = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: []), podcastName: nil)
    guard case .unavailable(let noneExplanation) = none.layout else {
      Issue.record("Expected the unavailable layout")
      return
    }
    #expect(noneExplanation.contains("no podcast library"))

    let several = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [
        empty, NativeEpisodeServerSaveLibraryChoice(libraryID: "lib-4", displayName: "More", folders: []),
      ]), podcastName: nil)
    guard case .unavailable(let severalExplanation) = several.layout else {
      Issue.record("Expected the unavailable layout")
      return
    }
    #expect(severalExplanation.contains("None of the podcast libraries"))

    let noCandidates = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .existing(candidates: []), podcastName: nil)
    #expect(noCandidates.layout == .unavailable(NativeEpisodeServerSaveCopy.noExistingShowExplanation))
  }

  @Test("several matching server shows explain that an existing show is being chosen")
  func existingShowsAreAChoiceOfShows() {
    let candidates = [
      NativeEpisodeServerSaveExistingChoice(serverItemID: "one", displayName: "One"),
      NativeEpisodeServerSaveExistingChoice(serverItemID: "two", displayName: "Two"),
    ]
    let presentation = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .existing(candidates: candidates), podcastName: "Night Vale")

    #expect(presentation.layout == .chooseExistingShow(candidates))
    #expect(presentation.explanation == NativeEpisodeServerSaveCopy.chooseExistingShowExplanation)
    #expect(presentation.explanation.contains("existing"))
    #expect(
      presentation.existingRowAccessibilityLabel(candidates[1])
        == "Save this episode to the existing show \u{2018}Two\u{2019}")
    #expect(presentation.primaryAction == nil)
  }

  @Test("the podcast name is sanitized and bounded before it is spoken or drawn")
  func podcastNameIsSanitized() {
    let hostile = "Night\u{202E} Vale\nLive"
    let presentation = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [podcasts]), podcastName: hostile)
    #expect(presentation.podcastName == "Night Vale Live")

    let long = String(repeating: "n", count: 500)
    let bounded = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [podcasts]), podcastName: long)
    #expect(bounded.podcastName?.count == 120)

    let blank = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [podcasts]), podcastName: "  \u{202A} ")
    #expect(blank.podcastName == nil)
    #expect(blank.explanation.hasPrefix("This will create this podcast in Podcasts"))
  }

  @Test("count one preserves the existing static copy")
  func countOnePreservesExistingCopy() {
    let sole = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [podcasts]), podcastName: "Night Vale")
    #expect(sole.episodeCount == 1)
    #expect(sole.title == NativeEpisodeServerSaveCopy.saveAction)
    #expect(sole.primaryAction?.title == NativeEpisodeServerSaveCopy.createShowAndSaveAction)
    #expect(sole.primaryAction?.hint == NativeEpisodeServerSaveCopy.futureEpisodesHint)

    let candidates = [
      NativeEpisodeServerSaveExistingChoice(serverItemID: "one", displayName: "One"),
      NativeEpisodeServerSaveExistingChoice(serverItemID: "two", displayName: "Two"),
    ]
    let existing = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .existing(candidates: candidates), podcastName: "Night Vale")
    #expect(existing.explanation == NativeEpisodeServerSaveCopy.chooseExistingShowExplanation)
    #expect(existing.existingRowHint == NativeEpisodeServerSaveCopy.existingShowHint)
  }

  @Test("a batch count changes destination copy and row labels")
  func batchCountChangesCopy() {
    let sole = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [podcasts]),
      podcastName: "Night Vale",
      episodeCount: 5)
    #expect(sole.episodeCount == 5)
    #expect(sole.explanation.contains("and save these 5 episodes."))
    #expect(sole.primaryAction?.title == "Create show and save 5 episodes")
    #expect(
      sole.primaryAction?.accessibilityLabel
        == "Create ‘Night Vale’ in Podcasts and save these 5 episodes")
    #expect(
      sole.folderRowAccessibilityLabel(library: podcasts, folder: podcasts.folders[0])
        == "Create ‘Night Vale’ in Podcasts and save these 5 episodes")

    let candidates = [
      NativeEpisodeServerSaveExistingChoice(serverItemID: "one", displayName: "One"),
      NativeEpisodeServerSaveExistingChoice(serverItemID: "two", displayName: "Two"),
    ]
    let existing = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .existing(candidates: candidates), podcastName: "Night Vale", episodeCount: 5)
    #expect(
      existing.explanation
        == "More than one show on Audiobookshelf uses this podcast’s feed. Choose the existing "
        + "show to save these 5 episodes to.")
    #expect(
      existing.existingRowAccessibilityLabel(candidates[1])
        == "Save these 5 episodes to the existing show ‘Two’")
    #expect(
      existing.existingRowHint
        == "Saves these 5 episodes to this existing Audiobookshelf "
        + "show.")
  }

  @Test("the destination count clamps to one and does not affect choose-destination copy")
  func countClampsAndChooseDestinationIsUnchanged() {
    let clamped = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [podcasts]), podcastName: "Night Vale", episodeCount: 0)
    #expect(clamped.episodeCount == 1)
    #expect(clamped.explanation.contains("save this episode"))

    let archive = NativeEpisodeServerSaveLibraryChoice(
      libraryID: "lib-2", displayName: "Archive",
      folders: [NativeEpisodeServerSaveFolderChoice(folderID: "folder-2", displayName: "Old")])
    let counted = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [podcasts, archive]),
      podcastName: "Night Vale",
      episodeCount: 5)
    #expect(counted.explanation == NativeEpisodeServerSaveCopy.chooseDestinationExplanation)
  }

  @Test("the presentation never reflects names or ids into diagnostics")
  func diagnosticsAreRedacted() {
    let library = NativeEpisodeServerSaveLibraryChoice(
      libraryID: "SENTINEL-ID", displayName: "SENTINEL-NAME",
      folders: [NativeEpisodeServerSaveFolderChoice(folderID: "SENTINEL-ID", displayName: "SENTINEL-NAME")])
    let presentation = NativeEpisodeServerSaveDestinationPresentation(
      prompt: .libraryAndFolder(libraries: [library]), podcastName: "SENTINEL-PODCAST")
    for value in [
      presentation.description, presentation.debugDescription, String(reflecting: presentation),
      "\(presentation)",
    ] {
      #expect(value.contains("SENTINEL") == false)
    }
  }
}
