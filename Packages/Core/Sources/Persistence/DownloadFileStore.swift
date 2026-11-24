import Foundation

/// The response metadata a background transfer's finish event carries (from the
/// `BackgroundTransferring` event stream), including the raw `Content-Range` value. It passes
/// unchanged into validation here: this store, not the App adapter, owns the status/MIME/final-size
/// decision (see SECURITY.md).
public struct DownloadTransferResponse: Sendable, Equatable {
  public let httpStatusCode: Int
  public let mimeType: String?
  public let contentLength: Int64?
  public let contentRange: String?

  public init(
    httpStatusCode: Int, mimeType: String? = nil, contentLength: Int64? = nil,
    contentRange: String? = nil
  ) {
    self.httpStatusCode = httpStatusCode
    self.mimeType = mimeType
    self.contentLength = contentLength
    self.contentRange = contentRange
  }
}

/// Which of `completeTransfer`'s guards rejected the response. All fail the row as `.validation`,
/// so the durable category alone cannot say which, and they differ diagnostically: a length
/// mismatch means the server's recorded size disagrees with the bytes it served (stale library-scan
/// metadata, which no retry can clear), while a MIME mismatch means the response was not the file
/// at all. Bounded and privacy-safe: it names the guard, never the values compared.
public enum DownloadValidationReason: String, Equatable, Sendable {
  case httpStatus
  case mimeType
  case contentLength
  case contentRangeTotal
  case onDiskSize
}

/// Thrown when `completeTransfer` rejects a finished transfer. The row has already been moved to
/// `failed` with this category by then. Privacy-safe and category-only, like `DownloadStoreError`.
/// `validationReason` is non-nil only for `.validation`, whose single category would otherwise
/// collapse four unrelated causes into one.
public struct DownloadCompletionFailure: Error, Equatable, Sendable {
  public let category: DownloadErrorCategory
  public let validationReason: DownloadValidationReason?

  public init(
    category: DownloadErrorCategory, validationReason: DownloadValidationReason? = nil
  ) {
    self.category = category
    self.validationReason = validationReason
  }
}

public enum DownloadFileStoreError: Error, Equatable, Sendable {
  case downloadNotFound(Int64)
}

/// Download file layout, protection, and integrity (see SECURITY.md). Owns validation of the file
/// the App adapter preserved at its deterministic, account-scoped destination before URLSession's
/// delegate callback returned, the separate DB transaction marking the row `completed`, and the
/// recoverable deletion protocol. An unmoved temporary file from a test or alternate adapter is
/// moved once. Lives under Application Support, never Caches: system eviction there would break
/// the invariant that no DB row points at a missing playable file.
public struct DownloadFileStore: Sendable {
  public let rootURL: URL
  private let fileAttributes: FileAttributeApplying
  private let downloadStore: DownloadStore
  private let fileMover: DownloadFileMoving

  /// Creates (if needed) and protects the downloads root before any file is written into it, as
  /// `AppDatabase.onDisk` does for the database directory. Protection is re-applied and re-verified
  /// on every construction (every launch), like the database's own attributes.
  public init(
    rootURL: URL,
    fileAttributes: FileAttributeApplying,
    downloadStore: DownloadStore,
    fileMover: DownloadFileMoving = POSIXDownloadFileMover()
  ) throws {
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try fileAttributes.protectDownloadsRoot(at: rootURL)
    self.rootURL = rootURL
    self.fileAttributes = fileAttributes
    self.downloadStore = downloadStore
    self.fileMover = fileMover
  }

  // MARK: - Deterministic destinations

  /// A deterministic, account-scoped relative path. Never absolute, so nothing persisted in the
  /// `download` table depends on where the app container lives between launches. Callers join it
  /// against `absoluteURL(forRelativePath:)` at the point of use.
  public static func destinationRelativePath(
    accountId: Int64,
    itemId: Int64,
    podcastEpisodeId: Int64?,
    orderIndex: Int,
    serverFileIno: String,
    mimeType: String
  ) -> String {
    let episodeSegment = podcastEpisodeId.map { "ep-\($0)/" } ?? ""
    let sanitizedIno = sanitizePathComponent(serverFileIno)
    let ext = fileExtension(forMimeType: mimeType)
    return "\(accountId)/\(itemId)/\(episodeSegment)\(orderIndex)-\(sanitizedIno).\(ext)"
  }

  /// Resolves a stored relative path to an absolute location under this store's root. The DB never
  /// persists the absolute form.
  public func absoluteURL(forRelativePath relativePath: String) -> URL {
    rootURL.appendingPathComponent(relativePath)
  }

  // MARK: - Completion

  /// Validates `response` against the row's expected MIME/size, moves an unmoved temp file into
  /// place if needed, verifies the final on-disk size, and only then commits the DB completion
  /// transaction. Production's background adapter has already moved the file before emitting its
  /// event, so that path validates in place and never moves or deletes the same URL twice.
  ///
  /// The gap between that move and this commit is routine, not only a crash: a transfer finishing
  /// while the app is terminated is moved during relaunch, before any coordinator exists, and the
  /// launch rewrite has already made the row `.interrupted`. The coordinator reattaches it before
  /// completing; until then it stays uncompleted (never phantom-playable) with the file in place,
  /// and a fresh transfer would overwrite it.
  @discardableResult
  public func completeTransfer(
    downloadId: Int64,
    temporaryFileURL: URL,
    response: DownloadTransferResponse
  ) throws -> DownloadRecord {
    guard let record = try downloadStore.fetch(downloadId: downloadId) else {
      throw DownloadFileStoreError.downloadNotFound(downloadId)
    }

    guard (200...299).contains(response.httpStatusCode) else {
      try quarantineAndFail(
        downloadId: downloadId, temporaryFileURL: temporaryFileURL, category: .validation,
        validationReason: .httpStatus)
    }
    if let mimeType = response.mimeType,
      Self.baseMimeType(mimeType) != Self.baseMimeType(record.expectedMimeType)
    {
      try quarantineAndFail(
        downloadId: downloadId, temporaryFileURL: temporaryFileURL, category: .validation,
        validationReason: .mimeType)
    }
    if response.httpStatusCode == 206 {
      if let total = Self.contentRangeTotal(response.contentRange), total != record.expectedBytes {
        try quarantineAndFail(
          downloadId: downloadId, temporaryFileURL: temporaryFileURL, category: .validation,
          validationReason: .contentRangeTotal)
      }
    } else if let contentLength = response.contentLength, contentLength != record.expectedBytes {
      try quarantineAndFail(
        downloadId: downloadId, temporaryFileURL: temporaryFileURL, category: .validation,
        validationReason: .contentLength)
    }

    let destinationURL = absoluteURL(forRelativePath: record.destinationRelativePath)
    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let sourceIsDestination =
      temporaryFileURL.standardizedFileURL == destinationURL.standardizedFileURL
    if sourceIsDestination == false {
      // A stale orphan from a previous crashed attempt at this exact destination (rename
      // succeeded, commit never happened) must not block this attempt's rename.
      if FileManager.default.fileExists(atPath: destinationURL.path) {
        try FileManager.default.removeItem(at: destinationURL)
      }

      do {
        try fileMover.moveItem(at: temporaryFileURL, to: destinationURL)
      } catch {
        if Self.isOutOfSpace(error) {
          try quarantineAndFail(downloadId: downloadId, temporaryFileURL: nil, category: .lowDisk)
        }
        throw error
      }
    }

    guard let actualSize = try Self.fileSize(at: destinationURL), actualSize == record.expectedBytes
    else {
      try quarantineAndFail(
        downloadId: downloadId, temporaryFileURL: nil, destinationFileURL: destinationURL,
        category: .validation, validationReason: .onDiskSize)
    }

    do {
      try fileAttributes.protectDownloadedFile(at: destinationURL)
    } catch {
      try quarantineAndFail(
        downloadId: downloadId, temporaryFileURL: nil, destinationFileURL: destinationURL,
        category: .storage)
    }

    // The separate DB completion transaction: only reached once the file is verified in place.
    return try downloadStore.complete(downloadId: downloadId, finalSizeBytes: actualSize)
  }

  /// Deletes the temp/destination file (whichever is relevant) and fails the row with `category`,
  /// then throws `DownloadCompletionFailure` so the caller learns what happened. Never returns.
  private func quarantineAndFail(
    downloadId: Int64,
    temporaryFileURL: URL?,
    destinationFileURL: URL? = nil,
    category: DownloadErrorCategory,
    validationReason: DownloadValidationReason? = nil
  ) throws -> Never {
    if let temporaryFileURL {
      try? FileManager.default.removeItem(at: temporaryFileURL)
    }
    if let destinationFileURL {
      try? FileManager.default.removeItem(at: destinationFileURL)
    }
    _ = try? downloadStore.transition(downloadId: downloadId, to: .failed, errorCategory: category)
    throw DownloadCompletionFailure(category: category, validationReason: validationReason)
  }

  // MARK: - Recoverable deletion protocol

  /// Transactionally marks the row `deleting` (idempotent if it already is), deletes the file
  /// idempotently, then deletes the row. A crash at either boundary leaves the row `deleting`,
  /// which `DownloadIntegritySweep` resumes on the next launch. Playback and scheduling ignore
  /// `deleting` rows (`DownloadRecord.isPlayable`/`isSchedulable`).
  public func delete(downloadId: Int64) throws {
    guard var record = try downloadStore.fetch(downloadId: downloadId) else {
      throw DownloadFileStoreError.downloadNotFound(downloadId)
    }
    if record.state != .deleting {
      record = try downloadStore.transition(downloadId: downloadId, to: .deleting)
    }
    try removeFileIfPresent(relativePath: record.destinationRelativePath)
    try downloadStore.finalizeDeletion(downloadId: downloadId)
  }

  func removeFileIfPresent(relativePath: String) throws {
    guard StoragePath.isContained(relativePath: relativePath, under: rootURL) else { return }
    let url = absoluteURL(forRelativePath: relativePath)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  // MARK: - Helpers

  private static func fileSize(at url: URL) throws -> Int64? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.int64Value
  }

  /// Strips MIME parameters (e.g. `; charset=...`) and normalises case before comparison. The
  /// server's `Content-Type` and the catalog's `expectedMimeType` need not be byte-identical to
  /// agree.
  private static func baseMimeType(_ mimeType: String) -> String {
    (mimeType.split(separator: ";").first.map(String.init) ?? mimeType)
      .trimmingCharacters(in: .whitespaces)
      .lowercased()
  }

  /// Shared with `RSSFileStore`, whose `206` handling reads the same header.
  static func contentRangeTotal(_ contentRange: String?) -> Int64? {
    guard let contentRange, let slash = contentRange.firstIndex(of: "/") else { return nil }
    let range = contentRange[..<slash].trimmingCharacters(in: .whitespaces)
    let totalString = contentRange[contentRange.index(after: slash)...]
      .trimmingCharacters(in: .whitespaces)
    guard totalString != "*", let total = Int64(totalString) else { return nil }

    let rangeParts = range.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard rangeParts.count == 2, rangeParts[0].lowercased() == "bytes" else { return nil }
    let bounds = rangeParts[1].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard bounds.count == 2, Int64(bounds[0]) != nil, Int64(bounds[1]) != nil else { return nil }
    return total
  }

  /// Shared with `RSSFileStore`: the same disk-full classification must pause the same queue.
  static func isOutOfSpace(_ error: Error) -> Bool {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
      return true
    }
    if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) {
      return true
    }
    return false
  }

  private static func sanitizePathComponent(_ raw: String) -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
    let sanitized = String(scalars)
    return sanitized.isEmpty ? "_" : sanitized
  }

  /// A deterministic file extension derived from the MIME type. MPEG audio needs an explicit
  /// mapping: `.mpeg` conventionally identifies an MPEG program/video stream, and AVFoundation
  /// rejects an MP3 bitstream stored under that extension with `AVErrorFileFormatNotRecognized`.
  /// Other subtypes use the generic mapping.
  private static func fileExtension(forMimeType mimeType: String) -> String {
    let base =
      (mimeType.split(separator: ";").first.map(String.init) ?? mimeType)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    if base == "audio/mpeg" || base == "audio/mp3" || base == "audio/x-mpeg" {
      return "mp3"
    }
    // iOS's EPUB reader admission is extension-sensitive, and the generic subtype of
    // `application/epub+zip` would become `epub+zip`, not the required suffix.
    if base == "application/epub+zip" {
      return "epub"
    }

    let subtype = base.split(separator: "/").last.map(String.init) ?? "bin"
    let normalized = subtype.hasPrefix("x-") ? String(subtype.dropFirst(2)) : subtype
    let sanitized = sanitizePathComponent(normalized)
    return sanitized.isEmpty ? "bin" : sanitized
  }
}
