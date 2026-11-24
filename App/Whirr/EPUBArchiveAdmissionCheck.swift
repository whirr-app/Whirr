import Foundation
import ReaderCore
import ReadiumShared

/// Measures a Readium container's entries so `EPUBArchiveAdmission` can judge them.
///
/// Metadata only: both lengths come from the ZIP directory, so nothing is decompressed. The pinned
/// Readium path serves entries on demand and never extracts to a directory, so expansion cost, not
/// traversal, needs bounding (see `ARCHITECTURE.md`).
enum EPUBArchiveAdmissionCheck {

  /// The refusal for this container, or nil when it may be opened.
  static func refusal(
    for container: Container,
    limits: EPUBArchiveLimits = .release
  ) async -> EPUBArchiveRefusal? {
    EPUBArchiveAdmission.refusal(
      forEntries: await measuredEntries(of: container, limits: limits),
      limits: limits
    )
  }

  /// Measures one entry past the count bound and stops. A publication with a hostile number of
  /// entries is refused on the count alone, so measuring the rest would be work done on behalf of
  /// an archive already known to be inadmissible.
  private static func measuredEntries(
    of container: Container,
    limits: EPUBArchiveLimits
  ) async -> [EPUBArchiveEntry] {
    var measured: [EPUBArchiveEntry] = []
    for url in container.entries.prefix(limits.maximumEntryCount + 1) {
      guard let resource = container[url] else { continue }
      let expandedBytes = try? await resource.estimatedLength().get()
      let archive = (try? await resource.properties().get())?.archive
      measured.append(
        EPUBArchiveEntry(
          expandedBytes: expandedBytes ?? nil,
          storedBytes: archive?.entryLength ?? 0,
          isCompressed: archive?.isEntryCompressed ?? false
        ))
    }
    return measured
  }
}
