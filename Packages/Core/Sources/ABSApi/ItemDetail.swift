import Foundation

/// Clean public value type for `GET /api/items/{id}?expanded=1`. Never the raw wire shape
/// (ARCHITECTURE.md §1).
public struct ItemDetail: Sendable, Equatable {
  public let id: String
  public let libraryID: String?
  public let mediaType: String?
  public let media: ItemMedia?

  public init(
    id: String,
    libraryID: String?,
    mediaType: String?,
    media: ItemMedia?
  ) {
    self.id = id
    self.libraryID = libraryID
    self.mediaType = mediaType
    self.media = media
  }

  init(dto: ItemDetailDTO, id: String) {
    let media: ItemMedia?
    if let book = dto.book {
      media = .book(BookMedia(dto: book, libraryFiles: dto.libraryFiles))
    } else if let podcast = dto.podcast {
      media = .podcast(PodcastMedia(dto: podcast))
    } else {
      media = nil
    }
    self.init(id: id, libraryID: dto.libraryId, mediaType: dto.mediaType, media: media)
  }
}

/// Book and podcast shapes diverge, so this is an enum keyed off the wire `mediaType`
/// discriminator rather than one blanket-optional struct.
public enum ItemMedia: Sendable, Equatable {
  case book(BookMedia)
  case podcast(PodcastMedia)
}

public struct BookMedia: Sendable, Equatable {
  public let title: String?
  public let subtitle: String?
  public let authorName: String?
  public let narratorName: String?
  public let seriesName: String?
  public let description: String?
  public let duration: Double?
  public let audioFiles: AudioFileCatalog
  public let tracks: [AudioTrack]
  public let chapters: [Chapter]
  public let ebookFile: EbookFileInfo?
  /// PDFs that accompany the audio. Never an ebook.
  public let supplements: [SupplementFileInfo]

  public init(
    title: String?,
    subtitle: String?,
    authorName: String?,
    narratorName: String?,
    seriesName: String?,
    description: String?,
    duration: Double?,
    audioFiles: AudioFileCatalog,
    tracks: [AudioTrack],
    chapters: [Chapter],
    ebookFile: EbookFileInfo?,
    supplements: [SupplementFileInfo] = []
  ) {
    self.title = title
    self.subtitle = subtitle
    self.authorName = authorName
    self.narratorName = narratorName
    self.seriesName = seriesName
    self.description = description
    self.duration = duration
    self.audioFiles = audioFiles
    self.tracks = tracks
    self.chapters = chapters
    self.ebookFile = ebookFile
    self.supplements = supplements
  }

  init(dto: BookMediaDTO, libraryFiles: [EbookFileDTO] = []) {
    self.init(
      title: dto.title,
      subtitle: dto.subtitle,
      authorName: dto.authorName,
      narratorName: dto.narratorName,
      seriesName: dto.seriesName,
      description: dto.description,
      duration: dto.duration,
      audioFiles: Self.makeAudioFileCatalog(from: dto.audioFiles),
      // Elements missing `index` are dropped. `decodeLossyArray`'s `requiredKey` filter has
      // normally excluded them already.
      tracks: dto.tracks.compactMap { track in
        guard let index = track.index else { return nil }
        return AudioTrack(
          index: index,
          startOffset: track.startOffset,
          duration: track.duration,
          title: track.title,
          contentUrl: track.contentUrl,
          mimeType: track.mimeType
        )
      },
      chapters: Chapter.identified(dto.chapters),
      ebookFile: dto.ebookFile.flatMap { file -> EbookFileInfo? in
        // `ino` builds the per-file ebook download URL; without one the file can't be
        // referenced, so treat it as absent.
        guard let ino = file.ino else { return nil }
        return EbookFileInfo(ino: ino, ext: file.ext, filename: file.filename, size: file.size)
      },
      supplements: Self.makeSupplements(
        primary: dto.ebookFile, libraryFiles: libraryFiles,
        hasAudio: dto.audioFiles.isEmpty == false || dto.tracks.isEmpty == false)
    )
  }

  /// An `audioFiles[]` entry becomes an `AudioFileInfo` only with identity (`index`/`ino`),
  /// validation (`expectedSize` positive) and playback (`mimeType` non-empty, `duration` finite
  /// and positive) all present. Anything else, malformed or incomplete, increments
  /// `invalidEntryCount` rather than disappearing, so download planning can't mistake a partial
  /// catalog for a complete one.
  private static func makeAudioFileCatalog(from entries: [AudioFileEntryDTO]) -> AudioFileCatalog {
    var files: [AudioFileInfo] = []
    var invalidEntryCount = 0
    for entry in entries {
      guard let index = entry.index,
        let ino = entry.ino, ino.isEmpty == false,
        let expectedSize = entry.size, expectedSize > 0,
        let mimeType = entry.mimeType, mimeType.isEmpty == false,
        let duration = entry.duration, duration.isFinite, duration > 0
      else {
        invalidEntryCount += 1
        continue
      }
      files.append(
        AudioFileInfo(index: index, ino: ino, expectedSize: expectedSize, mimeType: mimeType, duration: duration)
      )
    }
    return AudioFileCatalog(files: files, invalidEntryCount: invalidEntryCount)
  }
}

/// One audio file backing a book, the source for per-file downloads (API-CONVENTIONS.md rule 24).
/// Distinct from `AudioTrack`, the playable stream descriptor `tracks[]` exposes. `ino` fills the
/// download endpoint's `{fileid}` path segment. It is a server-side inode string
/// (`"649641337522215266"`), carried verbatim and never parsed: values exceed `Int32`. No raw
/// filesystem path or filename is exposed.
public struct AudioFileInfo: Sendable, Equatable {
  public let index: Int
  public let ino: String
  public let expectedSize: Int
  public let mimeType: String
  public let duration: Double

  public init(index: Int, ino: String, expectedSize: Int, mimeType: String, duration: Double) {
    self.index = index
    self.ino = ino
    self.expectedSize = expectedSize
    self.mimeType = mimeType
    self.duration = duration
  }
}

/// Loss-tolerant view of a book's `audioFiles[]`. See `BookMedia.makeAudioFileCatalog(from:)` for
/// which entries qualify as clean.
public struct AudioFileCatalog: Sendable, Equatable {
  public let files: [AudioFileInfo]
  public let invalidEntryCount: Int

  public init(files: [AudioFileInfo], invalidEntryCount: Int) {
    self.files = files
    self.invalidEntryCount = invalidEntryCount
  }
}

/// A playable stream descriptor from `tracks[]`, distinct from the raw `audioFiles[]` entries.
public struct AudioTrack: Sendable, Equatable {
  public let index: Int
  public let startOffset: Double?
  public let duration: Double?
  public let title: String?
  public let contentUrl: String?
  public let mimeType: String?

  public init(
    index: Int,
    startOffset: Double?,
    duration: Double?,
    title: String?,
    contentUrl: String?,
    mimeType: String?
  ) {
    self.index = index
    self.startOffset = startOffset
    self.duration = duration
    self.title = title
    self.contentUrl = contentUrl
    self.mimeType = mimeType
  }
}

public struct Chapter: Sendable, Equatable {
  public let id: Int
  public let start: Double?
  public let end: Double?
  public let title: String?

  public init(id: Int, start: Double?, end: Double?, title: String?) {
    self.id = id
    self.start = start
    self.end = end
    self.title = title
  }

  /// A chapter without an `id` cannot be addressed, so it is dropped.
  static func identified(_ dtos: [ChapterDTO]) -> [Chapter] {
    dtos.compactMap { chapter in
      guard let id = chapter.id else { return nil }
      return Chapter(id: id, start: chapter.start, end: chapter.end, title: chapter.title)
    }
  }
}

/// The `{ino, metadata{filename, ext, size}}` shape of `libraryFiles[]`/`audioFiles[]` entries.
/// A captured example is in `Sources/TestSupport/Fixtures/search-full-buckets-authors.json:58`,
/// including the leading-dot `ext` value `.epub`. The raw filesystem `path` is not carried into
/// the public type.
public struct EbookFileInfo: Sendable, Equatable {
  /// The same server-side inode string as `AudioFileInfo.ino`.
  public let ino: String
  public let ext: String?
  public let filename: String?
  public let size: Int?

  public init(ino: String, ext: String?, filename: String?, size: Int?) {
    self.ino = ino
    self.ext = Self.normalizedExtension(ext)
    self.filename = filename
    self.size = size
  }

  static func normalizedExtension(_ rawExtension: String?) -> String? {
    guard let rawExtension else { return nil }
    let trimmed = rawExtension.trimmingCharacters(in: .whitespacesAndNewlines)
    let withoutLeadingDots = trimmed.drop(while: { $0 == "." })
    guard withoutLeadingDots.isEmpty == false else { return nil }
    return withoutLeadingDots.lowercased()
  }
}

public struct PodcastMedia: Sendable, Equatable {
  public let title: String?
  public let author: String?
  public let description: String?
  public let episodes: [PodcastEpisode]
  /// True only when the wire payload actually contained a structurally valid `episodes` array.
  /// A missing/null/wrong-type field still decodes as an empty list for resilient presentation,
  /// but callers must not treat that as authoritative emptiness for deletion inference.
  public let isEpisodeListStructurallyComplete: Bool
  /// Read-only show diagnostics (API-CONVENTIONS rule 26). Present on a live v2.35.1 capture but
  /// decoded absent-tolerantly: render them only when the value is here, never guess
  /// "off"/"never" from a missing field.
  public let autoDownloadEpisodes: Bool?
  public let autoDownloadSchedule: String?
  public let lastEpisodeCheck: Date?
  public let maxEpisodesToKeep: Int?
  public let maxNewEpisodesToDownload: Int?

  public init(
    title: String?,
    author: String?,
    description: String?,
    episodes: [PodcastEpisode],
    isEpisodeListStructurallyComplete: Bool = true,
    autoDownloadEpisodes: Bool? = nil,
    autoDownloadSchedule: String? = nil,
    lastEpisodeCheck: Date? = nil,
    maxEpisodesToKeep: Int? = nil,
    maxNewEpisodesToDownload: Int? = nil
  ) {
    self.title = title
    self.author = author
    self.description = description
    self.episodes = episodes
    self.isEpisodeListStructurallyComplete = isEpisodeListStructurallyComplete
    self.autoDownloadEpisodes = autoDownloadEpisodes
    self.autoDownloadSchedule = autoDownloadSchedule
    self.lastEpisodeCheck = lastEpisodeCheck
    self.maxEpisodesToKeep = maxEpisodesToKeep
    self.maxNewEpisodesToDownload = maxNewEpisodesToDownload
  }

  init(dto: PodcastMediaDTO) {
    self.init(
      title: dto.title,
      author: dto.author,
      description: dto.description,
      episodes: dto.episodes.compactMap { episode in
        guard let id = episode.id else { return nil }
        return PodcastEpisode(
          id: id,
          title: episode.title,
          guid: episode.guid,
          enclosureURL: episode.enclosureURL,
          subtitle: episode.subtitle,
          description: episode.description,
          seasonNumber: episode.seasonNumber,
          episodeNumber: episode.episodeNumber,
          episodeType: episode.episodeType,
          contentUrl: episode.contentUrl,
          mimeType: episode.mimeType,
          duration: episode.duration,
          size: episode.size,
          publishedAt: episode.publishedAt,
          audioFile: Self.validatedAudioFile(from: episode.audioFile),
          chapters: Chapter.identified(episode.chapters)
        )
      },
      isEpisodeListStructurallyComplete: dto.isEpisodeListStructurallyComplete,
      autoDownloadEpisodes: dto.autoDownloadEpisodes,
      autoDownloadSchedule: dto.autoDownloadSchedule,
      lastEpisodeCheck: dto.lastEpisodeCheck,
      maxEpisodesToKeep: dto.maxEpisodesToKeep,
      maxNewEpisodesToDownload: dto.maxNewEpisodesToDownload
    )
  }

  /// Mirrors `BookMedia.makeAudioFileCatalog`'s single-entry rule (that helper is book-specific).
  /// Audio is offline-downloadable only with a complete `ino`, positive size and duration, and
  /// non-empty `mimeType`; otherwise the episode still decodes but is not offline-downloadable.
  /// Internal because the recent-episodes shelf decodes the same objects and must apply it too.
  static func validatedAudioFile(from entry: AudioFileEntryDTO?) -> PodcastEpisodeAudio? {
    guard let entry,
      let ino = entry.ino, ino.isEmpty == false,
      let expectedSize = entry.size, expectedSize > 0,
      let mimeType = entry.mimeType, mimeType.isEmpty == false,
      let duration = entry.duration, duration.isFinite, duration > 0
    else { return nil }
    return PodcastEpisodeAudio(ino: ino, expectedSize: expectedSize, mimeType: mimeType, duration: duration)
  }
}

/// The stored, server-downloaded audio backing one podcast episode (`episode.audioFile`). `ino` is
/// the same file-identity string `AudioFileInfo`/`EbookFileInfo` carry and resolves through the
/// same `GET /api/items/{id}/file/{fileid}/download` route (API-CONVENTIONS rule 24).
/// `PodcastEpisode.audioFile` is `nil` whenever this identity can't be validated, which is what
/// the "not offline-downloadable" guard reads.
public struct PodcastEpisodeAudio: Sendable, Equatable {
  public let ino: String
  public let expectedSize: Int
  public let mimeType: String
  public let duration: Double

  public init(ino: String, expectedSize: Int, mimeType: String, duration: Double) {
    self.ino = ino
    self.expectedSize = expectedSize
    self.mimeType = mimeType
    self.duration = duration
  }
}

public struct PodcastEpisode: Sendable, Equatable, CustomReflectable {
  public let id: String
  /// Feed-provided episode GUID used for source reconciliation. This is distinct from the
  /// Audiobookshelf episode id and may be absent on older or malformed payloads.
  public let guid: String?
  /// Feed enclosure URL used for source reconciliation. Never infer this from `contentUrl`,
  /// which is the server-local playback route for the stored audio track.
  public let enclosureURL: String?
  public let title: String?
  /// Can be present-but-empty on the wire, which is distinct from absent.
  public let subtitle: String?
  /// HTML, not plain text. Stripping and rendering belong to presentation, not this wire layer.
  public let description: String?
  /// Wire `season` is a string, and `""` on an unseasoned episode. Seasoned and unseasoned
  /// episodes coexist within one show.
  public let seasonNumber: String?
  /// Wire `episode` is a string, never a number.
  public let episodeNumber: String?
  public let episodeType: String?
  public let contentUrl: String?
  public let mimeType: String?
  public let duration: Double?
  /// The episode's own byte count. Not `enclosure.length`, the feed's advertised size, which
  /// reads `"0"` on real stored episodes.
  public let size: Int?
  public let publishedAt: Date?
  /// The stored-audio identity backing offline download. `nil` when the episode has none (see
  /// `isOfflineDownloadable`).
  public let audioFile: PodcastEpisodeAudio?
  /// The episode's own chapter list from the expanded item; empty when the server sent none.
  public let chapters: [Chapter]

  /// An episode without a validated stored-audio identity is not offline-downloadable. Saves
  /// callers inferring it from `audioFile == nil`.
  public var isOfflineDownloadable: Bool { audioFile != nil }

  /// Source enclosure URLs and server-local content paths are not diagnostic data. Suppress
  /// synthesized reflection so a failed assertion cannot print either value.
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }

  public init(
    id: String,
    title: String?,
    guid: String? = nil,
    enclosureURL: String? = nil,
    subtitle: String? = nil,
    description: String? = nil,
    seasonNumber: String? = nil,
    episodeNumber: String? = nil,
    episodeType: String? = nil,
    contentUrl: String?,
    mimeType: String?,
    duration: Double?,
    size: Int? = nil,
    publishedAt: Date?,
    audioFile: PodcastEpisodeAudio? = nil,
    chapters: [Chapter] = []
  ) {
    self.id = id
    self.guid = guid
    self.enclosureURL = enclosureURL
    self.title = title
    self.subtitle = subtitle
    self.description = description
    self.seasonNumber = seasonNumber
    self.episodeNumber = episodeNumber
    self.episodeType = episodeType
    self.contentUrl = contentUrl
    self.mimeType = mimeType
    self.duration = duration
    self.size = size
    self.publishedAt = publishedAt
    self.audioFile = audioFile
    self.chapters = chapters
  }
}

extension ABSClient {
  /// `GET /api/items/{id}?expanded=1`. Fetched only on demand, never as part of a paginated list
  /// (API-CONVENTIONS rule 15).
  public func fetchItemDetail(
    account: TokenAccount,
    itemID: String,
    diagnostics: DecodeDiagnostics? = nil
  ) async throws -> ItemDetail {
    let tokens = try loadTokens(for: account)
    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/api/items/\(itemID)",
      queryItems: [URLQueryItem(name: "expanded", value: "1")],
      routeTemplate: "/api/items/:id"
    )
    let response = try await authenticatedSend(request, account: account, initialTokens: tokens)
    try validateSuccess(response)

    let wire = try decoder.decode(
      ItemDetailDTO.self,
      from: response.body,
      endpoint: "/api/items/:id",
      diagnostics: diagnostics
    )
    // Top-level shape failure (ARCHITECTURE.md §7): a missing item id means the response isn't
    // an item at all, so this is `.decoding`, not a lossy/skipped field.
    guard let id = wire.id else { throw APIError.decoding }
    return ItemDetail(dto: wire, id: id)
  }

}
