import Foundation
import GRDB

/// The durable removal journal. Not account-owned: `accountRowId` is a plain copy of the account
/// row's id, not a foreign key (`createAccountRemovalJournal` uses `t.column`, not `t.belongsTo`),
/// so the row survives the account row's deletion mid-removal, even across a crash and relaunch.
///
/// Written first in a confirmed removal, before any destructive side effect
/// (`AccountRemovalCoordinator`), and cleared only once both the schema-driven and file-system
/// sweeps pass. While it exists it gates login/setup. Carries the credential namespace, every
/// endpoint URL whose token/header items must be cleared, and `downloadsRootRelativePath`, none
/// of which a schema-driven sweep can reconstruct once the account row is gone.
public struct AccountRemovalJournalRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  private enum CodingKeys: String, CodingKey {
    case id
    case serverBaseURL
    case serverUserId
    case credentialNamespace
    case endpointURLs
    case accountRowId
    case downloadsRootRelativePath
    case createdAt
  }

  public static let databaseTableName = "accountRemovalJournal"

  public var id: Int64?
  public var serverBaseURL: String
  public var serverUserId: String
  public var credentialNamespace: String?
  public var endpointURLs: [String]
  public var accountRowId: Int64
  public var downloadsRootRelativePath: String
  public var createdAt: Date

  public init(
    id: Int64? = nil,
    serverBaseURL: String,
    serverUserId: String,
    credentialNamespace: String? = nil,
    endpointURLs: [String] = [],
    accountRowId: Int64,
    downloadsRootRelativePath: String,
    createdAt: Date
  ) {
    self.id = id
    self.serverBaseURL = serverBaseURL
    self.serverUserId = serverUserId
    self.credentialNamespace = credentialNamespace
    self.endpointURLs = endpointURLs
    self.accountRowId = accountRowId
    self.downloadsRootRelativePath = downloadsRootRelativePath
    self.createdAt = createdAt
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(Int64.self, forKey: .id)
    serverBaseURL = try container.decode(String.self, forKey: .serverBaseURL)
    serverUserId = try container.decode(String.self, forKey: .serverUserId)
    credentialNamespace = try container.decodeIfPresent(String.self, forKey: .credentialNamespace)
    endpointURLs = try container.decodeIfPresent([String].self, forKey: .endpointURLs) ?? []
    accountRowId = try container.decode(Int64.self, forKey: .accountRowId)
    downloadsRootRelativePath = try container.decode(String.self, forKey: .downloadsRootRelativePath)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
  }
}
