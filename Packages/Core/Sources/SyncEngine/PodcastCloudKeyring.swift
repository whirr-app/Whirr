import CryptoKit
import Foundation

public enum PodcastCloudKeyringError: Error, Sendable, Equatable {
  case invalidKeyLength
  case corruptKeyring
}

public struct PodcastCloudRecordNameKey: Sendable, Equatable {
  private static let byteCount = 32

  public let bytes: Data

  public init(bytes: Data) throws {
    guard bytes.count == Self.byteCount else { throw PodcastCloudKeyringError.invalidKeyLength }
    self.bytes = bytes
  }

  public static func mint() -> Self {
    var generator = SystemRandomNumberGenerator()
    var bytes = Data(capacity: byteCount)
    for _ in 0..<byteCount {
      bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
    }
    return try! Self(bytes: bytes)
  }
}

extension PodcastCloudRecordNameKey: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "PodcastCloudRecordNameKey(32 bytes)" }
  public var debugDescription: String { description }
}

/// What the store found at `v1.keyring`.
public enum PodcastCloudKeyringFetch: Sendable, Equatable {
  case absent
  case present(recordNameKey: Data)
}

/// Outcome of saving a freshly minted keyring with no change tag (`.ifServerRecordUnchanged`).
public enum PodcastCloudKeyringSave: Sendable, Equatable {
  case saved
  case serverRecordChanged(recordNameKey: Data)
}

public protocol PodcastCloudKeyringStore: Sendable {
  func fetchKeyring() async throws -> PodcastCloudKeyringFetch
  func saveNewKeyring(_ key: PodcastCloudRecordNameKey) async throws -> PodcastCloudKeyringSave
}

public struct PodcastCloudKeyringBootstrap: Sendable {
  private let mint: @Sendable () -> PodcastCloudRecordNameKey

  public init(mint: @escaping @Sendable () -> PodcastCloudRecordNameKey = PodcastCloudRecordNameKey.mint) {
    self.mint = mint
  }

  public func resolveKey(using store: some PodcastCloudKeyringStore) async throws -> PodcastCloudRecordNameKey {
    switch try await store.fetchKeyring() {
    case .absent:
      let minted = mint()
      switch try await store.saveNewKeyring(minted) {
      case .saved:
        return minted
      case .serverRecordChanged(let recordNameKey):
        return try validatedKey(recordNameKey)
      }
    case .present(let recordNameKey):
      return try validatedKey(recordNameKey)
    }
  }

  private func validatedKey(_ bytes: Data) throws -> PodcastCloudRecordNameKey {
    do {
      return try PodcastCloudRecordNameKey(bytes: bytes)
    } catch PodcastCloudKeyringError.invalidKeyLength {
      throw PodcastCloudKeyringError.corruptKeyring
    }
  }
}

/// The resolved key cached beside engine state, fenced by the zone it came from.
public struct PodcastCloudKeyringCache: Sendable, Equatable {
  public let key: PodcastCloudRecordNameKey
  public let fence: PodcastCloudAccountFence

  public init(key: PodcastCloudRecordNameKey, fence: PodcastCloudAccountFence) {
    self.key = key
    self.fence = fence
  }

  public func key(for current: PodcastCloudAccountFence) -> PodcastCloudRecordNameKey? {
    fence == current ? key : nil
  }
}
