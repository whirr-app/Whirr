import GRDB

/// One explicitly pinned playback-rate override for an item. The absence of a row means inherit
/// the global playback rate; a row equal to the current global rate is still meaningful because it
/// pins the title against a future global-default change.
public struct ItemPlaybackSettingsRecord: Codable, Equatable, Sendable, FetchableRecord,
  PersistableRecord
{
  public static let databaseTableName = "itemPlaybackSettings"

  public var itemId: Int64
  public var accountId: Int64
  public var rateStep: Int

  public init(itemId: Int64, accountId: Int64, rateStep: Int) {
    self.itemId = itemId
    self.accountId = accountId
    self.rateStep = rateStep
  }
}
