import Foundation
import WatchProtocol

enum WatchFencedStoreError: Error {
  case corrupt
  case foreignAccount
  case versionMismatch
  case io(any Error)
}

/// Persistence for keyed payloads flattened beside version and accountStamp.
/// Payloads must not encode the reserved keys `version` or `accountStamp`.
struct WatchAccountFencedJSONStore<Value: Codable & Sendable>: Sendable {
  enum Location: Sendable {
    /// The adapter owns its dedicated settings key.
    case settings(any WatchSettingsStoring)
    case file(URL)
  }

  private struct Envelope: Codable {
    let version: Int
    let accountStamp: WatchAccountStamp
    let payload: Value

    private enum CodingKeys: String, CodingKey {
      case version, accountStamp
    }

    init(version: Int, accountStamp: WatchAccountStamp, payload: Value) {
      self.version = version
      self.accountStamp = accountStamp
      self.payload = payload
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      version = try container.decode(Int.self, forKey: .version)
      accountStamp = try container.decode(WatchAccountStamp.self, forKey: .accountStamp)
      payload = try Value(from: decoder)
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(version, forKey: .version)
      try container.encode(accountStamp, forKey: .accountStamp)
      try payload.encode(to: encoder)
    }
  }

  let location: Location
  let accountStamp: WatchAccountStamp
  var version = 1

  func load() throws -> Value? {
    let data: Data?
    do {
      switch location {
      case .settings(let store): data = try store.load()
      case .file(let url):
        data = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
      }
    } catch { throw WatchFencedStoreError.io(error) }
    guard let data else { return nil }
    let envelope: Envelope
    do {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .millisecondsSince1970
      envelope = try decoder.decode(Envelope.self, from: data)
    } catch { throw WatchFencedStoreError.corrupt }
    guard envelope.version == version else { throw WatchFencedStoreError.versionMismatch }
    guard envelope.accountStamp == accountStamp else { throw WatchFencedStoreError.foreignAccount }
    return envelope.payload
  }

  func save(_ value: Value) throws {
    let data: Data
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .millisecondsSince1970
      data = try encoder.encode(Envelope(version: version, accountStamp: accountStamp, payload: value))
    } catch { throw WatchFencedStoreError.corrupt }
    do {
      switch location {
      case .settings(let store): try store.save(data)
      case .file(let url):
        // Protection rides on the write: the progress store saves every few seconds while playing.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          var mutableURL = url
          try? mutableURL.setResourceValues(values)
        #endif
      }
    } catch { throw WatchFencedStoreError.io(error) }
  }
}
