import Foundation
import Observation
import Persistence
import SyncEngine

/// The AppModel boundary for the account's ordered server addresses. The service is actor-backed in
/// production; every operation is async here so test fakes and the production actor share one seam.
public protocol ServerAddressManaging: Sendable {
  func endpoints() async throws -> [AccountEndpointRecord]
  func add(url: URL, customHeaders: [String: String]) async throws -> AccountEndpointRecord
  func add(
    url: URL, customHeaders: [String: String], credentials: AccountEndpointService.EndpointProofCredentials
  ) async throws -> AccountEndpointRecord
  func remove(id: Int64) async throws
  func reorder(ids: [Int64]) async throws
  func setPreferred(id: Int64) async throws
}

/// Declared here rather than in the App so the conformance lives in the module that owns the
/// protocol; a retroactive conformance across two imported modules is not guaranteed to behave.
extension AccountEndpointService: ServerAddressManaging {}

@MainActor
@Observable
public final class ServerAddressesModel {
  public enum Reachability: Sendable, Equatable {
    case reached
    case failed
    case unknown
  }

  public struct Row: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let displayAddress: String
    public let isActive: Bool
    public let isPreferred: Bool
    public let reachability: Reachability

    public init(
      id: Int64, displayAddress: String, isActive: Bool, isPreferred: Bool,
      reachability: Reachability
    ) {
      self.id = id
      self.displayAddress = displayAddress
      self.isActive = isActive
      self.isPreferred = isPreferred
      self.reachability = reachability
    }

    /// Mirrors the setup form's scheme glyphs so the two screens read the same way.
    public var securitySymbol: String {
      displayAddress.lowercased().hasPrefix("https://") ? "lock.fill" : "network"
    }
  }

  public enum Phase: Sendable, Equatable {
    case idle
    case loading
    case failed(String)
  }

  public enum AddState: Sendable, Equatable {
    case idle
    case probing
    case needsCredentials
    case failed(String)
    case added
  }

  public private(set) var rows: [Row] = []
  public private(set) var phase: Phase = .idle
  public private(set) var addState: AddState = .idle

  private let service: any ServerAddressManaging
  private let activeURL: () -> String?

  public init(service: any ServerAddressManaging, activeURL: @escaping () -> String?) {
    self.service = service
    self.activeURL = activeURL
  }

  public func load() async {
    phase = .loading
    do {
      rows = try await mappedRows(from: service.endpoints())
      phase = .idle
    } catch {
      guard Task.isCancelled == false else { return }
      phase = .failed(message(for: error))
    }
  }

  public func add(address: String, headers: [String: String]) async {
    await add(address: address, headers: headers, credentials: nil)
  }

  public func add(address: String, headers: [String: String], username: String, password: String) async {
    await add(
      address: address, headers: headers,
      credentials: .password(username: username, password: password))
  }

  public func add(address: String, headers: [String: String], apiToken: String) async {
    await add(address: address, headers: headers, credentials: .apiToken(apiToken))
  }

  public func remove(id: Int64) async {
    do {
      try await service.remove(id: id)
      rows.removeAll { $0.id == id }
      phase = .idle
    } catch {
      phase = .failed(message(for: error))
    }
  }

  public func move(from source: IndexSet, to destination: Int) async {
    var reordered = rows
    reordered.move(fromOffsets: source, toOffset: destination)
    do {
      try await service.reorder(ids: reordered.map(\.id))
      rows = reordered
      phase = .idle
    } catch {
      phase = .failed(message(for: error))
    }
  }

  public func setPreferred(id: Int64) async {
    do {
      try await service.setPreferred(id: id)
      rows = rows.map { row in
        Row(
          id: row.id, displayAddress: row.displayAddress, isActive: row.isActive,
          isPreferred: row.id == id, reachability: row.reachability)
      }
      phase = .idle
    } catch {
      phase = .failed(message(for: error))
    }
  }

  public func dismissFailure() {
    if case .failed = phase { phase = .idle }
  }

  /// The add sheet starts clean each time it is presented; a previous attempt's outcome must not
  /// leak into the next one.
  public func resetAddState() {
    addState = .idle
  }

  private func add(
    address: String, headers: [String: String],
    credentials: AccountEndpointService.EndpointProofCredentials?
  ) async {
    addState = .probing
    do {
      let url = try makeURL(from: address)
      let record: AccountEndpointRecord
      if let credentials {
        record = try await service.add(url: url, customHeaders: headers, credentials: credentials)
      } else {
        record = try await service.add(url: url, customHeaders: headers)
      }
      guard record.id != nil, let row = map(record: record, active: activeURL()) else {
        throw AccountEndpointError.localPersistenceFailed
      }
      rows.append(row)
      addState = .added
    } catch let error as AccountEndpointError {
      addState = error == .credentialsRequired ? .needsCredentials : .failed(ServerAddressesCopy.message(for: error))
    } catch let error as AccountLifecycleError {
      addState = .failed(ServerAddressesCopy.message(for: error))
    } catch {
      addState = .failed(ServerAddressesCopy.generic)
    }
  }

  private func mappedRows(from records: [AccountEndpointRecord]) -> [Row] {
    let active = activeURL()
    return records.compactMap { record in map(record: record, active: active) }
  }

  private func map(record: AccountEndpointRecord, active: String?) -> Row? {
    guard let id = record.id else { return nil }
    return Row(
      id: id,
      displayAddress: Self.displayAddress(for: record.normalizedURL),
      isActive: record.normalizedURL == active,
      isPreferred: record.isPreferred,
      reachability: Self.reachability(reached: record.lastReachedAt, failed: record.lastFailedAt))
  }

  private func message(for error: Error) -> String {
    if let error = error as? AccountEndpointError { return ServerAddressesCopy.message(for: error) }
    if let error = error as? AccountLifecycleError { return ServerAddressesCopy.message(for: error) }
    return ServerAddressesCopy.generic
  }

  private func makeURL(from address: String) throws -> URL {
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let url = URL(string: candidate), url.host != nil else {
      throw AccountLifecycleError.malformedURL
    }
    return url
  }

  private static func displayAddress(for normalizedURL: String) -> String {
    guard let components = URLComponents(string: normalizedURL), let scheme = components.scheme,
      let host = components.host
    else { return normalizedURL }
    let hostDisplay = host.contains(":") ? "[\(host)]" : host
    let port = components.port.map { ":\($0)" } ?? ""
    let path = components.path == "/" ? "" : components.path
    return "\(scheme)://\(hostDisplay)\(port)\(path)"
  }

  private static func reachability(reached: Date?, failed: Date?) -> Reachability {
    switch (reached, failed) {
    case (nil, nil): .unknown
    case (.some, nil): .reached
    case (nil, .some): .failed
    case (.some(let reached), .some(let failed)): reached >= failed ? .reached : .failed
    }
  }
}

extension Array {
  fileprivate mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
    let moving = offsets.map { self[$0] }
    for index in offsets.sorted(by: >) { remove(at: index) }
    let adjustedDestination = destination - offsets.filter { $0 < destination }.count
    insert(contentsOf: moving, at: Swift.min(adjustedDestination, count))
  }
}
