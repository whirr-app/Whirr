import Foundation
import Persistence

/// `Persistence` depends on GRDB alone and cannot see `PodcastCloudClockState`, so the table's
/// transfer value is flat and the mapping lives here, the direction the dependency graph allows.
/// `PodcastCloudClockFields` holds the identity as text because everything else in the registry
/// does; this is the one place that text has to be a real UUID.
extension PodcastCloudClockState {
  public init(_ fields: PodcastCloudClockFields) throws {
    guard let installationUUID = UUID(uuidString: fields.installationUUID) else {
      throw PodcastCloudInstallationError.invalidRecord
    }
    try self.init(
      installationUUID: installationUUID,
      physicalMilliseconds: fields.physicalMilliseconds,
      logicalCounter: fields.logicalCounter,
      anchorServerMilliseconds: fields.anchorServerMilliseconds,
      lastAdmittedPhysicalMilliseconds: fields.lastAdmittedPhysicalMilliseconds,
      lastAdmittedLogicalCounter: fields.lastAdmittedLogicalCounter,
      repairRequired: fields.repairRequired)
  }
}

extension PodcastCloudClockFields {
  public init(_ state: PodcastCloudClockState) {
    self.init(
      installationUUID: state.installationUUID.uuidString.lowercased(),
      physicalMilliseconds: state.physicalMilliseconds,
      logicalCounter: state.logicalCounter,
      anchorServerMilliseconds: state.anchorServerMilliseconds,
      lastAdmittedPhysicalMilliseconds: state.lastAdmittedPhysicalMilliseconds,
      lastAdmittedLogicalCounter: state.lastAdmittedLogicalCounter,
      repairRequired: state.repairRequired)
  }
}
