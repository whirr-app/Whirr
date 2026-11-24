import Foundation
import Persistence
import Testing

@testable import SyncEngine

@Suite struct PodcastCloudValuesTests {
  private let a = UUID(uuidString: "11111111-1111-8111-8111-111111111111")!
  private let b = UUID(uuidString: "22222222-2222-8222-8222-222222222222")!
  private let recordNameKey = try! PodcastCloudRecordNameKey(bytes: Data(repeating: 0x01, count: 32))
  private func stamp(_ time: Int64, counter: Int64 = 0) throws -> PodcastCloudMutationStamp {
    try PodcastCloudMutationStamp(
      physicalMilliseconds: time, logicalCounter: counter, installationUUID: a, mutationUUID: b)
  }

  @Test func totalOrderUsesEveryStampComponent() throws {
    let first = try stamp(10)
    #expect(try first < stamp(11))
    #expect(try first < stamp(10, counter: 1))
    let otherAuthor = try PodcastCloudMutationStamp(
      physicalMilliseconds: 10, logicalCounter: 0, installationUUID: b, mutationUUID: a)
    #expect(first < otherAuthor)
    let earlierMutation = try PodcastCloudMutationStamp(
      physicalMilliseconds: 10, logicalCounter: 0, installationUUID: a, mutationUUID: a)
    #expect(earlierMutation < first)
    #expect(try JSONDecoder().decode(PodcastCloudMutationStamp.self, from: JSONEncoder().encode(first)) == first)
  }

  @Test func explicitResetBeatsStaleTickAndDeliberateResumeCanAdvance() throws {
    let tick = try PodcastCloudEpisodeState(
      position: 120, isFinished: false, isDismissed: false, writeStamp: stamp(1_000))
    let reset = try PodcastCloudEpisodeState(
      position: 0, isFinished: false, isDismissed: true, explicitEpoch: stamp(10), writeStamp: stamp(10))
    let resumed = try PodcastCloudEpisodeState(
      position: 4, isFinished: false, isDismissed: false, explicitEpoch: stamp(20), writeStamp: stamp(21))
    #expect(try PodcastCloudEpisodeState.merge(tick, reset) == reset)
    #expect(try PodcastCloudEpisodeState.merge(reset, resumed) == resumed)
    let values = [tick, reset, resumed]
    for x in values {
      #expect(try PodcastCloudEpisodeState.merge(x, x) == x)
      for y in values {
        #expect(try PodcastCloudEpisodeState.merge(x, y) == PodcastCloudEpisodeState.merge(y, x))
        for z in values {
          #expect(
            try PodcastCloudEpisodeState.merge(PodcastCloudEpisodeState.merge(x, y), z)
              == PodcastCloudEpisodeState.merge(x, PodcastCloudEpisodeState.merge(y, z)))
        }
      }
    }
  }

  @Test func reusedStampWithDifferentPayloadIsRejected() throws {
    let x = try PodcastCloudEpisodeState(position: 1, isFinished: false, isDismissed: false, writeStamp: stamp(5))
    let y = try PodcastCloudEpisodeState(position: 2, isFinished: false, isDismissed: false, writeStamp: stamp(5))
    #expect(throws: PodcastCloudEpisodeState.ValidationError.stampCollision) {
      try PodcastCloudEpisodeState.merge(x, y)
    }
    let differentEpoch = try PodcastCloudEpisodeState(
      position: 1, isFinished: false, isDismissed: false,
      explicitEpoch: stamp(5), writeStamp: stamp(5))
    #expect(throws: PodcastCloudEpisodeState.ValidationError.stampCollision) {
      try PodcastCloudEpisodeState.merge(x, differentEpoch)
    }
  }

  @Test func hostileDecodedStateCannotBypassValidation() throws {
    let value = try PodcastCloudEpisodeState(position: 1, isFinished: false, isDismissed: false, writeStamp: stamp(2))
    let encoded = try JSONEncoder().encode(value)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["position"] = -1
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(PodcastCloudEpisodeState.self, from: JSONSerialization.data(withJSONObject: object))
    }
    object["position"] = 1
    object["explicitEpoch"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stamp(3)))
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(PodcastCloudEpisodeState.self, from: JSONSerialization.data(withJSONObject: object))
    }
    var clock = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(stamp(2))) as? [String: Any])
    for field in ["physicalMilliseconds", "logicalCounter"] {
      var invalid = clock
      invalid[field] = -1
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(PodcastCloudMutationStamp.self, from: JSONSerialization.data(withJSONObject: invalid))
      }
    }
    clock["logicalCounter"] = 0
    #expect(throws: (any Error).self) {
      try PodcastCloudEpisodeState(position: .infinity, isFinished: false, isDismissed: false, writeStamp: stamp(2))
    }
  }

  @Test func refollowAndDifferentParentFenceChildren() throws {
    let old = PodcastCloudFollowRegister(subscriptionUUID: a, generationUUID: a, isFollowed: true, stamp: try stamp(1))
    let removed = PodcastCloudFollowRegister(
      subscriptionUUID: a, generationUUID: a, isFollowed: false, stamp: try stamp(2))
    let refollow = PodcastCloudFollowRegister(
      subscriptionUUID: a, generationUUID: b, isFollowed: true, stamp: try stamp(3))
    let child = PodcastCloudChildReference(subscriptionUUID: a, generationUUID: a)
    #expect(child.isAdmitted(by: old))
    #expect(!child.isAdmitted(by: removed))
    #expect(!child.isAdmitted(by: refollow))
    #expect(!PodcastCloudChildReference(subscriptionUUID: b, generationUUID: b).isAdmitted(by: refollow))
    let values = [old, removed, refollow]
    for x in values {
      for y in values {
        for z in values {
          #expect(try PodcastCloudFollowRegister.merge(x, y) == PodcastCloudFollowRegister.merge(y, x))
          #expect(
            try PodcastCloudFollowRegister.merge(PodcastCloudFollowRegister.merge(x, y), z)
              == PodcastCloudFollowRegister.merge(x, PodcastCloudFollowRegister.merge(y, z)))
        }
      }
    }
    let wrongParent = PodcastCloudFollowRegister(
      subscriptionUUID: b, generationUUID: a, isFollowed: true, stamp: try stamp(1))
    #expect(throws: PodcastCloudFollowRegister.ValidationError.subscriptionMismatch) {
      try PodcastCloudFollowRegister.merge(old, wrongParent)
    }
    let collision = PodcastCloudFollowRegister(
      subscriptionUUID: a, generationUUID: b, isFollowed: true, stamp: try stamp(1))
    #expect(throws: PodcastCloudFollowRegister.ValidationError.stampCollision) {
      try PodcastCloudFollowRegister.merge(old, collision)
    }
  }

  @Test func removedSaveIsDurableAndNewerExplicitSaveSurvives() throws {
    let date = Date(timeIntervalSince1970: 100)
    let save = try PodcastCloudSavedRegister(isSaved: true, savedAt: date, stamp: stamp(1))
    let removal = try PodcastCloudSavedRegister(isSaved: false, stamp: stamp(2))
    let resave = try PodcastCloudSavedRegister(isSaved: true, savedAt: date, stamp: stamp(3))
    #expect(try PodcastCloudSavedRegister.merge(save, removal) == removal)
    #expect(try PodcastCloudSavedRegister.merge(removal, resave) == resave)
    for x in [save, removal, resave] {
      for y in [save, removal, resave] {
        for z in [save, removal, resave] {
          #expect(try PodcastCloudSavedRegister.merge(x, y) == PodcastCloudSavedRegister.merge(y, x))
          #expect(
            try PodcastCloudSavedRegister.merge(PodcastCloudSavedRegister.merge(x, y), z)
              == PodcastCloudSavedRegister.merge(x, PodcastCloudSavedRegister.merge(y, z)))
        }
      }
    }
    let conflicting = try PodcastCloudSavedRegister(isSaved: false, stamp: stamp(1))
    #expect(throws: PodcastCloudSavedRegister.ValidationError.stampCollision) {
      try PodcastCloudSavedRegister.merge(save, conflicting)
    }
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(removal)) as? [String: Any])
    json["isSaved"] = true
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(PodcastCloudSavedRegister.self, from: JSONSerialization.data(withJSONObject: json))
    }
  }

  @Test func acknowledgementRequiresExactRecordGenerationAndAccountFence() {
    let fence = PodcastCloudAccountFence(
      container: "container", environment: "Development", zone: "zone", iCloudUserRecordID: "test-user", accountEpoch: 1
    )
    let send = PodcastCloudOutboxSend(recordName: "record", generation: 8, fence: fence)
    #expect(send.acceptsAcknowledgement(currentRecordName: "record", currentGeneration: 8, currentFence: fence))
    #expect(!send.acceptsAcknowledgement(currentRecordName: "other", currentGeneration: 8, currentFence: fence))
    #expect(!send.acceptsAcknowledgement(currentRecordName: "record", currentGeneration: 9, currentFence: fence))
    for changed in [
      PodcastCloudAccountFence(
        container: "other", environment: "Development", zone: "zone", iCloudUserRecordID: "test-user", accountEpoch: 1),
      PodcastCloudAccountFence(
        container: "container", environment: "Production", zone: "zone", iCloudUserRecordID: "test-user",
        accountEpoch: 1),
      PodcastCloudAccountFence(
        container: "container", environment: "Development", zone: "other", iCloudUserRecordID: "test-user",
        accountEpoch: 1),
      PodcastCloudAccountFence(
        container: "container", environment: "Development", zone: "zone", iCloudUserRecordID: "other-user",
        accountEpoch: 1),
      PodcastCloudAccountFence(
        container: "container", environment: "Development", zone: "zone", iCloudUserRecordID: "test-user",
        accountEpoch: 2),
    ] {
      #expect(!send.acceptsAcknowledgement(currentRecordName: "record", currentGeneration: 8, currentFence: changed))
    }
    let signedOut = PodcastCloudAccountFence(
      container: "container", environment: "Development", zone: "zone", iCloudUserRecordID: nil, accountEpoch: 1)
    #expect(
      !PodcastCloudOutboxSend(recordName: "record", generation: 8, fence: signedOut).acceptsAcknowledgement(
        currentRecordName: "record", currentGeneration: 8, currentFence: signedOut))
  }

  @Test func normalizationReusesExistingFeedContract() {
    for input in [
      "HTTPS://Example.COM:443/feed///?", "http://example.com/", "https://example.com/feed#one",
      "ftp://example.com/feed", "https://u:p@example.com/feed",
    ] {
      #expect(PodcastCloudIdentity.normalizedFeedURL(input) == PodcastFeedIdentity.normalized(input))
    }
    #expect(
      PodcastCloudIdentity.subscriptionUUID(feedURL: "https://example.com/feed/")
        == PodcastCloudIdentity.subscriptionUUID(feedURL: "HTTPS://EXAMPLE.COM:443/feed"))
    #expect(
      PodcastCloudIdentity.subscriptionUUID(feedURL: "https://example.com/feed#one")
        != PodcastCloudIdentity.subscriptionUUID(feedURL: "https://example.com/feed#two"))
    #expect(PodcastCloudIdentity.subscriptionUUID(feedURL: "https://u:p@example.com/feed") == nil)
    #expect(PodcastCloudIdentity.subscriptionUUID(feedURL: "ftp://example.com/feed") == nil)
  }

  @Test func recordNamesAreUniqueTypedAndBounded() throws {
    let id = try #require(PodcastCloudIdentity.subscriptionUUID(feedURL: "https://example.com/feed"))
    let uuid = id.uuidString.lowercased()
    #expect(uuid == "2a9a58b1-a77f-8354-89da-b15f26507fa8")
    #expect(Array(uuid)[14] == "8")
    let digest = PodcastCloudIdentity.episodeDigest(identityKey: "guid:x")
    #expect(digest == "40c6276d05fb47712fdbe1a7e9ad32edc8cad3a51fda559bdb61fdeac6afcfda")
    let components = [uuid, a.uuidString.lowercased(), digest]
    let names = try ["state", "saved", "identity"].map {
      try PodcastCloudIdentity.recordName(kind: $0, components: components, key: recordNameKey)
    }
    #expect(Set(names).count == 3)
    #expect(names.allSatisfy { $0.utf8.count < 255 && $0.unicodeScalars.allSatisfy(\.isASCII) })
    let stateName = try PodcastCloudIdentity.recordName(kind: "state", components: components, key: recordNameKey)
    let expectedStateName =
      "v1.state.f7fc1d7b-209d-8936-81af-39a7d3be9227."
      + "6210a834-525b-8dc2-a9cc-df6dc2117031."
      + "92c07c1d77c1a64b8635328b120db1139234bd19f7122a1fef80298b3e9f1cdc"
    #expect(stateName == expectedStateName)
    let reproducedStateName = try PodcastCloudIdentity.recordName(
      kind: "state", components: components, key: recordNameKey)
    #expect(stateName == reproducedStateName)
    let otherKey = try PodcastCloudRecordNameKey(bytes: Data(repeating: 0x02, count: 32))
    let otherName = try PodcastCloudIdentity.recordName(kind: "state", components: components, key: otherKey)
    #expect(otherName != stateName)
    #expect(stateName.contains(uuid) == false)
    #expect(stateName.contains(digest) == false)
    let keyedComponents = stateName.split(separator: ".").dropFirst(2).map(String.init)
    for component in keyedComponents.prefix(2) {
      let keyedUUID = try #require(UUID(uuidString: component))
      #expect(keyedUUID.uuidString.lowercased() == component)
      #expect(Array(component)[14] == "8")
    }
    #expect(keyedComponents[2].count == 64)
    #expect(keyedComponents[2].utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
    for kind in ["globals", "bookmark", "keyring"] {
      let expected = "v1.\(kind)"
      #expect(try PodcastCloudIdentity.recordName(kind: kind, components: [], key: recordNameKey) == expected)
      #expect(try PodcastCloudIdentity.recordName(kind: kind, components: [], key: otherKey) == expected)
    }
    #expect(
      try PodcastCloudIdentity.recordName(kind: "keyring", components: [], key: recordNameKey)
        == PodcastCloudIdentity.keyringRecordName)
    #expect(throws: PodcastCloudIdentity.RecordNameError.invalid) {
      try PodcastCloudIdentity.recordName(kind: "keyring", components: [uuid], key: recordNameKey)
    }
    for invalid in [
      ["https://example.com"], [uuid], [uuid, uuid, "bad"], [uuid, uuid, String(repeating: "a", count: 65)],
    ] {
      #expect(throws: PodcastCloudIdentity.RecordNameError.invalid) {
        try PodcastCloudIdentity.recordName(kind: "state", components: invalid, key: recordNameKey)
      }
    }
    #expect(throws: PodcastCloudIdentity.RecordNameError.invalid) {
      try PodcastCloudIdentity.recordName(kind: "", components: [], key: recordNameKey)
    }
  }

  @Test func recordNameKeyIsFixedLengthRandomAndRedactsMaterial() throws {
    #expect(throws: PodcastCloudKeyringError.invalidKeyLength) {
      try PodcastCloudRecordNameKey(bytes: Data(repeating: 0, count: 31))
    }
    #expect(throws: PodcastCloudKeyringError.invalidKeyLength) {
      try PodcastCloudRecordNameKey(bytes: Data(repeating: 0, count: 33))
    }
    #expect(PodcastCloudRecordNameKey.mint() != PodcastCloudRecordNameKey.mint())
    let description = String(describing: recordNameKey)
    let hex = recordNameKey.bytes.map { String(format: "%02x", $0) }.joined()
    #expect(description == "PodcastCloudRecordNameKey(32 bytes)")
    #expect(description.contains(hex) == false)
    #expect(String(reflecting: recordNameKey).contains(hex) == false)
  }
}
