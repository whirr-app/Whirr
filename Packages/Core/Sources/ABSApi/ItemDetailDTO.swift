import Foundation

/// The item-detail wire shape. Internal because the batch-get envelope
/// (`{"libraryItems": [ItemDetailExpanded, ...]}`) reuses this per-item shape, so `BatchGet.swift`
/// decodes an array of these rather than duplicating the book/podcast branching.
struct ItemDetailDTO: Decodable {
  let id: String?
  let libraryId: String?
  let mediaType: String?
  let book: BookMediaDTO?
  let podcast: PodcastMediaDTO?
  /// Item-root `libraryFiles[]`, a sibling of `media`. Decoded for books only: a podcast's are all
  /// episode audio and never yield a supplement.
  let libraryFiles: [EbookFileDTO]

  private enum CodingKeys: String, CodingKey { case id, libraryId, mediaType, media, libraryFiles }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // `.reject` + `try?`: a truncated server item id would address a different row. A `nil` id
    // fails `fetchItemDetail` as a top-level shape error and falls out of `batchGetItems`/search
    // through their `requiredKey` filter, rather than each page failing.
    id = try? container.decodeBoundedString(forKey: .id, policy: .reject)
    libraryId = try container.decodeIfPresent(String.self, forKey: .libraryId)
    mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)

    // `mediaType` ("book" or "podcast") is the discriminator. An unrecognised or missing value
    // leaves `media` nil rather than guessing a shape or throwing; id/libraryID/mediaType still
    // decode.
    switch mediaType {
    case "book":
      book = try container.decodeIfPresent(BookMediaDTO.self, forKey: .media)
      podcast = nil
      // Supplements are extras: no shape of this array may fail the item.
      libraryFiles =
        (try? container.decodeLossyArrayIfPresent(forKey: .libraryFiles) as [EbookFileDTO]) ?? []
    case "podcast":
      book = nil
      podcast = try? container.decode(PodcastMediaDTO.self, forKey: .media)
      libraryFiles = []
    default:
      book = nil
      podcast = nil
      libraryFiles = []
    }
  }
}

struct BookMediaDTO: Decodable {
  let title: String?
  let subtitle: String?
  let authorName: String?
  let narratorName: String?
  let seriesName: String?
  let description: String?
  let duration: Double?
  let audioFiles: [AudioFileEntryDTO]
  let tracks: [AudioTrackDTO]
  let chapters: [ChapterDTO]
  let ebookFile: EbookFileDTO?

  private enum CodingKeys: String, CodingKey { case metadata, duration, audioFiles, tracks, chapters, ebookFile }
  private enum MetadataCodingKeys: String, CodingKey {
    case title, subtitle, authorName, narratorName, seriesName, description
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let metadata = try? container.nestedContainer(keyedBy: MetadataCodingKeys.self, forKey: .metadata) {
      title = try metadata.decodeBoundedString(forKey: .title)
      subtitle = try metadata.decodeBoundedString(forKey: .subtitle)
      authorName = try metadata.decodeBoundedString(forKey: .authorName)
      narratorName = try metadata.decodeBoundedString(forKey: .narratorName)
      seriesName = try metadata.decodeBoundedString(forKey: .seriesName)
      description = try metadata.decodeBoundedString(forKey: .description)
    } else {
      title = nil
      subtitle = nil
      authorName = nil
      narratorName = nil
      seriesName = nil
      description = nil
    }
    duration = try container.decode(LossyOptional<Double>.self, forKey: .duration).wrappedValue
    // Missing/null arrays are optional; a present wrong-typed or oversized array fails the item
    // decode. No `validating`/`requiredKey` filter on audioFiles: every decoded entry, valid or
    // not, must reach `BookMedia.makeAudioFileCatalog(from:)` so it can count the invalid ones.
    audioFiles = try container.decodeLossyArrayIfPresent(forKey: .audioFiles)
    tracks = try container.decodeLossyArrayIfPresent(
      forKey: .tracks, validating: { $0.index != nil }, requiredKey: "index")
    chapters = try container.decodeLossyArrayIfPresent(
      forKey: .chapters, validating: { $0.id != nil }, requiredKey: "id")
    if let file = try? container.decodeIfPresent(EbookFileDTO.self, forKey: .ebookFile) {
      ebookFile = file
    } else {
      ebookFile = nil
    }
  }
}

/// Every field is optional and every decode step never throws, including `init(from:)` falling
/// back to an all-nil value for a non-object array element. So `LossyArray` never drops one of
/// these before `BookMedia.makeAudioFileCatalog(from:)` can count it as invalid. `filename`, `ext`
/// and `path` are not carried.
struct AudioFileEntryDTO: Decodable {
  let index: Int?
  let ino: String?
  let duration: Double?
  let mimeType: String?
  let size: Int?

  private enum CodingKeys: String, CodingKey { case index, ino, duration, mimeType, metadata }
  private enum MetadataCodingKeys: String, CodingKey { case size }

  init(from decoder: Decoder) throws {
    guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
      index = nil
      ino = nil
      duration = nil
      mimeType = nil
      size = nil
      return
    }
    index = try container.decode(LossyOptional<Int>.self, forKey: .index).wrappedValue
    ino = try container.decodeFileIdentifier(forKey: .ino)
    duration = try container.decode(LossyOptional<Double>.self, forKey: .duration).wrappedValue
    mimeType = try container.decodeBoundedString(forKey: .mimeType)
    if let metadata = try? container.nestedContainer(keyedBy: MetadataCodingKeys.self, forKey: .metadata) {
      size = try metadata.decode(LossyOptional<Int>.self, forKey: .size).wrappedValue
    } else {
      size = nil
    }
  }
}

struct AudioTrackDTO: Decodable {
  let index: Int?
  let startOffset: Double?
  let duration: Double?
  let title: String?
  let contentUrl: String?
  let mimeType: String?

  private enum CodingKeys: String, CodingKey { case index, startOffset, duration, title, contentUrl, mimeType }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    index = try container.decode(LossyOptional<Int>.self, forKey: .index).wrappedValue
    startOffset = try container.decode(LossyOptional<Double>.self, forKey: .startOffset).wrappedValue
    duration = try container.decode(LossyOptional<Double>.self, forKey: .duration).wrappedValue
    title = try container.decodeBoundedString(forKey: .title)
    contentUrl = try container.decodeBoundedString(forKey: .contentUrl)
    mimeType = try container.decodeBoundedString(forKey: .mimeType)
  }
}

struct ChapterDTO: Decodable {
  let id: Int?
  let start: Double?
  let end: Double?
  let title: String?

  private enum CodingKeys: String, CodingKey { case id, start, end, title }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(LossyOptional<Int>.self, forKey: .id).wrappedValue
    start = try container.decode(LossyOptional<Double>.self, forKey: .start).wrappedValue
    end = try container.decode(LossyOptional<Double>.self, forKey: .end).wrappedValue
    title = try container.decodeBoundedString(forKey: .title)
  }
}

struct EbookFileDTO: Decodable {
  let ino: String?
  let ext: String?
  let filename: String?
  let size: Int?

  private enum CodingKeys: String, CodingKey { case ino, metadata }
  private enum MetadataCodingKeys: String, CodingKey { case ext, filename, size }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    ino = try container.decodeFileIdentifier(forKey: .ino)
    if let metadata = try? container.nestedContainer(keyedBy: MetadataCodingKeys.self, forKey: .metadata) {
      ext = try metadata.decodeBoundedString(forKey: .ext)
      filename = try metadata.decodeBoundedString(forKey: .filename)
      size = try metadata.decode(LossyOptional<Int>.self, forKey: .size).wrappedValue
    } else {
      ext = nil
      filename = nil
      size = nil
    }
  }
}

struct PodcastMediaDTO: Decodable {
  let title: String?
  let author: String?
  let description: String?
  let episodes: [PodcastEpisodeDTO]
  let isEpisodeListStructurallyComplete: Bool
  let autoDownloadEpisodes: Bool?
  let autoDownloadSchedule: String?
  let lastEpisodeCheck: Date?
  let maxEpisodesToKeep: Int?
  let maxNewEpisodesToDownload: Int?

  private enum CodingKeys: String, CodingKey {
    case metadata, episodes, autoDownloadEpisodes, autoDownloadSchedule, lastEpisodeCheck,
      maxEpisodesToKeep, maxNewEpisodesToDownload
  }
  private enum MetadataCodingKeys: String, CodingKey { case title, author, description }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let metadata = try? container.nestedContainer(keyedBy: MetadataCodingKeys.self, forKey: .metadata) {
      title = try metadata.decodeBoundedString(forKey: .title)
      author = try metadata.decodeBoundedString(forKey: .author)
      description = try metadata.decodeBoundedString(forKey: .description)
    } else {
      title = nil
      author = nil
      description = nil
    }
    let decodedEpisodes: [PodcastEpisodeDTO]? =
      try? container.decodeLossyArray(
        forKey: .episodes, validating: { $0.id != nil }, requiredKey: "id")
    if container.contains(.episodes), let decodedEpisodes {
      episodes = decodedEpisodes
      isEpisodeListStructurallyComplete = true
    } else {
      episodes = []
      isEpisodeListStructurallyComplete = false
    }
    autoDownloadEpisodes =
      try container.decode(LossyOptional<Bool>.self, forKey: .autoDownloadEpisodes).wrappedValue
    autoDownloadSchedule = try container.decodeBoundedString(forKey: .autoDownloadSchedule)
    lastEpisodeCheck = try container.decodeEpochMillisDate(forKey: .lastEpisodeCheck)
    maxEpisodesToKeep =
      try container.decode(LossyOptional<Int>.self, forKey: .maxEpisodesToKeep).wrappedValue
    maxNewEpisodesToDownload =
      try container.decode(LossyOptional<Int>.self, forKey: .maxNewEpisodesToDownload).wrappedValue
  }
}

/// Every field is optional and every decode step is loss-tolerant (API-CONVENTIONS rule 21). A
/// server sending `season`/`episode` as numbers, a null `audioFile`, or an oversized description
/// degrades individual fields to `nil` rather than dropping the episode. Only a missing `id` does
/// that, filtered by `PodcastMediaDTO`'s `decodeLossyArray` call.
struct PodcastEpisodeDTO: Decodable {
  let id: String?
  let guid: String?
  let enclosureURL: String?
  let title: String?
  let subtitle: String?
  let description: String?
  let seasonNumber: String?
  let episodeNumber: String?
  let episodeType: String?
  let contentUrl: String?
  let mimeType: String?
  let duration: Double?
  let size: Int?
  let publishedAt: Date?
  /// The raw stored-audio wire entry; `PodcastMedia.validatedAudioFile(from:)` turns this into the
  /// public `PodcastEpisodeAudio?` after applying the identity/validation rule.
  let audioFile: AudioFileEntryDTO?
  let chapters: [ChapterDTO]

  private enum CodingKeys: String, CodingKey {
    case id, guid, enclosure, title, subtitle, description, season, episode, episodeType, size,
      audioTrack, publishedAt, duration, audioFile, chapters
  }
  private enum AudioTrackCodingKeys: String, CodingKey { case contentUrl, mimeType }
  private enum EnclosureCodingKeys: String, CodingKey { case url }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id)
    do {
      guid = try container.decodeBoundedString(forKey: .guid, policy: .reject)
    } catch {
      guid = nil
    }
    if let enclosure = try? container.nestedContainer(keyedBy: EnclosureCodingKeys.self, forKey: .enclosure) {
      do {
        enclosureURL = try enclosure.decodeBoundedString(forKey: .url, policy: .reject)
      } catch {
        enclosureURL = nil
      }
    } else {
      enclosureURL = nil
    }
    title = try container.decodeBoundedString(forKey: .title)
    subtitle = try container.decodeBoundedString(forKey: .subtitle)
    description = try container.decodeBoundedString(forKey: .description)
    seasonNumber = try container.decodeBoundedString(forKey: .season)
    episodeNumber = try container.decodeBoundedString(forKey: .episode)
    episodeType = try container.decodeBoundedString(forKey: .episodeType)
    size = try container.decode(LossyOptional<Int>.self, forKey: .size).wrappedValue
    duration = try container.decode(LossyOptional<Double>.self, forKey: .duration).wrappedValue
    publishedAt = try container.decodeEpochMillisDate(forKey: .publishedAt)
    if let audioTrack = try? container.nestedContainer(keyedBy: AudioTrackCodingKeys.self, forKey: .audioTrack) {
      contentUrl = try audioTrack.decodeBoundedString(forKey: .contentUrl)
      mimeType = try audioTrack.decodeBoundedString(forKey: .mimeType)
    } else {
      contentUrl = nil
      mimeType = nil
    }
    audioFile = try? container.decodeIfPresent(AudioFileEntryDTO.self, forKey: .audioFile)
    // Same rule as a book's chapters. A malformed `chapters` must not drop the episode, so a
    // wrong-typed or oversized array degrades to none rather than failing the show decode.
    chapters =
      (try? container.decodeLossyArrayIfPresent(
        forKey: .chapters, validating: { (chapter: ChapterDTO) in chapter.id != nil },
        requiredKey: "id")) ?? []
  }
}
