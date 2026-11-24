import Foundation
import Testing

@testable import SyncEngine

/// Encryption coverage rule: `schema` is the only plaintext field on every record type.
@Suite struct PodcastCloudRecordLayoutTests {
  private let recordNameKey = try! PodcastCloudRecordNameKey(bytes: Data(repeating: 0x01, count: 32))

  @Test func schemaIsTheOnlyPlaintextFieldOnEveryRecordType() {
    for type in PodcastCloudRecordLayout.allRecordTypes {
      #expect(type.plaintextFieldNames == [PodcastCloudRecordLayout.schemaFieldName], "\(type.name)")
      #expect(
        Set(type.plaintextFieldNames).isSubset(of: PodcastCloudRecordLayout.permittedPlaintextFieldNames))
    }
  }

  @Test func everyPlanRecordTypeIsListedOnceWithAUniqueIdentityKind() throws {
    let names = PodcastCloudRecordLayout.allRecordTypes.map(\.name)
    #expect(
      names == [
        "PodcastSubscription", "PodcastFeedSettings", "PodcastEpisodeState", "PodcastEpisodeIdentity",
        "PodcastSavedEpisode", "PodcastGlobalSettings", "PodcastLastPlayed", "PodcastKeyring",
      ])
    let kinds = PodcastCloudRecordLayout.allRecordTypes.map(\.identityKind)
    #expect(Set(kinds).count == kinds.count)
    for type in PodcastCloudRecordLayout.allRecordTypes {
      let components: [String]
      switch type.identityKind {
      case "globals", "bookmark", "keyring": components = []
      case "sub": components = [UUID().uuidString.lowercased()]
      case "settings": components = [UUID().uuidString.lowercased(), UUID().uuidString.lowercased()]
      default:
        components = [
          UUID().uuidString.lowercased(), UUID().uuidString.lowercased(),
          PodcastCloudIdentity.episodeDigest(identityKey: "x"),
        ]
      }
      _ = try PodcastCloudIdentity.recordName(kind: type.identityKind, components: components, key: recordNameKey)
    }
  }

  @Test func fieldNamesAreUniquePerRecordAndCarryNoValues() {
    for type in PodcastCloudRecordLayout.allRecordTypes {
      let names = type.fields.map(\.name)
      #expect(Set(names).count == names.count, "\(type.name)")
      for name in names {
        #expect(name.allSatisfy { $0.isLetter || $0.isNumber }, "\(type.name).\(name)")
        #expect(name.contains("http") == false)
      }
    }
  }

  @Test func everyStampComponentIsEncrypted() {
    for type in PodcastCloudRecordLayout.allRecordTypes {
      if type.identityKind == "keyring" { continue }
      let stampFields = type.fields.filter {
        $0.name.hasSuffix("PhysicalMilliseconds") || $0.name.hasSuffix("LogicalCounter")
          || $0.name.hasSuffix("InstallationUUID") || $0.name.hasSuffix("MutationUUID")
      }
      #expect(stampFields.isEmpty == false, "\(type.name)")
      #expect(stampFields.allSatisfy { $0.isEncrypted }, "\(type.name)")
    }
    #expect(
      PodcastCloudRecordLayout.keyring.fields == [
        PodcastCloudRecordLayout.Field(
          name: PodcastCloudRecordLayout.schemaFieldName, kind: .integer, isEncrypted: false),
        PodcastCloudRecordLayout.Field(
          name: PodcastCloudRecordLayout.recordNameKeyFieldName, kind: .data, isEncrypted: true),
      ])
  }

  private struct ProductionSchemaManifest: Decodable {
    let recordTypes: [String: [String: String]]
  }

  /// Production does not create a record type or a field on demand, so a save carrying one it has
  /// not been given is rejected and held. The manifest is the list that was deployed; a layout
  /// change fails here until the schema is deployed again and the manifest says so.
  @Test func theLayoutMatchesTheSchemaDeployedToProduction() throws {
    let manifestURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("docs/cloudkit-production-schema.json")
    let manifest = try JSONDecoder().decode(
      ProductionSchemaManifest.self, from: try Data(contentsOf: manifestURL))

    var layout: [String: [String: String]] = [:]
    for type in PodcastCloudRecordLayout.allRecordTypes {
      layout[type.name] = Dictionary(
        uniqueKeysWithValues: type.fields.map {
          ($0.name, ($0.isEncrypted ? "encrypted " : "") + $0.kind.rawValue)
        })
    }

    #expect(
      layout == manifest.recordTypes,
      """
      PodcastCloudRecordLayout no longer matches docs/cloudkit-production-schema.json. Deploy the \
      Development schema to Production in CloudKit Console, then update the manifest to match.
      """)
  }
}
