import Foundation
import SyncEngine

/// What the destination sheet draws for one coordinator prompt. The prompt stays the coordinator's
/// opaque-id value; this adds the layout, the sentences, and the one pre-built choice a sole
/// destination submits.
///
/// The Docker default is one podcast library with one folder, both called "Podcasts". A single-row
/// list there would ask the user to choose "Podcasts" without saying a new show is about to be
/// created, so that case gets an explanatory creation sheet. A real choice keeps the picker; an
/// empty catalogue explains itself.
public struct NativeEpisodeServerSaveDestinationPresentation: Sendable, Equatable,
  CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  /// The sole library + folder a create can go to. The choice carries only the opaque ids the
  /// prompt supplied; the names are what the sheet reads out.
  public struct SoleDestination: Sendable, Equatable {
    public let choice: ServerPodcastSaveChoice
    /// "Podcasts" when the library and its folder share a name, otherwise "Library › Folder".
    public let name: String

    public init(choice: ServerPodcastSaveChoice, name: String) {
      self.choice = choice
      self.name = name
    }
  }

  public enum Layout: Sendable, Equatable {
    /// One library with one folder: an explanation and one confirming action, no list.
    case createInSoleDestination(SoleDestination)
    /// More than one place a show could be created; only libraries with a folder are listed.
    case chooseDestination([NativeEpisodeServerSaveLibraryChoice])
    /// More than one existing server show matches the feed.
    case chooseExistingShow([NativeEpisodeServerSaveExistingChoice])
    /// Nothing to choose: the explanation is the whole sheet.
    case unavailable(String)
  }

  public let layout: Layout
  /// The native feed's title, already bounded and sanitized, or `nil` when the surface has none.
  public let podcastName: String?
  /// The number of episodes represented by this destination choice.
  public let episodeCount: Int
  /// The prompt belongs to a Save Show batch, whose created show has downloads turned on.
  /// Off by default and for every episode surface.
  public let savesShow: Bool

  public init(
    prompt: NativeEpisodeServerSaveChoicePrompt,
    podcastName rawPodcastName: String?,
    episodeCount: Int = 1,
    savesShow: Bool = false
  ) {
    self.episodeCount = max(1, episodeCount)
    self.savesShow = savesShow
    podcastName = rawPodcastName.map(Self.sanitizedPodcastName).flatMap { $0.isEmpty ? nil : $0 }
    switch prompt {
    case .existing(let candidates):
      layout =
        candidates.isEmpty
        ? .unavailable(NativeEpisodeServerSaveCopy.noExistingShowExplanation)
        : .chooseExistingShow(candidates)
    case .libraryAndFolder(let libraries):
      let usable = libraries.filter { $0.folders.isEmpty == false }
      if usable.count == 1, usable[0].folders.count == 1 {
        let library = usable[0]
        let folder = library.folders[0]
        layout = .createInSoleDestination(
          SoleDestination(
            choice: .libraryAndFolder(libraryID: library.libraryID, folderID: folder.folderID),
            name: NativeEpisodeServerSaveCopy.destinationName(
              library: library.displayName, folder: folder.displayName)))
      } else if usable.isEmpty {
        layout = .unavailable(
          NativeEpisodeServerSaveCopy.noDestinationExplanation(
            libraryNames: libraries.map(\.displayName)))
      } else {
        layout = .chooseDestination(usable)
      }
    }
  }

  public var title: String { NativeEpisodeServerSaveCopy.saveAction }

  public var explanation: String {
    switch layout {
    case .createInSoleDestination(let destination):
      guard savesShow else {
        return NativeEpisodeServerSaveCopy.createInSoleDestinationExplanation(
          podcastName: podcastName, destinationName: destination.name, episodeCount: episodeCount)
      }
      return NativeEpisodeServerSaveCopy.createInSoleDestinationRuns(
        podcastName: podcastName, destinationName: destination.name, episodeCount: episodeCount
      ).map(\.text).joined() + " " + NativeEpisodeServerSaveCopy.showSaveDestinationLine
    case .chooseDestination:
      return NativeEpisodeServerSaveCopy.chooseDestinationExplanation
    case .chooseExistingShow:
      return NativeEpisodeServerSaveCopy.chooseExistingShowExplanation(episodeCount: episodeCount)
    case .unavailable(let explanation):
      return explanation
    }
  }

  /// The sole-destination sentence as runs the sheet can emphasise, and its footer. `nil` for
  /// every other layout, which draws `explanation` as plain prose.
  public var soleDestinationRuns: [NativeEpisodeServerSaveCopy.TextRun]? {
    guard case .createInSoleDestination(let destination) = layout else { return nil }
    return NativeEpisodeServerSaveCopy.createInSoleDestinationRuns(
      podcastName: podcastName, destinationName: destination.name, episodeCount: episodeCount)
  }

  public var soleDestinationFooter: String? {
    guard case .createInSoleDestination = layout else { return nil }
    // A show save turns downloads on, so the "future episodes will save there" sentence would say
    // the same thing in other words.
    if savesShow { return NativeEpisodeServerSaveCopy.showSaveDestinationLine }
    return NativeEpisodeServerSaveCopy.createInSoleDestinationFooter(podcastName: podcastName)
  }

  /// The picker's footer for a show save. Only the destination picker: choosing an existing show
  /// changes no setting, and an unavailable sheet creates nothing.
  public var pickerFooter: String? {
    guard savesShow, case .chooseDestination = layout else { return nil }
    return NativeEpisodeServerSaveCopy.showSaveDestinationLine
  }

  /// The symbol drawn above the title: the same one the Save menu item carries, so the sheet
  /// reads as a continuation of the tap that opened it.
  public var systemImage: String { NativeEpisodeServerSaveCopy.saveSystemImage }

  /// The confirming action for the sole-destination sheet; `nil` for every other layout, which
  /// commits from a row instead.
  public var primaryAction: (title: String, accessibilityLabel: String, hint: String)? {
    guard case .createInSoleDestination(let destination) = layout else { return nil }
    return (
      NativeEpisodeServerSaveCopy.createShowAndSaveAction(episodeCount: episodeCount),
      NativeEpisodeServerSaveCopy.createAccessibilityLabel(
        podcastName: podcastName, destinationName: destination.name, episodeCount: episodeCount),
      NativeEpisodeServerSaveCopy.futureEpisodesHint
    )
  }

  public var soleDestinationChoice: ServerPodcastSaveChoice? {
    guard case .createInSoleDestination(let destination) = layout else { return nil }
    return destination.choice
  }

  /// "Library › Folder › Podcast" for a picker row: what the create will produce, without any
  /// server directory.
  public func destinationPreview(
    library: NativeEpisodeServerSaveLibraryChoice,
    folder: NativeEpisodeServerSaveFolderChoice
  ) -> String {
    NativeEpisodeServerSaveCopy.destinationPreview(
      library: library.displayName, folder: folder.displayName, podcastName: podcastName)
  }

  public func folderRowAccessibilityLabel(
    library: NativeEpisodeServerSaveLibraryChoice,
    folder: NativeEpisodeServerSaveFolderChoice
  ) -> String {
    NativeEpisodeServerSaveCopy.createAccessibilityLabel(
      podcastName: podcastName,
      destinationName: NativeEpisodeServerSaveCopy.destinationName(
        library: library.displayName, folder: folder.displayName),
      episodeCount: episodeCount)
  }

  public func existingRowAccessibilityLabel(
    _ candidate: NativeEpisodeServerSaveExistingChoice
  ) -> String {
    NativeEpisodeServerSaveCopy.existingShowAccessibilityLabel(
      showName: candidate.displayName, episodeCount: episodeCount)
  }

  public var existingRowHint: String {
    NativeEpisodeServerSaveCopy.existingShowHint(episodeCount: episodeCount)
  }

  /// The same rule the resolver applies to server names: bidirectional controls and isolates
  /// removed, separators collapsed, bounded length.
  static func sanitizedPodcastName(_ value: String) -> String {
    let bounded = ServerPodcastDestinationResolver.boundedDisplayName(value, fallback: "")
    return String(bounded.prefix(120))
  }

  public var description: String {
    switch layout {
    case .createInSoleDestination:
      return
        "NativeEpisodeServerSaveDestinationPresentation(createInSoleDestination, "
        + "episodeCount: \(episodeCount))"
    case .chooseDestination(let libraries):
      return
        "NativeEpisodeServerSaveDestinationPresentation(chooseDestination, "
        + "libraryCount: \(libraries.count), episodeCount: \(episodeCount))"
    case .chooseExistingShow(let candidates):
      return
        "NativeEpisodeServerSaveDestinationPresentation(chooseExistingShow, "
        + "candidateCount: \(candidates.count), episodeCount: \(episodeCount))"
    case .unavailable:
      return
        "NativeEpisodeServerSaveDestinationPresentation(unavailable, episodeCount: \(episodeCount))"
    }
  }

  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }
}
