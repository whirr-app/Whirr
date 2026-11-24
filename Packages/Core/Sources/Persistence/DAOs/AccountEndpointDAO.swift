import Foundation
import GRDB

public enum AccountEndpointDAOError: Error, Equatable, Sendable {
  case accountNotFound
  case endpointNotFound
  case duplicateURL
  case cannotRemoveLastEndpoint
  case cannotRemoveActiveEndpoint
  case reorderMismatch
}

/// Persistence operations for an account's ordered set of server addresses.
public struct AccountEndpointDAO: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func fetchAll(accountId: Int64) throws -> [AccountEndpointRecord] {
    try database.read { db in
      try AccountEndpointRecord
        .filter(Column("accountId") == accountId)
        .order(Column("sortOrder"), Column("id"))
        .fetchAll(db)
    }
  }

  public func insert(
    accountId: Int64, normalizedURL: String, preferred: Bool
  ) throws -> AccountEndpointRecord {
    try database.write { db in
      guard try AccountRecord.fetchOne(db, key: accountId) != nil else {
        throw AccountEndpointDAOError.accountNotFound
      }
      guard
        try AccountEndpointRecord
          .filter(Column("accountId") == accountId)
          .filter(Column("normalizedURL") == normalizedURL)
          .fetchOne(db) == nil
      else {
        throw AccountEndpointDAOError.duplicateURL
      }

      let endpoints = try endpoints(accountId: accountId, in: db)
      if preferred || endpoints.isEmpty {
        try clearPreferred(accountId: accountId, in: db)
      }
      var endpoint = AccountEndpointRecord(
        accountId: accountId,
        normalizedURL: normalizedURL,
        isPreferred: preferred || endpoints.isEmpty,
        sortOrder: endpoints.count,
        addedAt: Date())
      try endpoint.insert(db)
      return endpoint
    }
  }

  public func remove(id: Int64) throws {
    try database.write { db in
      guard let endpoint = try AccountEndpointRecord.fetchOne(db, key: id) else {
        throw AccountEndpointDAOError.endpointNotFound
      }
      let currentEndpoints = try endpoints(accountId: endpoint.accountId, in: db)
      guard currentEndpoints.count > 1 else {
        throw AccountEndpointDAOError.cannotRemoveLastEndpoint
      }
      guard let account = try AccountRecord.fetchOne(db, key: endpoint.accountId) else {
        throw AccountEndpointDAOError.accountNotFound
      }
      guard endpoint.normalizedURL != account.serverBaseURL else {
        throw AccountEndpointDAOError.cannotRemoveActiveEndpoint
      }

      try endpoint.delete(db)
      let remaining = try endpoints(accountId: endpoint.accountId, in: db)
      try renumber(remaining, in: db)
      if endpoint.isPreferred {
        try clearPreferred(accountId: endpoint.accountId, in: db)
        if let replacement = remaining.first {
          try db.execute(
            sql: "UPDATE accountEndpoint SET isPreferred = 1 WHERE id = ?",
            arguments: [replacement.id])
        }
      }
    }
  }

  public func reorder(accountId: Int64, ids: [Int64]) throws {
    try database.write { db in
      let endpoints = try endpoints(accountId: accountId, in: db)
      guard Set(ids).count == ids.count,
        Set(ids) == Set(endpoints.compactMap(\.id))
      else {
        throw AccountEndpointDAOError.reorderMismatch
      }
      for (sortOrder, id) in ids.enumerated() {
        try db.execute(
          sql: "UPDATE accountEndpoint SET sortOrder = ? WHERE id = ?",
          arguments: [sortOrder, id])
      }
    }
  }

  public func setPreferred(id: Int64) throws {
    try database.write { db in
      guard let endpoint = try AccountEndpointRecord.fetchOne(db, key: id) else {
        throw AccountEndpointDAOError.endpointNotFound
      }
      try clearPreferred(accountId: endpoint.accountId, in: db)
      try db.execute(
        sql: "UPDATE accountEndpoint SET isPreferred = 1 WHERE id = ?", arguments: [id])
    }
  }

  public func setActive(accountId: Int64, normalizedURL: String) throws {
    try database.write { db in
      guard
        try AccountEndpointRecord
          .filter(Column("accountId") == accountId)
          .filter(Column("normalizedURL") == normalizedURL)
          .fetchOne(db) != nil
      else {
        throw AccountEndpointDAOError.endpointNotFound
      }
      try db.execute(
        sql: "UPDATE account SET serverBaseURL = ? WHERE id = ?",
        arguments: [normalizedURL, accountId])
    }
  }

  public func markReached(id: Int64, at date: Date) throws {
    try updateTimestamp(id: id, column: "lastReachedAt", date: date)
  }

  public func markFailed(id: Int64, at date: Date) throws {
    try updateTimestamp(id: id, column: "lastFailedAt", date: date)
  }

  private func updateTimestamp(id: Int64, column: String, date: Date) throws {
    try database.write { db in
      guard try AccountEndpointRecord.fetchOne(db, key: id) != nil else {
        throw AccountEndpointDAOError.endpointNotFound
      }
      try db.execute(
        sql: "UPDATE accountEndpoint SET \(column) = ? WHERE id = ?", arguments: [date, id])
    }
  }

  private func endpoints(accountId: Int64, in db: Database) throws -> [AccountEndpointRecord] {
    try AccountEndpointRecord
      .filter(Column("accountId") == accountId)
      .order(Column("sortOrder"), Column("id"))
      .fetchAll(db)
  }

  private func clearPreferred(accountId: Int64, in db: Database) throws {
    try db.execute(
      sql: "UPDATE accountEndpoint SET isPreferred = 0 WHERE accountId = ?",
      arguments: [accountId])
  }

  private func renumber(_ endpoints: [AccountEndpointRecord], in db: Database) throws {
    for (sortOrder, endpoint) in endpoints.enumerated() {
      try db.execute(
        sql: "UPDATE accountEndpoint SET sortOrder = ? WHERE id = ?",
        arguments: [sortOrder, endpoint.id])
    }
  }
}
