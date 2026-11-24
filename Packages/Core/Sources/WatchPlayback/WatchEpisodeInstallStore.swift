import Foundation
import WatchProtocol

/// The Watch app's install identity and the two monotonic inventory/progress sequences. The file is
/// device-owned and backup-excluded, so a restored or replacement Watch gets a new identity and the
/// phone replaces the previous Watch's desired set rather than inheriting it.
///
/// A corrupt file yields a new identity with sequences starting at 1. That is safe because the phone
/// keys the desired set by install ID: it sees a new Watch and offers the whole set again, which is
/// the same recovery a wiped Watch uses. An unreadable file (before first unlock) is not treated as
/// corrupt; it throws so the App can retry with the same identity.
public actor WatchEpisodeInstallStore {
  public struct Payload: Codable, Sendable, Equatable {
    public var installID: String
    public var inventorySequence: UInt64
    public var progressSequence: UInt64

    public init(installID: String, inventorySequence: UInt64, progressSequence: UInt64) {
      self.installID = installID
      self.inventorySequence = inventorySequence
      self.progressSequence = progressSequence
    }
  }

  private let fileURL: URL
  private var payload: Payload

  public init(fileURL: URL) throws {
    self.fileURL = fileURL

    var existing: Payload?
    if FileManager.default.fileExists(atPath: fileURL.path) {
      let data: Data
      do {
        data = try Data(contentsOf: fileURL)
      } catch {
        throw WatchEpisodeInstallStoreError.storageFailure
      }
      if let decoded = try? JSONDecoder().decode(Payload.self, from: data),
        (try? WatchInstallIdentity.validate(decoded.installID)) != nil
      {
        existing = decoded
      }
    }

    let resolved =
      existing
      ?? Payload(
        installID: UUID().uuidString.lowercased(), inventorySequence: 0, progressSequence: 0)
    self.payload = resolved
    // Only a new identity is written here; an existing file already holds this payload, and
    // rewriting it on every open would needlessly require the directory to be writable.
    if existing == nil {
      do {
        try Self.save(resolved, to: fileURL)
      } catch {
        throw WatchEpisodeInstallStoreError.storageFailure
      }
    }
  }

  public func installID() throws -> String {
    payload.installID
  }

  /// Strictly increasing across relaunches and across sign-out/sign-in: the phone ignores a
  /// sequence at or below the last it stored for this install.
  public func nextInventorySequence() throws -> UInt64 {
    let previous = payload
    let next = previous.inventorySequence &+ 1
    guard next > previous.inventorySequence else {
      throw WatchEpisodeInstallStoreError.storageFailure
    }
    payload.inventorySequence = next
    do {
      try Self.save(payload, to: fileURL)
    } catch {
      payload = previous
      throw WatchEpisodeInstallStoreError.storageFailure
    }
    return next
  }

  public func nextProgressSequence() throws -> UInt64 {
    let previous = payload
    let next = previous.progressSequence &+ 1
    guard next > previous.progressSequence else {
      throw WatchEpisodeInstallStoreError.storageFailure
    }
    payload.progressSequence = next
    do {
      try Self.save(payload, to: fileURL)
    } catch {
      payload = previous
      throw WatchEpisodeInstallStoreError.storageFailure
    }
    return next
  }

  private static func save(_ payload: Payload, to fileURL: URL) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(payload)
    try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var mutableURL = fileURL
      try? mutableURL.setResourceValues(values)
    #endif
  }
}

public enum WatchEpisodeInstallStoreError: Error, Sendable, Equatable {
  case storageFailure
}
