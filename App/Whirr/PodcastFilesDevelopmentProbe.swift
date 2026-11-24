#if DEBUG
  import Foundation

  /// Manual IC0 probe for a picker-selected folder; never composed into the shipping app.
  @MainActor
  final class PodcastFilesDevelopmentProbe {
    enum Failure: Error, Equatable {
      case scopeDenied, tooLarge, alreadyExists, missingOrUnexpectedPayload, coordinationFailed
    }

    struct Receipt {
      let bookmark: Data
      let bookmarkWasStale: Bool
    }

    private let identifier: UUID
    private let startAccess: (URL) -> Bool
    private let stopAccess: (URL) -> Void
    private let maximumBytes = 65_536

    /// Persist the UUID with the bookmark to verify the same synthetic file after relaunch.
    init(
      identifier: UUID,
      startAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
      stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
      self.identifier = identifier
      self.startAccess = startAccess
      self.stopAccess = stopAccess
    }

    private func file(in folder: URL) -> URL {
      folder.appendingPathComponent("whirr-files-probe-\(identifier.uuidString.lowercased()).bin")
    }

    func create(in selectedFolder: URL, payload: Data) throws -> Receipt {
      try bounded(payload)
      return try scoped(selectedFolder) {
        let bookmark = try makeBookmark(selectedFolder)
        try write(payload, at: file(in: selectedFolder), expectedPrevious: nil)
        return Receipt(bookmark: bookmark, bookmarkWasStale: false)
      }
    }

    func verify(bookmark: Data, expected: Data) throws -> Receipt {
      try bounded(expected)
      return try resolved(bookmark) { folder, receipt in
        guard try read(file(in: folder)) == expected else { throw Failure.missingOrUnexpectedPayload }
        return receipt
      }
    }

    /// Replaces only the UUID-owned probe whose previous bytes match the caller's receipt.
    func replace(bookmark: Data, expectedPrevious: Data, payload: Data) throws -> Receipt {
      try bounded(expectedPrevious)
      try bounded(payload)
      return try resolved(bookmark) { folder, receipt in
        try write(payload, at: file(in: folder), expectedPrevious: expectedPrevious)
        return receipt
      }
    }

    private func bounded(_ data: Data) throws {
      guard data.count <= maximumBytes else { throw Failure.tooLarge }
    }

    private func scoped<T>(_ folder: URL, body: () throws -> T) throws -> T {
      guard startAccess(folder) else { throw Failure.scopeDenied }
      defer { stopAccess(folder) }
      return try body()
    }

    private func makeBookmark(_ folder: URL) throws -> Data {
      try folder.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func resolved<T>(_ bookmark: Data, body: (URL, Receipt) throws -> T) throws -> T {
      var stale = false
      let folder = try URL(
        resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil,
        bookmarkDataIsStale: &stale)
      return try scoped(folder) {
        let current = stale ? try makeBookmark(folder) : bookmark
        return try body(folder, Receipt(bookmark: current, bookmarkWasStale: stale))
      }
    }

    private func read(_ url: URL) throws -> Data {
      var coordinationError: NSError?
      var result: Result<Data, Error>?
      NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
        result = Result {
          let size = try coordinatedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
          guard let size, size <= maximumBytes else { throw Failure.tooLarge }
          let data = try Data(contentsOf: coordinatedURL)
          try bounded(data)
          return data
        }
      }
      if coordinationError != nil { throw Failure.coordinationFailed }
      guard let result else { throw Failure.coordinationFailed }
      return try result.get()
    }

    private func write(_ payload: Data, at url: URL, expectedPrevious: Data?) throws {
      var coordinationError: NSError?
      var result: Result<Void, Error>?
      NSFileCoordinator().coordinate(
        writingItemAt: url, options: expectedPrevious == nil ? [] : .forReplacing,
        error: &coordinationError
      ) { coordinatedURL in
        result = Result {
          if let expectedPrevious {
            let size = try coordinatedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size == expectedPrevious.count,
              try Data(contentsOf: coordinatedURL) == expectedPrevious
            else { throw Failure.missingOrUnexpectedPayload }
          } else {
            guard !FileManager.default.fileExists(atPath: coordinatedURL.path) else { throw Failure.alreadyExists }
          }
          try payload.write(to: coordinatedURL, options: .atomic)
        }
      }
      if coordinationError != nil { throw Failure.coordinationFailed }
      guard let result else { throw Failure.coordinationFailed }
      try result.get()
      guard try read(url) == payload else { throw Failure.missingOrUnexpectedPayload }
    }
  }
#endif
