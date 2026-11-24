import ABSApi
import Foundation
import WatchProtocol

/// Why a phone request produced no file to download: the server or the plan refused it before any
/// manifest existed, so the download store has nothing to remember it by.
public enum WatchABSRequestOutcome: Sendable, Equatable {
  case failed(WatchABSInventoryEntry.FailureReason)
  case declined(WatchABSInventoryEntry.DeclineReason)

  /// `nil` for a cancelled or superseded request: that is not a failure to remember, and the next
  /// reconcile tries again.
  public init?(_ error: any Error) {
    switch error {
    case is CancellationError:
      return nil
    case let error as APIError:
      switch error {
      case .cancelled: return nil
      case .notFound: self = .failed(.itemMissing)
      case .unauthorized, .forbidden: self = .failed(.httpStatus)
      case .transport: self = .failed(.network)
      default: self = .failed(.invalidResponse)
      }
    case let error as URLError:
      if error.code == .cancelled { return nil }
      self = .failed(.network)
    case let error as WatchLibraryError:
      switch error {
      case .staleRequest: return nil
      case .notAuthenticated, .accountMismatch: self = .failed(.httpStatus)
      default: self = .failed(.planInvalid)
      }
    case is TokenStoreError:
      self = .failed(.httpStatus)
    case let error as WatchDownloadPlanningError:
      switch error {
      case .episodeNotFound: self = .failed(.itemMissing)
      case .noAudioFiles, .unsupportedMedia: self = .failed(.noAudio)
      default: self = .failed(.planInvalid)
      }
    case WatchDownloadStoreError.quotaExceeded, WatchABSAdmissionError.insufficientSpace:
      self = .declined(.storageFull)
    default:
      self = .failed(.planInvalid)
    }
  }

  /// A network failure is retried when the network returns or the app next activates; every other
  /// outcome waits for the phone to send a new revision.
  public var retriesWhenTheNetworkReturns: Bool { self == .failed(.network) }
}

public enum WatchABSAdmissionError: Error, Sendable, Equatable {
  case insufficientSpace
}

/// Admits a whole plan against the Watch's shared budget before its first file is enqueued, so a
/// book too big for the Watch is declined once rather than enqueued in part and then refused. It
/// only checks: the store still claims each file as it enqueues it.
public enum WatchABSAdmission {
  public static func admits(additionalBytes: Int64, budget: WatchStorageBudget) -> Bool {
    additionalBytes <= max(0, budget.totalBytes - budget.usedBytes)
  }

  /// The plan's bytes for files the store does not already hold. A held file, failed or not, keeps
  /// or regains its own reservation through the store's retry.
  public static func additionalBytes(
    for plan: [WatchDownloadDescriptor], held: [WatchDownloadManifest]
  ) -> Int64 {
    let heldFiles = Set(held.map { HeldFile(selection: $0.selection, fileID: $0.fileID, fileIndex: $0.fileIndex) })
    return plan.reduce(Int64(0)) { total, descriptor in
      let file = HeldFile(selection: descriptor.selection, fileID: descriptor.fileID, fileIndex: descriptor.fileIndex)
      guard heldFiles.contains(file) == false else { return total }
      let sum = total.addingReportingOverflow(max(0, descriptor.expectedBytes))
      return sum.overflow ? Int64.max : sum.partialValue
    }
  }

  private struct HeldFile: Hashable {
    let selection: WatchSelection
    let fileID: String
    let fileIndex: Int
  }
}
