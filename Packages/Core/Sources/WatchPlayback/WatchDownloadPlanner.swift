import ABSApi
import Foundation
import PlayerCore
import WatchProtocol

/// One server-backed file that can be handed to `WatchDownloadStore.enqueue`.
/// It contains no URL or credential; the App obtains an authenticated request from the current
/// account only when the transfer is actually scheduled.
public struct WatchDownloadDescriptor: Sendable, Equatable, Identifiable {
  public let id: String
  public let selection: WatchSelection
  public let title: String?
  public let chapters: [PlayerCore.PlaybackChapter]
  public let downloadGroupID: String
  public let expectedTrackCount: Int
  public let fileID: String
  public let fileIndex: Int
  public let startOffset: Double
  public let duration: Double
  public let expectedBytes: Int64
  public let expectedMIMEType: String

  public init(
    id: String,
    selection: WatchSelection,
    title: String?,
    downloadGroupID: String,
    expectedTrackCount: Int,
    fileID: String,
    fileIndex: Int,
    startOffset: Double,
    duration: Double,
    expectedBytes: Int64,
    expectedMIMEType: String,
    chapters: [PlayerCore.PlaybackChapter] = []
  ) {
    self.id = id
    self.selection = selection
    self.title = title
    self.chapters = PlaybackChapterMap(chapters: chapters).chapters
    self.downloadGroupID = downloadGroupID
    self.expectedTrackCount = expectedTrackCount
    self.fileID = fileID
    self.fileIndex = fileIndex
    self.startOffset = startOffset
    self.duration = duration
    self.expectedBytes = expectedBytes
    self.expectedMIMEType = expectedMIMEType
  }
}

public enum WatchDownloadPlanningError: Error, Sendable, Equatable {
  case unsupportedMedia
  case noAudioFiles
  case invalidItemID
  case invalidEpisodeID
  case invalidFileIndex
  case invalidFileIdentity
  case missingDuration
  case missingSize
  case invalidMIMEType
  case duplicateFileIndex
  /// The show has no episode with the requested identifier.
  case episodeNotFound
}

/// Maps clean ABS item-detail values into account-neutral download descriptors. The mapper never
/// reconstructs an endpoint from an enclosure/content URL: the request provider owns that step.
public enum WatchDownloadPlanner {
  /// Every file of a book, or every stored episode of a show. A malformed episode fails the whole
  /// show, so a caller that wants one episode uses `plan(for:episodeID:)`.
  public static func plan(for detail: ItemDetail) throws -> [WatchDownloadDescriptor] {
    guard WatchDownloadValidation.validIdentifier(detail.id) else { throw WatchDownloadPlanningError.invalidItemID }
    switch detail.media {
    case .book(let book):
      return try bookDescriptors(itemID: detail.id, media: book)
    case .podcast(let podcast):
      return try podcastDescriptors(itemID: detail.id, episodes: podcast.episodes)
    case nil:
      throw WatchDownloadPlanningError.unsupportedMedia
    }
  }

  /// The files of one selection: the whole book when `episodeID` is nil, or one episode of a show,
  /// validated alone so the show's other episodes cannot fail it.
  public static func plan(for detail: ItemDetail, episodeID: String?) throws -> [WatchDownloadDescriptor] {
    guard WatchDownloadValidation.validIdentifier(detail.id) else { throw WatchDownloadPlanningError.invalidItemID }
    switch (detail.media, episodeID) {
    case (.book(let book), nil):
      return try bookDescriptors(itemID: detail.id, media: book)
    case (.podcast(let podcast), .some(let episodeID)):
      let requested = podcast.episodes.filter { $0.id == episodeID }
      guard requested.isEmpty == false else { throw WatchDownloadPlanningError.episodeNotFound }
      let plan = try podcastDescriptors(itemID: detail.id, episodes: requested)
      guard plan.isEmpty == false else { throw WatchDownloadPlanningError.noAudioFiles }
      return plan
    default:
      throw WatchDownloadPlanningError.unsupportedMedia
    }
  }

  private static func bookDescriptors(itemID: String, media: BookMedia) throws -> [WatchDownloadDescriptor] {
    guard media.audioFiles.files.isEmpty == false, media.audioFiles.invalidEntryCount == 0 else {
      throw WatchDownloadPlanningError.noAudioFiles
    }
    var seen: Set<Int> = []
    var tracksByIndex: [Int: AudioTrack] = [:]
    for track in media.tracks {
      guard track.index >= 0 else { throw WatchDownloadPlanningError.invalidFileIndex }
      guard tracksByIndex[track.index] == nil else {
        throw WatchDownloadPlanningError.duplicateFileIndex
      }
      tracksByIndex[track.index] = track
    }
    let files = media.audioFiles.files.sorted { $0.index < $1.index }
    var runningOffset = 0.0
    return try files.map { file in
      guard file.index >= 0 else { throw WatchDownloadPlanningError.invalidFileIndex }
      guard seen.insert(file.index).inserted else {
        throw WatchDownloadPlanningError.duplicateFileIndex
      }
      guard WatchDownloadValidation.validIdentifier(file.ino) else {
        throw WatchDownloadPlanningError.invalidFileIdentity
      }
      guard WatchDownloadValidation.validSize(file.expectedSize) else { throw WatchDownloadPlanningError.missingSize }
      guard WatchDownloadValidation.validDuration(file.duration) else {
        throw WatchDownloadPlanningError.missingDuration
      }
      guard file.mimeType.isEmpty == false else { throw WatchDownloadPlanningError.invalidMIMEType }
      let track = tracksByIndex[file.index]
      let startOffset = track?.startOffset ?? runningOffset
      let duration = track?.duration ?? file.duration
      guard startOffset.isFinite, abs(startOffset - runningOffset) < 0.01,
        WatchDownloadValidation.validDuration(duration)
      else { throw WatchDownloadPlanningError.missingDuration }
      runningOffset = startOffset + duration
      return WatchDownloadDescriptor(
        id: "\(itemID):\(file.index):\(file.ino)",
        selection: .audiobookshelf(itemID: itemID, episodeID: nil),
        title: bookTitle(media: media, track: track),
        downloadGroupID: itemID, expectedTrackCount: files.count,
        fileID: file.ino, fileIndex: file.index, startOffset: startOffset,
        duration: duration, expectedBytes: Int64(file.expectedSize), expectedMIMEType: file.mimeType,
        chapters: file.index == files.first?.index
          ? media.chapters.compactMap { chapter in
            guard let start = chapter.start, let end = chapter.end else { return nil }
            return PlayerCore.PlaybackChapter(id: String(chapter.id), title: chapter.title, start: start, end: end)
          } : [])
    }
  }

  /// The descriptor title becomes the player title. ABS names a book's audio track after its file
  /// ("Provenance.m4b"), so the track only stands in when the book itself has no title.
  private static func bookTitle(media: BookMedia, track: AudioTrack?) -> String? {
    if let title = media.title, title.isEmpty == false { return title }
    guard let name = track?.title, name.isEmpty == false else { return nil }
    let stem = (name as NSString).deletingPathExtension
    return stem.isEmpty ? name : stem
  }

  private static func podcastDescriptors(
    itemID: String, episodes: [PodcastEpisode]
  ) throws -> [WatchDownloadDescriptor] {
    var descriptors: [WatchDownloadDescriptor] = []
    for episode in episodes {
      guard WatchDownloadValidation.validIdentifier(episode.id) else {
        throw WatchDownloadPlanningError.invalidEpisodeID
      }
      guard let audio = episode.audioFile else { continue }
      guard WatchDownloadValidation.validIdentifier(audio.ino) else {
        throw WatchDownloadPlanningError.invalidFileIdentity
      }
      guard WatchDownloadValidation.validSize(audio.expectedSize) else { throw WatchDownloadPlanningError.missingSize }
      guard WatchDownloadValidation.validDuration(audio.duration) else {
        throw WatchDownloadPlanningError.missingDuration
      }
      guard audio.mimeType.isEmpty == false else { throw WatchDownloadPlanningError.invalidMIMEType }
      descriptors.append(
        WatchDownloadDescriptor(
          id: "\(itemID):\(episode.id):\(audio.ino)",
          selection: .audiobookshelf(itemID: itemID, episodeID: episode.id),
          title: episode.title,
          downloadGroupID: episode.id, expectedTrackCount: 1,
          fileID: audio.ino, fileIndex: 0, startOffset: 0, duration: audio.duration,
          expectedBytes: Int64(audio.expectedSize), expectedMIMEType: audio.mimeType))
    }
    return descriptors
  }

}
