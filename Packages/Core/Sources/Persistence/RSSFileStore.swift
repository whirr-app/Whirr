import Foundation

/// The closed, privacy-safe reason `RSSFileStore.completeTransfer` rejected a finished transfer.
/// Names the guard that fired and never the values it compared, so the device trace can carry it
/// without leaking feed metadata.
public enum RSSTransferRejection: String, Equatable, Sendable {
  case invalidEnclosureType
  case invalidRelativePath
  case invalidHTTPStatus
  case invalidMIMEType
  case sizeLimitExceeded
  case responseSizeMismatch
  case missingFile
  case invalidFile
  case storageFailure
}

/// Errors raised while validating an RSS enclosure. The values carry no URL or server-provided
/// text, so callers can log the category without leaking feed metadata.
public enum RSSFileStoreError: Error, Equatable, Sendable {
  case downloadNotFound(Int64)
  case invalidEnclosureType
  case invalidRelativePath
  case invalidHTTPStatus
  case invalidMIMEType
  case sizeLimitExceeded
  /// The bytes on disk disagree with the final HTTP response's own length (a truncated or
  /// over-long body), never with the feed's declared enclosure length.
  case responseSizeMismatch
  case missingFile
  case invalidFile
  case storageFailure

  /// The trace reason for a rejected transfer; `nil` for `downloadNotFound`, which rejects nothing.
  public var rejection: RSSTransferRejection? {
    switch self {
    case .downloadNotFound: nil
    case .invalidEnclosureType: .invalidEnclosureType
    case .invalidRelativePath: .invalidRelativePath
    case .invalidHTTPStatus: .invalidHTTPStatus
    case .invalidMIMEType: .invalidMIMEType
    case .sizeLimitExceeded: .sizeLimitExceeded
    case .responseSizeMismatch: .responseSizeMismatch
    case .missingFile: .missingFile
    case .invalidFile: .invalidFile
    case .storageFailure: .storageFailure
    }
  }

  /// The durable category the row is failed with. Only a write or protection failure is a
  /// `.storage` problem; everything else is the response or the file failing validation.
  public var errorCategory: DownloadErrorCategory {
    self == .storageFailure ? .storage : .validation
  }
}

/// The non-account RSS sibling of `DownloadFileStore`. `rootURL` is the shared downloads root;
/// all RSS paths sit below its `RSS/` child, so they never collide with a numeric ABS account
/// directory.
public struct RSSFileStore: Sendable {
  /// The absolute per-transfer cap for every RSS enclosure (ADR 0004; SECURITY.md). A feed's
  /// declared length neither raises nor lowers it: declared lengths lie, so the cap is the only
  /// size bound a third-party enclosure is held to.
  public static let sizeCapBytes: Int64 = 1_073_741_824
  public static let unknownSizeReserveBytes: Int64 = 500_000_000
  public static let admissionHeadroomFraction = 0.10
  public static let admissionHeadroomMinimumBytes: Int64 = 1_048_576

  /// Bytes that must be available before admission. The declared length is used only here, as a
  /// free-space estimate rather than a bound. Unknown enclosures reserve the full cap plus the
  /// safety reserve; declared lengths get 10%/1 MiB of headroom.
  public static func admissionBytes(expectedBytes: Int64?) -> Int64 {
    guard let expectedBytes, expectedBytes > 0 else {
      return sizeCapBytes + unknownSizeReserveBytes
    }
    let headroom = max(
      Int64(Double(expectedBytes) * admissionHeadroomFraction),
      admissionHeadroomMinimumBytes)
    let (admission, overflow) = expectedBytes.addingReportingOverflow(headroom)
    return overflow ? Int64.max : admission
  }

  public let rootURL: URL
  public let rssRootURL: URL
  private let fileAttributes: FileAttributeApplying
  private let downloadStore: RSSDownloadStore
  private let fileMover: DownloadFileMoving

  public init(
    rootURL: URL, fileAttributes: FileAttributeApplying, downloadStore: RSSDownloadStore,
    fileMover: DownloadFileMoving = POSIXDownloadFileMover()
  ) throws {
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try fileAttributes.protectDownloadsRoot(at: rootURL)
    let rssRootURL = rootURL.appendingPathComponent(RSSFileRoot.directoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: rssRootURL, withIntermediateDirectories: true)
    try fileAttributes.protectDownloadsRoot(at: rssRootURL)
    self.rootURL = rootURL
    self.rssRootURL = rssRootURL
    self.fileAttributes = fileAttributes
    self.downloadStore = downloadStore
    self.fileMover = fileMover
  }

  /// Exact RSS layout required by ADR 0004: no account segment, no user-controlled filename.
  public static func destinationRelativePath(
    feedId: Int64, episodeRowId: Int64, enclosureURL: URL, enclosureMimeType: String? = nil
  ) -> String {
    let extensionName = safeExtension(mimeType: enclosureMimeType, url: enclosureURL)
    return "\(RSSFileRoot.directoryName)/\(feedId)/\(episodeRowId).\(extensionName)"
  }

  public static func destinationRelativePath(
    feedId: Int64, episodeRowId: Int64, enclosureURL: URL, enclosureType: String?
  ) -> String {
    destinationRelativePath(
      feedId: feedId, episodeRowId: episodeRowId, enclosureURL: enclosureURL,
      enclosureMimeType: enclosureType)
  }

  public func absoluteURL(forRelativePath relativePath: String) -> URL {
    rootURL.appendingPathComponent(relativePath)
  }

  /// Resolves one persisted transfer destination only when it remains below the non-account RSS
  /// root. Scheduling uses this before handing an absolute path to the background adapter.
  public func transferDestinationURL(forRelativePath relativePath: String) throws -> URL {
    let url = absoluteURL(forRelativePath: relativePath)
    guard isSafeRSSPath(relativePath, destinationURL: url) else {
      throw RSSFileStoreError.invalidRelativePath
    }
    return url
  }

  /// Moves, validates, protects, and then marks an RSS transfer complete.
  ///
  /// Guards: the status, the served MIME type, a non-empty file below the cap, and agreement with
  /// the final response's own length. The feed's declared enclosure length is not consulted: it is
  /// advisory, not a checksum (the BBC serves a 20 MB file for an enclosure declaring 40 MB).
  @discardableResult
  public func completeTransfer(
    downloadId: Int64, temporaryFileURL: URL, response: DownloadTransferResponse
  ) throws -> RSSDownloadRecord {
    guard let details = try downloadStore.transferDetails(downloadId: downloadId) else {
      throw RSSFileStoreError.downloadNotFound(downloadId)
    }
    guard (200...299).contains(response.httpStatusCode) else {
      try fail(downloadId: downloadId, temporaryURL: temporaryFileURL, error: .invalidHTTPStatus)
    }
    let declaredMIME = Self.baseMIME(details.episode.enclosureType)
    guard declaredMIME.isEmpty || declaredMIME.hasPrefix("audio/") else {
      try fail(downloadId: downloadId, temporaryURL: temporaryFileURL, error: .invalidEnclosureType)
    }
    if declaredMIME.isEmpty == false, let responseMIME = response.mimeType,
      Self.baseMIME(responseMIME) != declaredMIME
    {
      try fail(downloadId: downloadId, temporaryURL: temporaryFileURL, error: .invalidMIMEType)
    }
    if let responseMIME = response.mimeType,
      Self.baseMIME(responseMIME).hasPrefix("audio/") == false
    {
      try fail(downloadId: downloadId, temporaryURL: temporaryFileURL, error: .invalidEnclosureType)
    }

    let destinationURL = absoluteURL(forRelativePath: details.download.relativePath)
    guard isSafeRSSPath(details.download.relativePath, destinationURL: destinationURL) else {
      try fail(downloadId: downloadId, temporaryURL: temporaryFileURL, error: .invalidRelativePath)
    }
    let actualSize: Int64
    do {
      actualSize = try Self.fileSize(at: temporaryFileURL) ?? 0
    } catch {
      try fail(downloadId: downloadId, temporaryURL: temporaryFileURL, error: .invalidFile)
    }
    guard actualSize > 0 else {
      try fail(downloadId: downloadId, temporaryURL: temporaryFileURL, error: .invalidFile)
    }
    guard actualSize <= Self.sizeCapBytes else {
      try fail(downloadId: downloadId, temporaryURL: temporaryFileURL, error: .sizeLimitExceeded)
    }
    if let finalLength = Self.finalResponseLength(response), finalLength != actualSize {
      try fail(downloadId: downloadId, temporaryURL: temporaryFileURL, error: .responseSizeMismatch)
    }

    try FileManager.default.createDirectory(
      at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if temporaryFileURL.standardizedFileURL != destinationURL.standardizedFileURL {
      if FileManager.default.fileExists(atPath: destinationURL.path) {
        try FileManager.default.removeItem(at: destinationURL)
      }
      do { try fileMover.moveItem(at: temporaryFileURL, to: destinationURL) } catch {
        guard DownloadFileStore.isOutOfSpace(error) else {
          try fail(downloadId: downloadId, temporaryURL: temporaryFileURL, error: .storageFailure)
        }
        _ = try? downloadStore.transition(
          downloadId: downloadId, to: .failed, errorCode: .lowDisk)
        throw DownloadCompletionFailure(category: .lowDisk)
      }
    }
    guard try Self.fileSize(at: destinationURL) == actualSize else {
      try fail(downloadId: downloadId, temporaryURL: nil, destinationURL: destinationURL, error: .invalidFile)
    }
    do { try fileAttributes.protectDownloadedFile(at: destinationURL) } catch {
      try fail(
        downloadId: downloadId, temporaryURL: nil, destinationURL: destinationURL,
        error: .storageFailure)
    }
    return try downloadStore.complete(downloadId: downloadId, actualBytes: actualSize)
  }

  /// Returns a local URL only after rechecking state, containment, file kind, size, and the same
  /// protection/backup contract applied at completion. Invalid local media is not fatal: callers
  /// should fall back to the enclosure URL.
  public func validatedLocalURL(episodeId: Int64) throws -> URL? {
    guard let record = try downloadStore.fetch(episodeId: episodeId), record.state == .completed else {
      return nil
    }
    let url = absoluteURL(forRelativePath: record.relativePath)
    guard isSafeRSSPath(record.relativePath, destinationURL: url),
      let size = try Self.fileSize(at: url),
      size > 0,
      size <= Self.sizeCapBytes,
      size == record.actualBytes
    else { return nil }
    do {
      // Verifies and repairs the same protection/backup attributes applied on write.
      try fileAttributes.protectDownloadedFile(at: url)
    } catch { return nil }
    return url
  }

  /// Demotes a completed row whose file has gone missing or changed, with the same verdict the
  /// launch sweep reaches, so a play-time failure stops the Downloads screen reporting a download
  /// that no longer exists.
  public func demoteCompletedDownloadIfFileInvalid(episodeId: Int64) throws {
    try RSSDownloadIntegritySweep(rootURL: rootURL, downloadStore: downloadStore)
      .validate(episodeId: episodeId)
  }

  public func localURL(episodeId: Int64) throws -> URL? {
    try validatedLocalURL(episodeId: episodeId)
  }

  public func delete(downloadId: Int64) throws {
    guard let record = try downloadStore.fetch(downloadId: downloadId) else {
      throw RSSFileStoreError.downloadNotFound(downloadId)
    }
    let url = absoluteURL(forRelativePath: record.relativePath)
    guard isSafeRSSPath(record.relativePath, destinationURL: url) else {
      throw RSSFileStoreError.invalidRelativePath
    }
    if record.state != .deleting {
      _ = try downloadStore.transition(downloadId: downloadId, to: .deleting)
    }
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
    try downloadStore.finalizeDeletion(downloadId: downloadId)
  }

  private func fail(
    downloadId: Int64, temporaryURL: URL?, destinationURL: URL? = nil, error: RSSFileStoreError
  ) throws -> Never {
    if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
    if let destinationURL { try? FileManager.default.removeItem(at: destinationURL) }
    _ = try? downloadStore.transition(
      downloadId: downloadId, to: .failed, errorCode: error.errorCategory)
    throw error
  }

  private func isSafeRSSPath(_ path: String, destinationURL: URL) -> Bool {
    let ownershipPrefix = RSSFileRoot.directoryName + "/"
    guard path.hasPrefix(ownershipPrefix) else { return false }
    return StoragePath.relativePath(of: destinationURL, under: rssRootURL) != nil
  }

  /// The length the final response itself vouches for, when it gives one: a `206`'s
  /// `Content-Range` total, otherwise `Content-Length`. `nil` when the server sent neither, in
  /// which case the cap is the only size bound.
  static func finalResponseLength(_ response: DownloadTransferResponse) -> Int64? {
    if response.httpStatusCode == 206,
      let total = DownloadFileStore.contentRangeTotal(response.contentRange)
    {
      return total
    }
    return response.contentLength
  }

  private static func fileSize(at url: URL) throws -> Int64? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey])
    guard values.isRegularFile == true else { return nil }
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.int64Value
  }

  private static func baseMIME(_ value: String?) -> String {
    guard let value else { return "" }
    return (value.split(separator: ";").first.map(String.init) ?? value)
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func safeExtension(mimeType: String?, url: URL) -> String {
    let mime = baseMIME(mimeType)
    if mime == "audio/mpeg" || mime == "audio/mp3" || mime == "audio/x-mpeg" { return "mp3" }
    if mime.hasPrefix("audio/") {
      let subtype = String(mime.dropFirst("audio/".count)).replacingOccurrences(of: "x-", with: "")
      if isSafeExtension(subtype) { return subtype }
    }
    let fallback = url.pathExtension.lowercased()
    return isAudioExtension(fallback) ? fallback : "audio"
  }

  private static func isSafeExtension(_ value: String) -> Bool {
    guard value.isEmpty == false, value.count <= 12 else { return false }
    return value.unicodeScalars.allSatisfy {
      CharacterSet.alphanumerics.contains($0)
    }
  }

  private static func isAudioExtension(_ value: String) -> Bool {
    isSafeExtension(value)
      && ["aac", "aiff", "flac", "m4a", "m4b", "mp3", "mp4", "oga", "ogg", "opus", "wav", "webm"]
        .contains(value)
  }
}
