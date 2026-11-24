import AppModel
import CloudKit
import CoreSupport
import Foundation
import os

/// The iCloud account, read from the container. Translation only: which answers start a session,
/// and which open a new account epoch, is `PodcastCloudAccountPolicy` in Core.
struct PodcastCloudKitAccountReading: PodcastCloudAccountReading {
  let containerIdentifier: String
  private static let log = CoreLogging.logger(category: "PodcastCloudSync")

  func currentAccount() async -> PodcastCloudAccountState {
    let container = CKContainer(identifier: containerIdentifier)
    let status: CKAccountStatus
    do {
      status = try await container.accountStatus()
    } catch {
      Self.logUnknown("account status threw", error)
      return .unknown
    }
    switch status {
    case .available:
      // The user record ID can need the network; failing to read it is not a sign-out.
      do {
        return .available(userRecordID: try await container.userRecordID().recordName)
      } catch {
        Self.logUnknown("user record ID threw", error)
        return .unknown
      }
    case .noAccount, .restricted:
      return .noAccount
    case .couldNotDetermine, .temporarilyUnavailable:
      Self.log.error("Podcast sync account unknown: status \(status.rawValue, privacy: .public)")
      return .unknown
    @unknown default:
      Self.log.error("Podcast sync account unknown: status \(status.rawValue, privacy: .public)")
      return .unknown
    }
  }

  /// Domain and code only: a CloudKit error's description can carry record or account detail.
  private static func logUnknown(_ step: StaticString, _ error: any Error) {
    let error = error as NSError
    log.error(
      "Podcast sync account unknown: \(step, privacy: .public): \(error.domain, privacy: .public) \(error.code, privacy: .public)"
    )
  }
}
