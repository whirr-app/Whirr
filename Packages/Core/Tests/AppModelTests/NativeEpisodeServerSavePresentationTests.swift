import Persistence
import SyncEngine
import Testing

@testable import AppModel

@Suite("Native episode server-save presentation")
struct NativeEpisodeServerSavePresentationTests {
  @Test("every durable state maps to its exact presentation state")
  func everyStateMapsExhaustively() {
    let category: NativeEpisodeServerSaveErrorCategory = .transport
    let mappings: [(NativeEpisodeServerSaveAttemptState, NativeEpisodeServerSaveStatus)] = [
      (.preparing, .preparing),
      (.creatingShow, .preparing),
      (.requestingDownload, .requested),
      (.accepted, .requested),
      (.confirmed, .saved),
      (.deleting, .removing),
      (.removed, .removed),
      (.createUncertain, .uncertain(category, phase: .save)),
      (.deleteUncertain, .uncertain(category, phase: .remove)),
      (.uncertain, .uncertain(category, phase: .save)),
      (.failed, .failed(category, phase: .save)),
      (.deleteFailed, .failed(category, phase: .remove)),
    ]

    for (state, expected) in mappings {
      #expect(NativeEpisodeServerSaveStatus.status(for: state, category: category) == expected)
    }
  }

  @Test("accepted/requested never shares the saved/confirmed state or copy")
  func requestedIsNotSaved() {
    let requested = NativeEpisodeServerSaveStatus.status(
      for: .accepted, category: .transport)
    let saved = NativeEpisodeServerSaveStatus.status(
      for: .confirmed, category: .transport)

    #expect(requested == .requested)
    #expect(saved == .saved)
    #expect(requested != saved)
    #expect(NativeEpisodeServerSaveCopy.requested != NativeEpisodeServerSaveCopy.saved)
    #expect(
      NativeEpisodeServerSaveCopy.accessibilityLabel(for: requested)
        != NativeEpisodeServerSaveCopy.accessibilityLabel(for: saved))
  }

  @Test("lifecycle teardown distinguishes only the unsent preparing state")
  func lifecycleSendBoundaryIsExplicit() {
    #expect(NativeEpisodeServerSaveStatus.none.hasReachedServerSend == false)
    #expect(NativeEpisodeServerSaveStatus.preparing.hasReachedServerSend == false)
    for status: NativeEpisodeServerSaveStatus in [
      .requested, .saved, .removing, .removed,
      .uncertain(.transport, phase: .save), .failed(.transport, phase: .remove),
    ] {
      #expect(status.hasReachedServerSend)
    }
  }

  @Test("non-native episodes hide both actions")
  func nonNativeHidesBothActions() {
    let capability = fullCapability
    #expect(
      NativeEpisodeServerSaveStatus.saveAvailability(
        capability: capability, isNativeFeed: false, isCredentialedFeed: false, status: .none)
        == .hidden)
    #expect(
      NativeEpisodeServerSaveStatus.removeAvailability(
        capability: capability, isNativeFeed: false, status: .saved,
        preflightPresence: .absentBeforeRequest)
        == .hidden)
  }

  @Test("native episodes expose allowed actions")
  func nativeExposesAllowedActions() {
    #expect(
      NativeEpisodeServerSaveStatus.saveAvailability(
        capability: fullCapability, isNativeFeed: true, isCredentialedFeed: false, status: .none)
        == .enabled)
    #expect(
      NativeEpisodeServerSaveStatus.removeAvailability(
        capability: fullCapability, isNativeFeed: true, status: .saved,
        preflightPresence: .absentBeforeRequest)
        == .enabled)
  }

  @Test("missing Save permission hides Save, while permission enables it")
  func savePermissionControlsVisibility() {
    #expect(
      NativeEpisodeServerSaveStatus.saveAvailability(
        capability: ServerPodcastMutationCapability(canSave: false, canRemove: false),
        isNativeFeed: true, isCredentialedFeed: true, status: .none)
        == .hidden)
    #expect(
      NativeEpisodeServerSaveStatus.saveAvailability(
        capability: fullCapability, isNativeFeed: true, isCredentialedFeed: false, status: .none)
        == .enabled)
  }

  @Test("missing Remove permission hides Remove, while permission enables it")
  func removePermissionControlsVisibility() {
    #expect(
      NativeEpisodeServerSaveStatus.removeAvailability(
        capability: ServerPodcastMutationCapability(canSave: true, canRemove: false),
        isNativeFeed: true, status: .saved, preflightPresence: .absentBeforeRequest)
        == .hidden)
    #expect(
      NativeEpisodeServerSaveStatus.removeAvailability(
        capability: fullCapability, isNativeFeed: true, status: .saved,
        preflightPresence: .absentBeforeRequest)
        == .enabled)
  }

  @Test("credentialed Save is disabled with its reason after permission passes")
  func credentialedFeedGetsDisabledReason() {
    #expect(
      NativeEpisodeServerSaveStatus.saveAvailability(
        capability: fullCapability, isNativeFeed: true, isCredentialedFeed: true, status: .none)
        == .disabled(.credentialedFeed))
    #expect(
      NativeEpisodeServerSaveCopy.disabledReason(.credentialedFeed)
        == "Episodes from private feeds cannot be saved to the server.")
  }

  @Test("Save hides while present or sent")
  func saveHidesForPresentAndInFlightStates() {
    let hidden: [NativeEpisodeServerSaveStatus] = [
      .requested, .saved, .removing,
    ]
    for status in hidden {
      #expect(
        NativeEpisodeServerSaveStatus.saveAvailability(
          capability: fullCapability, isNativeFeed: true, isCredentialedFeed: false, status: status)
          == .hidden)
    }
    #expect(
      NativeEpisodeServerSaveStatus.saveAvailability(
        capability: fullCapability, isNativeFeed: true, isCredentialedFeed: false, status: .none)
        == .enabled)
  }

  @Test("a preparing row has sent nothing, so Save stays offered as the way to resume it")
  func saveStaysOfferedWhilePreparing() {
    #expect(
      NativeEpisodeServerSaveStatus.saveAvailability(
        capability: fullCapability, isNativeFeed: true, isCredentialedFeed: false,
        status: .preparing)
        == .enabled)
    #expect(
      NativeEpisodeServerSaveStatus.removeAvailability(
        capability: fullCapability, isNativeFeed: true, status: .preparing,
        preflightPresence: nil)
        == .hidden)
  }

  @Test("Save is enabled for removed and definitive failed attempts")
  func saveCanRetryRemovedAndFailed() {
    for status: NativeEpisodeServerSaveStatus in [.removed, .failed(.invalidDestination, phase: .save)] {
      #expect(
        NativeEpisodeServerSaveStatus.saveAvailability(
          capability: fullCapability, isNativeFeed: true, isCredentialedFeed: false, status: status)
          == .enabled)
    }
  }

  @Test("Save uncertainty is disabled and never offered as a plain retry")
  func saveUncertaintyIsGated() {
    #expect(
      NativeEpisodeServerSaveStatus.saveAvailability(
        capability: fullCapability, isNativeFeed: true, isCredentialedFeed: false,
        status: .uncertain(.transport, phase: .save))
        == .disabled(.uncertainOutcome))
    #expect(
      NativeEpisodeServerSaveStatus.saveAvailability(
        capability: fullCapability, isNativeFeed: true, isCredentialedFeed: false,
        status: .failed(.transport, phase: .save))
        == .enabled)
  }

  @Test("Remove requires a confirmed episode absent before Whirr's request")
  func removeRequiresWhirrOwnedEpisode() {
    #expect(
      NativeEpisodeServerSaveStatus.removeAvailability(
        capability: fullCapability, isNativeFeed: true, status: .saved,
        preflightPresence: .absentBeforeRequest)
        == .enabled)
    #expect(
      NativeEpisodeServerSaveStatus.removeAvailability(
        capability: fullCapability, isNativeFeed: true, status: .saved,
        preflightPresence: .preExisting)
        == .hidden)
    #expect(
      NativeEpisodeServerSaveStatus.removeAvailability(
        capability: fullCapability, isNativeFeed: true, status: .saved, preflightPresence: nil)
        == .hidden)
  }

  @Test("Remove disables only while a removal is in flight; a stalled removal may be retried")
  func removeReconciliationStatesAreDisabled() {
    #expect(
      NativeEpisodeServerSaveStatus.removeAvailability(
        capability: fullCapability, isNativeFeed: true, status: .removing,
        preflightPresence: .absentBeforeRequest)
        == .disabled(.removalInProgress))
    for status: NativeEpisodeServerSaveStatus in [
      .uncertain(.transport, phase: .remove), .uncertain(.localPersistence, phase: .remove),
      .failed(.transport, phase: .remove),
    ] {
      #expect(
        NativeEpisodeServerSaveStatus.removeAvailability(
          capability: fullCapability, isNativeFeed: true, status: status,
          preflightPresence: .absentBeforeRequest)
          == .enabled,
        "the coordinator re-observes before any resend, so an explicit retry is the only exit")
    }
    for status: NativeEpisodeServerSaveStatus in [.none, .preparing, .requested, .removed] {
      #expect(
        NativeEpisodeServerSaveStatus.removeAvailability(
          capability: fullCapability, isNativeFeed: true, status: status,
          preflightPresence: .absentBeforeRequest)
          == .hidden)
    }
  }

  @Test("each disabled reason has closed, privacy-safe copy")
  func disabledReasonCopyIsComplete() {
    let reasons: [NativeEpisodeServerSaveDisabledReason] = [
      .permissionChanged, .invalidDestination, .credentialedFeed, .unsubscribed,
      .missingEpisode, .unavailable, .uncertainOutcome, .removalInProgress,
    ]
    for reason in reasons {
      #expect(NativeEpisodeServerSaveCopy.disabledReason(reason).isEmpty == false)
    }
  }

  @Test("copy contains no URLs, paths, or unproven storage promises")
  func copyAudit() {
    let statuses: [NativeEpisodeServerSaveStatus] = [
      .none, .preparing, .requested, .saved, .removing, .removed,
      .uncertain(.transport, phase: .save), .failed(.transport, phase: .save),
      .uncertain(.transport, phase: .remove), .failed(.transport, phase: .remove),
    ]
    let reasons: [NativeEpisodeServerSaveDisabledReason] = [
      .permissionChanged, .invalidDestination, .credentialedFeed, .unsubscribed,
      .missingEpisode, .unavailable, .uncertainOutcome, .removalInProgress,
    ]
    let strings =
      [
        NativeEpisodeServerSaveCopy.none,
        NativeEpisodeServerSaveCopy.preparing,
        NativeEpisodeServerSaveCopy.requested,
        NativeEpisodeServerSaveCopy.saved,
        NativeEpisodeServerSaveCopy.removing,
        NativeEpisodeServerSaveCopy.removed,
        NativeEpisodeServerSaveCopy.saveAction,
        NativeEpisodeServerSaveCopy.removeAction,
        NativeEpisodeServerSaveCopy.removeConsequence,
        NativeEpisodeServerSaveCopy.saveUncertain,
        NativeEpisodeServerSaveCopy.removeUncertain,
      ] + reasons.map(NativeEpisodeServerSaveCopy.disabledReason)
      + statuses.map(NativeEpisodeServerSaveCopy.accessibilityLabel)

    for value in strings {
      let lowercase = value.lowercased()
      #expect(value.contains("://") == false)
      #expect(value.contains("/Users") == false)
      #expect(lowercase.contains("http") == false)
      // The ban is on claiming reclaimed storage, not on the word. `removeConsequence` is
      // required to say reclamation is unknown, so a bare keyword ban would forbid the very
      // sentence the plan mandates.
      for claim in [
        "storage is freed", "frees storage", "space is freed", "frees up",
        "storage is reclaimed", "reclaims storage",
      ] {
        #expect(lowercase.contains(claim) == false)
      }
    }
  }

  @Test("Remove's consequence states server-wide effect and disclaims storage reclamation")
  func removeConsequenceMatchesThePlan() {
    let copy = NativeEpisodeServerSaveCopy.removeConsequence.lowercased()
    // Server-wide effect on all three references the plan enumerates.
    #expect(copy.contains("progress"))
    #expect(copy.contains("playlist"))
    #expect(copy.contains("everyone on the server"))
    // The affirmative disclaimer. Live evidence never established that removal reclaims storage.
    #expect(copy.contains("not known") || copy.contains("not proven"))
    #expect(copy.contains("storage"))
  }

  @Test("A failed or uncertain save never exposes a Remove entry")
  func saveSideFailuresHideRemove() {
    for status: NativeEpisodeServerSaveStatus in [
      .failed(.transport, phase: .save), .uncertain(.transport, phase: .save),
    ] {
      #expect(
        NativeEpisodeServerSaveStatus.removeAvailability(
          capability: fullCapability, isNativeFeed: true, status: status,
          preflightPresence: .absentBeforeRequest)
          == .hidden,
        "a save that never confirmed put nothing on the server to remove")
    }
  }

  @Test("A failed removal leaves the episode on the server, so Save is not re-offered")
  func failedRemovalDoesNotOfferSave() {
    #expect(
      NativeEpisodeServerSaveStatus.saveAvailability(
        capability: fullCapability, isNativeFeed: true, isCredentialedFeed: false,
        status: .failed(.transport, phase: .remove))
        == .hidden,
      "re-saving an episode still present on the server duplicates the row and the file")
  }

  @Test("Uncertainty copy is selected by the phase that stalled")
  func uncertaintyCopyFollowsPhase() {
    #expect(
      NativeEpisodeServerSaveCopy.uncertain(phase: .save) == NativeEpisodeServerSaveCopy.saveUncertain)
    #expect(
      NativeEpisodeServerSaveCopy.uncertain(phase: .remove)
        == NativeEpisodeServerSaveCopy.removeUncertain)
    #expect(
      NativeEpisodeServerSaveCopy.uncertain(phase: .save)
        != NativeEpisodeServerSaveCopy.uncertain(phase: .remove))
  }

  private var fullCapability: ServerPodcastMutationCapability {
    ServerPodcastMutationCapability(canSave: true, canRemove: true)
  }
}
