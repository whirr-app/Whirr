import ABSApi
import AppModel
import Persistence

/// The facts one item surface's long-press menu reads, composed once at row-body time from the
/// projection the surface already holds.
///
/// Values and closures only. `playbackStatus` stays a closure so the progress entry is evaluated
/// inside the presented menu, never once per visible row (see `ItemContextMenuModifier`'s note).
struct ItemMenuSubject {
  let itemID: String
  let title: String
  let author: String?
  let duration: Double?
  let category: ItemMediaCategory
  let hasReadableEbook: Bool
  let usesEbookProgress: Bool
  let episodeID: String?
  let playbackStatus: () -> ItemPlaybackStatus?
  let showsNarratorLink: Bool
  let narrator: String?
  let coverClient: any ArtworkServing
  let source: ArtworkSource?
  let revision: ArtworkRevision
  let playback: PlaybackModel
  let actions: ItemActionsModel

  /// Whether this subject is offered the shared menu at all.
  var offersMenu: Bool { ItemContextMenuAvailability.offersMenu(for: category) }

  init(
    itemID: String,
    title: String,
    author: String?,
    duration: Double?,
    category: ItemMediaCategory,
    hasReadableEbook: Bool,
    usesEbookProgress: Bool = false,
    episodeID: String? = nil,
    playbackStatus: @escaping () -> ItemPlaybackStatus? = { nil },
    showsNarratorLink: Bool,
    narrator: String?,
    coverClient: any ArtworkServing,
    source: ArtworkSource? = nil,
    revision: ArtworkRevision,
    playback: PlaybackModel,
    actions: ItemActionsModel
  ) {
    self.itemID = itemID
    self.title = title
    self.author = author
    self.duration = duration
    self.category = category
    self.hasReadableEbook = hasReadableEbook
    self.usesEbookProgress = usesEbookProgress
    self.episodeID = episodeID
    self.playbackStatus = playbackStatus
    self.showsNarratorLink = showsNarratorLink
    self.narrator = narrator
    self.coverClient = coverClient
    self.source = source
    self.revision = revision
    self.playback = playback
    self.actions = actions
  }

  /// A Home shelf, Continue Listening or Saved-for-Later row's audiobook or ebook.
  init(
    item: HomeItem, usesEbookProgress: Bool = false, coverClient: any ArtworkServing,
    playback: PlaybackModel, actions: ItemActionsModel
  ) {
    self.init(
      itemID: item.serverItemId,
      title: item.title,
      author: item.author,
      duration: item.durationSeconds,
      category: item.category,
      hasReadableEbook: item.hasReadableEbook,
      usesEbookProgress: usesEbookProgress,
      episodeID: item.episodeID,
      playbackStatus: {
        MediaProgressActionPolicy.playbackStatus(
          progressSeconds: item.progressSeconds,
          ebookProgress: item.ebookProgress,
          isFinished: item.isFinished)
      },
      showsNarratorLink: item.category == .audiobook,
      narrator: item.narratorName,
      coverClient: coverClient,
      source: item.itemSummary.providerArtworkSource,
      revision: item.artworkRevision,
      playback: playback,
      actions: actions)
  }

  /// A podcast episode row.
  init(
    episode: HomePodcastEpisode, coverClient: any ArtworkServing,
    playback: PlaybackModel, actions: ItemActionsModel
  ) {
    self.init(
      itemID: episode.itemID,
      title: episode.showTitle,
      author: episode.showAuthor,
      duration: episode.durationSeconds,
      category: .podcast,
      hasReadableEbook: false,
      episodeID: episode.episodeID,
      playbackStatus: {
        MediaProgressActionPolicy.playbackStatus(
          progressSeconds: episode.progressSeconds, isFinished: episode.isFinished)
      },
      showsNarratorLink: false,
      narrator: nil,
      coverClient: coverClient,
      source: episode.providerArtworkSource,
      revision: episode.artworkRevision,
      playback: playback,
      actions: actions)
  }

  /// A podcast show tile: a show is always a podcast with no narrator, whatever fields the
  /// catalogue row carries.
  init(
    show: ItemSummary, coverClient: any ArtworkServing,
    playback: PlaybackModel, actions: ItemActionsModel
  ) {
    self.init(
      itemID: show.serverItemId,
      title: show.title,
      author: show.author,
      duration: show.durationSeconds,
      category: .podcast,
      hasReadableEbook: false,
      showsNarratorLink: false,
      narrator: nil,
      coverClient: coverClient,
      source: show.providerArtworkSource,
      revision: show.artworkRevision,
      playback: playback,
      actions: actions)
  }

  /// An `ItemSummary` surface: a library row or a saved row. The caller supplies a progress closure
  /// only where the screen already holds one.
  init(
    summary: ItemSummary, title: String? = nil, category: ItemMediaCategory? = nil,
    playbackStatus: @escaping () -> ItemPlaybackStatus? = { nil },
    coverClient: any ArtworkServing, source: ArtworkSource?, revision: ArtworkRevision,
    playback: PlaybackModel, actions: ItemActionsModel
  ) {
    self.init(
      itemID: summary.serverItemId,
      title: title ?? summary.title,
      author: summary.author,
      duration: summary.durationSeconds,
      category: category ?? summary.category,
      hasReadableEbook: summary.hasReadableEbook,
      playbackStatus: playbackStatus,
      showsNarratorLink: (category ?? summary.category) == .audiobook,
      narrator: summary.narratorName,
      coverClient: coverClient,
      source: source,
      revision: revision,
      playback: playback,
      actions: actions)
  }
}
