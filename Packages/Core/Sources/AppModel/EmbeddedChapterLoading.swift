import Foundation
import Persistence

/// One chapter found inside an audio file. Times are seconds on the file's own timeline.
public struct EmbeddedChapter: Equatable, Sendable {
  public let start: Double
  public let end: Double
  public let title: String?

  public init(start: Double, end: Double, title: String?) {
    self.start = start
    self.end = end
    self.title = title
  }
}

/// Reads the chapters embedded in a local audio file (ID3 `CHAP`, MP4 chapter tracks) without
/// coupling Core to a media framework.
public protocol EmbeddedChapterLoading: Sendable {
  func loadChapters(from localFileURL: URL) async throws -> [EmbeddedChapter]
}

public struct NoOpEmbeddedChapterLoading: EmbeddedChapterLoading {
  public init() {}

  public func loadChapters(from _: URL) async throws -> [EmbeddedChapter] { [] }
}

/// Resolves the embedded chapters of a downloaded native RSS episode, parsing each download once.
/// A file with no chapters is cached as such, so playback start does not re-parse it. Any failure
/// to read or store chapters yields none: chapters are an enhancement and must not stop playback.
public actor RSSEpisodeChapterResolver {
  private let chapterStore: RSSEpisodeChapterStore
  private let loader: any EmbeddedChapterLoading
  private struct ExtractionKey: Hashable, Sendable {
    let episodeID: Int64
    let downloadID: Int64
    let completedAt: Date
  }

  private struct Extraction {
    let task: Task<[EmbeddedChapter], Error>
    var waiters: Set<UUID>
  }

  private var inFlightExtractions: [ExtractionKey: Extraction] = [:]

  public init(
    chapterStore: RSSEpisodeChapterStore,
    loader: any EmbeddedChapterLoading = NoOpEmbeddedChapterLoading()
  ) {
    self.chapterStore = chapterStore
    self.loader = loader
  }

  /// Only cancellation is thrown. `localFileURL` must be the validated file of the episode's
  /// completed download; with no completed download the result is empty and nothing is parsed.
  /// The parse is shared between concurrent callers and cancelled once its last waiting caller is,
  /// so a superseded playback start does not sit out a parse nobody needs.
  public func resolve(episodeId: Int64, localFileURL: URL) async throws -> [EmbeddedChapter] {
    let cache: RSSEpisodeChapterCache?
    do {
      cache = try await chapterStore.cache(episodeId: episodeId)
    } catch {
      try Task.checkCancellation()
      return []
    }
    guard let cache else { return [] }
    if let cached = cache.chapters {
      return cached.map { EmbeddedChapter(start: $0.start, end: $0.end, title: $0.title) }
    }
    try Task.checkCancellation()

    let key = ExtractionKey(
      episodeID: episodeId, downloadID: cache.downloadId, completedAt: cache.completedAt)
    let waiterID = UUID()
    let task = joinOrStart(key: key, cache: cache, localFileURL: localFileURL, waiterID: waiterID)
    return try await withTaskCancellationHandler {
      defer { release(key: key, waiterID: waiterID, cancelling: Task.isCancelled) }
      let chapters = try await task.value
      try Task.checkCancellation()
      return chapters
    } onCancel: {
      Task { await self.release(key: key, waiterID: waiterID, cancelling: true) }
    }
  }

  private func joinOrStart(
    key: ExtractionKey, cache: RSSEpisodeChapterCache, localFileURL: URL, waiterID: UUID
  ) -> Task<[EmbeddedChapter], Error> {
    if var existing = inFlightExtractions[key] {
      existing.waiters.insert(waiterID)
      inFlightExtractions[key] = existing
      return existing.task
    }
    let loader = self.loader
    let chapterStore = self.chapterStore
    let task = Task<[EmbeddedChapter], Error> {
      let chapters: [EmbeddedChapter]
      do {
        chapters = Self.normalized(try await loader.loadChapters(from: localFileURL))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // An unparseable file is not cached: a transient failure should get another attempt.
        try Task.checkCancellation()
        return []
      }
      try Task.checkCancellation()
      // A lost write only costs a re-parse on the next play.
      _ = try? await chapterStore.recordExtraction(
        episodeId: key.episodeID, cache: cache,
        chapters: chapters.map { RSSStoredChapter(start: $0.start, end: $0.end, title: $0.title) })
      return chapters
    }
    inFlightExtractions[key] = Extraction(task: task, waiters: [waiterID])
    return task
  }

  /// The cancellation handler and the waiter's own exit both release, so the second is a no-op.
  private func release(key: ExtractionKey, waiterID: UUID, cancelling: Bool) {
    guard var entry = inFlightExtractions[key], entry.waiters.remove(waiterID) != nil else {
      return
    }
    guard entry.waiters.isEmpty else {
      inFlightExtractions[key] = entry
      return
    }
    if cancelling { entry.task.cancel() }
    inFlightExtractions[key] = nil
  }

  /// Drops ranges that cannot be seeked to, orders by start, and turns blank titles into `nil`.
  static func normalized(_ chapters: [EmbeddedChapter]) -> [EmbeddedChapter] {
    chapters
      .filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
      .sorted { $0.start < $1.start }
      .map { chapter in
        let title = chapter.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return EmbeddedChapter(
          start: chapter.start, end: chapter.end,
          title: title?.isEmpty == false ? title : nil)
      }
  }
}
