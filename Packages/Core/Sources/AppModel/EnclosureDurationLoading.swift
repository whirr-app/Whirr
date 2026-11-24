import Foundation
import Persistence

public protocol EnclosureDurationLoading: Sendable {
  func loadDuration(for enclosureURL: URL) async throws -> Double?
}

public struct NoOpEnclosureDurationLoading: EnclosureDurationLoading {
  public init() {}

  public func loadDuration(for _: URL) async throws -> Double? { nil }
}

/// Resolves a device-owned episode's playback duration without coupling Core to a media framework.
public actor RSSEpisodeDurationResolver {
  private let episodeStore: RSSEpisodeStore
  /// Where a download's own length outlives this actor; `nil` keeps it in memory only.
  private let downloadDurationStore: RSSDownloadDurationStore?
  private let loader: any EnclosureDurationLoading
  private struct MeasurementKey: Hashable, Sendable {
    let episodeID: Int64
    let sourceURL: URL
  }

  private var inFlightMeasurements: [MeasurementKey: Task<Double?, Error>] = [:]

  /// What a local file was when it was measured. Size and modification date change whenever a
  /// download is replaced, so a match means the same bytes.
  private struct LocalFileIdentity: Equatable, Sendable {
    let url: URL
    let size: Int
    let modifiedAt: Date
  }

  /// The last local measurement per episode, so replaying a download does not re-open it. It sits
  /// in front of the stored length, which a racing write to the download row can drop.
  private var localDurations: [Int64: (file: LocalFileIdentity, seconds: Double)] = [:]

  public init(
    episodeStore: RSSEpisodeStore,
    downloadDurationStore: RSSDownloadDurationStore? = nil,
    loader: any EnclosureDurationLoading = NoOpEnclosureDurationLoading()
  ) {
    self.episodeStore = episodeStore
    self.downloadDurationStore = downloadDurationStore
    self.loader = loader
  }

  /// With a `localFileURL` the file's own measured length wins: a download is a separate fetch
  /// from the one the feed describes, and dynamic ad insertion makes the two differ. Feed-declared
  /// and cached values are only the fallback when that file cannot be measured, and a local file
  /// is never probed through its remote enclosure. A file's length is stored on its download row
  /// once measured, so a later session does not open the file again.
  public func resolve(episodeId: Int64, localFileURL: URL? = nil) async throws -> Double? {
    guard let episode = try await episodeStore.fetchEpisode(episodeId: episodeId) else {
      return nil
    }
    let declared = Self.usableDuration(episode.durationSeconds)
    let cached = Self.usableDuration(episode.measuredDurationSeconds)

    if let localFileURL {
      // `measuredDurationSeconds` describes the enclosure and feeds list and resume projections,
      // so a local measurement only fills it when nothing else is known, never overwrites it.
      let isFirstKnownDuration = declared == nil && cached == nil
      let file = Self.identity(of: localFileURL)
      if let file, let memo = localDurations[episodeId], memo.file == file {
        return memo.seconds
      }
      let stored = try await downloadDurationStore?.measuredDuration(episodeId: episodeId)
      if let seconds = Self.usableDuration(stored?.seconds) {
        if let file { localDurations[episodeId] = (file, seconds) }
        return seconds
      }
      do {
        if let local = try await measure(
          episodeId: episodeId, sourceURL: localFileURL, record: isFirstKnownDuration)
        {
          if let file { localDurations[episodeId] = (file, local) }
          if let stored, let downloadDurationStore {
            // A failed or dropped write only costs a measurement on the next session's first play.
            _ = try? await downloadDurationStore.recordMeasuredDuration(
              episodeId: episodeId, observed: stored, seconds: local)
          }
          return local
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // An unreadable file falls back to what the feed says.
      }
      return declared ?? cached
    }

    if let declared { return declared }
    if let cached { return cached }
    guard let sourceURL = URL(string: episode.enclosureURL) else { return nil }
    return try await measure(episodeId: episodeId, sourceURL: sourceURL, record: true)
  }

  private func measure(episodeId: Int64, sourceURL: URL, record: Bool) async throws -> Double? {
    let measurementKey = MeasurementKey(episodeID: episodeId, sourceURL: sourceURL)
    if let inFlightMeasurement = inFlightMeasurements[measurementKey] {
      return try await inFlightMeasurement.value
    }

    let loader = self.loader
    let episodeStore = self.episodeStore
    let measurement = Task<Double?, Error> {
      let loadedDuration = try await loader.loadDuration(for: sourceURL)
      guard let duration = Self.usableDuration(loadedDuration) else { return nil }
      if record {
        try await episodeStore.recordMeasuredDuration(episodeId: episodeId, seconds: duration)
      }
      return duration
    }
    inFlightMeasurements[measurementKey] = measurement
    defer { inFlightMeasurements.removeValue(forKey: measurementKey) }

    // Actor reentrancy lets different episodes and different source URLs start their own loads
    // while one awaits; the in-flight map only coalesces callers for the same source.
    return try await measurement.value
  }

  private static func identity(of fileURL: URL) -> LocalFileIdentity? {
    // `URL` caches resource values per instance, which would hide a replaced file.
    var fileURL = fileURL
    fileURL.removeAllCachedResourceValues()
    guard
      let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
      let size = values.fileSize, let modifiedAt = values.contentModificationDate
    else { return nil }
    return LocalFileIdentity(url: fileURL, size: size, modifiedAt: modifiedAt)
  }

  private static func usableDuration(_ duration: Double?) -> Double? {
    guard let duration, duration.isFinite, duration > 0 else { return nil }
    return duration
  }
}
