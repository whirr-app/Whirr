import Foundation

public enum CustomHeaderStoreError: Error, Sendable, Equatable {
  case invalidServer
  case malformedStoredHeaders
}

/// Server-scoped persistence for proxy credentials. Keyed by URL rather than `TokenAccount`
/// because setup needs these fields before a server user id exists (SECURITY.md).
public protocol CustomHeaderStoring: Sendable {
  func save(_ headers: CustomHeaders, for serverURL: URL) throws
  func load(for serverURL: URL) throws -> CustomHeaders?
  func clear(for serverURL: URL) throws
}

public final class InMemoryCustomHeaderStore: CustomHeaderStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String: CustomHeaders] = [:]

  public init() {}

  public func save(_ headers: CustomHeaders, for serverURL: URL) throws {
    let identity = try normalizedIdentity(for: serverURL)
    lock.lock()
    values[identity] = headers
    lock.unlock()
  }

  public func load(for serverURL: URL) throws -> CustomHeaders? {
    let identity = try normalizedIdentity(for: serverURL)
    lock.lock()
    let value = values[identity]
    lock.unlock()
    return value
  }

  public func clear(for serverURL: URL) throws {
    let identity = try normalizedIdentity(for: serverURL)
    lock.lock()
    values.removeValue(forKey: identity)
    lock.unlock()
  }

  private func normalizedIdentity(for serverURL: URL) throws -> String {
    do {
      return try TokenAccount.normalizedServerIdentity(from: serverURL)
    } catch {
      throw CustomHeaderStoreError.invalidServer
    }
  }
}

#if canImport(Security)
  import Security

  public final class KeychainCustomHeaderStore: CustomHeaderStoring, @unchecked Sendable {
    private let serviceNamespace: String
    private let client: SecItemClient
    private let lock = NSLock()

    public init(
      serviceNamespace: String = "com.remoteconcern.whirr.headers",
      client: SecItemClient = SecuritySecItemClient()
    ) throws {
      guard serviceNamespace.isEmpty == false else {
        throw CustomHeaderStoreError.invalidServer
      }
      self.serviceNamespace = serviceNamespace
      self.client = client
    }

    public func save(_ headers: CustomHeaders, for serverURL: URL) throws {
      let query = try makeQuery(for: serverURL)
      let attributes = try makeAttributes(headers, account: query.account)

      lock.lock()
      defer { lock.unlock() }
      do {
        try client.update(attributes, for: query)
      } catch KeychainStoreError.itemNotFound {
        do {
          try client.add(attributes, for: query)
        } catch KeychainStoreError.itemAlreadyExists {
          try client.update(attributes, for: query)
        }
      }
    }

    public func load(for serverURL: URL) throws -> CustomHeaders? {
      lock.lock()
      defer { lock.unlock() }
      let query = try makeQuery(for: serverURL)
      guard let data = try client.copyData(for: query) else { return nil }
      guard let headers = try? JSONDecoder().decode(CustomHeaders.self, from: data) else {
        throw KeychainStoreError.malformedData
      }
      return headers
    }

    public func clear(for serverURL: URL) throws {
      lock.lock()
      defer { lock.unlock() }
      try client.delete(for: makeQuery(for: serverURL))
    }

    private func makeQuery(for serverURL: URL) throws -> KeychainItemQuery {
      let account: String
      do {
        account = try TokenAccount.normalizedServerIdentity(from: serverURL)
      } catch {
        throw CustomHeaderStoreError.invalidServer
      }
      return KeychainItemQuery(service: serviceNamespace, account: account)
    }

    private func makeAttributes(_ headers: CustomHeaders, account: String) throws -> KeychainItemAttributes {
      guard let data = try? JSONEncoder().encode(headers) else {
        throw CustomHeaderStoreError.malformedStoredHeaders
      }
      return KeychainItemAttributes(
        service: serviceNamespace,
        account: account,
        data: data
      )
    }
  }
#endif
