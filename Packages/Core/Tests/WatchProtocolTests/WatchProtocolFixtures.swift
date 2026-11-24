import Foundation

@testable import WatchProtocol

enum WatchProtocolFixtures {
  static func accountStamp() -> WatchAccountStamp {
    try! WatchAccountStamp(accountIdentityHash: "account-hash", serverIdentityHash: "server-hash")
  }

  static func otherAccountStamp() -> WatchAccountStamp {
    try! WatchAccountStamp(accountIdentityHash: "other-account", serverIdentityHash: "server-hash")
  }

  static func absSelection(itemID: String = "book", episodeID: String? = "episode") -> WatchABSSelection {
    try! WatchABSSelection(itemID: itemID, episodeID: episodeID)
  }

  static func nativeSelection(feedID: String = "feed", episodeID: String = "episode") -> WatchSelection {
    .nativeFeed(feedID: feedID, episodeID: episodeID)
  }

  static func catalogueItem(
    id: String = "book", selection: WatchSelection = absSelection(episodeID: nil).watchSelection,
    section: WatchCatalogueSection = .recentBooks, progressSeconds: Double = 20,
    durationSeconds: Double? = 100, isCurrentPlayback: Bool = true
  ) throws -> WatchCatalogueItem {
    try WatchCatalogueItem(
      id: id, selection: selection, title: "Book", section: section,
      progressSeconds: progressSeconds, durationSeconds: durationSeconds, isCurrentPlayback: isCurrentPlayback,
      capabilities: WatchSelectionCapabilities(phonePlayable: true, watchPlayable: false))
  }

  static func snapshot(account: WatchAccountStamp = accountStamp(), at time: TimeInterval = 100) throws
    -> WatchCatalogueSnapshot
  {
    try WatchCatalogueSnapshot(
      accountStamp: account,
      generatedAt: Date(timeIntervalSinceReferenceDate: time), items: [catalogueItem()], playbackState: .playing)
  }

  static func browsePage(
    page: Int = 0, pageSize: Int = 1, rows: [WatchBrowseRow] = [],
    nextPage: Int? = nil, isComplete: Bool = true, generation: UInt64 = 1
  ) throws -> WatchBrowsePage {
    try WatchBrowsePage(
      page: page, pageSize: pageSize, rows: rows, nextPage: nextPage,
      isComplete: isComplete, generation: generation)
  }

  static func setupCredentials(
    for challenge: WatchSetupChallenge, account: WatchAccountStamp? = nil,
    nonce: UUID? = nil, expiry: Date? = nil,
    accessExpiry: Date? = Date(timeIntervalSince1970: 1_800_003_600)
  ) throws -> WatchSetupCredentials {
    try WatchSetupCredentials(
      id: challenge.id, accountStamp: account ?? challenge.accountStamp,
      nonce: nonce ?? challenge.nonce, expiresAt: expiry ?? challenge.expiresAt,
      serverURL: "https://abs.example.test/abs", userID: "user-1", username: "reader",
      defaultLibraryID: "library-1", accessToken: "access-token", refreshToken: "refresh-token",
      accessExpiry: accessExpiry)
  }

  static func roundTrip<Value: WatchWireValue>(_ value: Value) throws -> Value {
    try WatchWireCodec.decode(Value.self, from: WatchWireCodec.encode(value))
  }
}
