import Persistence
import SyncEngine

/// Which half of the lifecycle an uncertain or failed attempt came from.
///
/// The durable record distinguishes `.deleteUncertain`/`.deleteFailed` from `.uncertain`/`.failed`
/// and the presentation must not collapse them: consumers would fail closed on both, showing a
/// disabled Remove entry beside an episode never on the server and making the separate save/remove
/// uncertainty copy unreachable.
public enum NativeEpisodeServerSavePhase: Sendable, Equatable {
  case save
  case remove
}

/// External lifecycle events that invalidate an episode server-save presentation without
/// authorizing any mutation of its durable attempt.
public enum NativeEpisodeServerSaveLifecycleTrigger: Sendable, Equatable {
  case nativeSubscriptionsDisabled
  case accountUnavailable
  case accountReplaced
}

extension NativeEpisodeServerSaveLifecycleTrigger {
  /// Every trigger hides the server actions until a fresh capability read. Only an account change
  /// makes the cached server answer itself stale.
  var invalidatesCapability: Bool {
    switch self {
    case .nativeSubscriptionsDisabled: return false
    case .accountUnavailable, .accountReplaced: return true
    }
  }
}

/// The durable server-save lifecycle as it is presented beside a native RSS episode.
public enum NativeEpisodeServerSaveStatus: Sendable, Equatable {
  case none
  case preparing
  case requested
  case saved
  case removing
  case removed
  case uncertain(NativeEpisodeServerSaveErrorCategory, phase: NativeEpisodeServerSavePhase)
  case failed(NativeEpisodeServerSaveErrorCategory, phase: NativeEpisodeServerSavePhase)

  /// Projects one durable state without collapsing accepted into confirmed.
  public static func status(
    for state: NativeEpisodeServerSaveAttemptState,
    category: NativeEpisodeServerSaveErrorCategory
  ) -> NativeEpisodeServerSaveStatus {
    switch state {
    case .preparing, .creatingShow:
      return .preparing
    case .requestingDownload, .accepted:
      return .requested
    case .confirmed:
      return .saved
    case .deleting:
      return .removing
    case .removed:
      return .removed
    case .createUncertain, .uncertain:
      return .uncertain(category, phase: .save)
    case .deleteUncertain:
      return .uncertain(category, phase: .remove)
    case .failed:
      return .failed(category, phase: .save)
    case .deleteFailed:
      return .failed(category, phase: .remove)
    }
  }

  /// Lifecycle teardown uses this distinction only to describe what may have happened before the
  /// account or native-subscription context disappeared. Preparing is the only presentation state
  /// guaranteed not to have reached a send; requesting and every later state must be treated as
  /// potentially sent. In either case teardown clears in-memory presentation only and never edits
  /// the durable attempt.
  public var hasReachedServerSend: Bool {
    switch self {
    case .none, .preparing:
      return false
    case .requested, .saved, .removing, .removed, .uncertain, .failed:
      return true
    }
  }
}

/// Why a Save or Remove entry is visible but unavailable.
public enum NativeEpisodeServerSaveDisabledReason: Sendable, Equatable {
  case permissionChanged
  case invalidDestination
  case credentialedFeed
  case unsubscribed
  case missingEpisode
  case unavailable
  case uncertainOutcome
  case removalInProgress
}

public enum NativeEpisodeServerSaveAvailability: Sendable, Equatable {
  case hidden
  case enabled
  case disabled(NativeEpisodeServerSaveDisabledReason)
}

extension NativeEpisodeServerSaveStatus {
  /// Decides whether the Save action belongs on a native RSS episode surface.
  public static func saveAvailability(
    capability: ServerPodcastMutationCapability,
    isNativeFeed: Bool,
    isCredentialedFeed: Bool,
    status: NativeEpisodeServerSaveStatus
  ) -> NativeEpisodeServerSaveAvailability {
    guard isNativeFeed else { return .hidden }
    guard capability.canSave else { return .hidden }
    if isCredentialedFeed {
      return .disabled(.credentialedFeed)
    }

    switch status {
    case .none, .removed:
      return .enabled
    // A failed save may be retried by hand. A failed removal leaves the episode on the server,
    // so offering Save there would duplicate the row and the file.
    case .failed(_, .save):
      return .enabled
    case .failed(_, .remove):
      return .hidden
    // Neither uncertainty is safe to resend: the episode may already be on the server. The entry
    // stays visible so the reason is readable, but it is never a plain retry.
    case .uncertain:
      return .disabled(.uncertainOutcome)
    // Preparing has sent nothing. A durable preparing row outlives a dismissed destination sheet
    // or an interrupted launch and recovery never revisits it, so hiding Save would lock the
    // episode out for good. The coordinator resumes the existing row rather than opening a second
    // one, and a tap during a live flight joins that flight.
    case .preparing:
      return .enabled
    case .requested, .saved, .removing:
      return .hidden
    }
  }

  /// The status half of `removeAvailability`: a confirmed copy, or a removal that stalled and is
  /// retried through the same coordinator entry point. A model's Remove checks this, then the
  /// provenance and the attempt it would remove.
  var isRemovable: Bool {
    switch self {
    case .saved, .uncertain(_, .remove), .failed(_, .remove): return true
    default: return false
    }
  }

  /// Decides whether the Remove action belongs on an episode surface. `isNativeFeed` is read as
  /// "this surface can identify a Whirr-saved copy": true for a native RSS show or card, and
  /// also for a server show or card whose rows are keyed by the server episode ids Whirr
  /// confirmed (`PodcastShowServerSaveModel.hostsServerSaveRemoval`). The status and provenance
  /// gates below keep the entry to confirmed, Whirr-created copies on either kind of surface.
  public static func removeAvailability(
    capability: ServerPodcastMutationCapability,
    isNativeFeed: Bool,
    status: NativeEpisodeServerSaveStatus,
    preflightPresence: NativeEpisodeServerSavePreflightPresence?
  ) -> NativeEpisodeServerSaveAvailability {
    guard isNativeFeed else { return .hidden }
    guard capability.canRemove else { return .hidden }

    switch status {
    case .saved:
      guard preflightPresence == .absentBeforeRequest else { return .hidden }
      return .enabled
    case .removing:
      return .disabled(.removalInProgress)
    // A removal that did not resolve is offered as an explicit retry. The coordinator observes
    // the item before anything is sent and never repeats the DELETE for a proven absence, so the
    // entry is safe. Leaving it disabled would strand a stalled row.
    case .uncertain(_, .remove), .failed(_, .remove):
      return .enabled
    // A save that never confirmed put nothing on the server that this action could remove.
    case .uncertain(_, .save), .failed(_, .save):
      return .hidden
    case .none, .preparing, .requested, .removed:
      return .hidden
    }
  }
}
