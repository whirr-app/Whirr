import Foundation
import Testing

@testable import SyncEngine

/// The ebook policy is the field-level counterpart to `ProgressMergePolicyTests`' audio
/// coverage. The shared ordering is exercised through the composite result so an item-wide
/// finish flag can resolve independently from either position field.
struct EbookProgressMergePolicyTests {

  private let deviceKey = "11111111-1111-1111-1111-111111111111"

  private func current(
    currentTime: TimeInterval = 120,
    ebookProgress: Double? = nil,
    readingPositionJSON: String? = nil,
    isFinished: Bool = false,
    serverUpdatedAt: Date? = nil,
    hasUnacknowledgedAudioOperation: Bool = false,
    hasUnacknowledgedEbookOperation: Bool = false,
    hasUnacknowledgedFinishOperation: Bool = false
  ) -> ProgressMergePolicy.CurrentState {
    ProgressMergePolicy.CurrentState(
      currentTime: currentTime,
      isFinished: isFinished,
      serverUpdatedAt: serverUpdatedAt,
      localSequence: 10,
      originKey: deviceKey,
      hasUnacknowledgedLocalOperation: false,
      ebookProgress: ebookProgress,
      readingPositionJSON: readingPositionJSON,
      hasUnacknowledgedAudioOperation: hasUnacknowledgedAudioOperation,
      hasUnacknowledgedEbookOperation: hasUnacknowledgedEbookOperation,
      hasUnacknowledgedFinishOperation: hasUnacknowledgedFinishOperation
    )
  }

  private func serverPull(
    currentTime: TimeInterval = 120,
    ebookProgress: Double? = nil,
    ebookLocation: String? = nil,
    isFinished: Bool = false,
    serverUpdatedAt: Date?,
    signalsExplicitResetOrUnfinished: Bool = false
  ) -> ProgressMergePolicy.IncomingObservation {
    ProgressMergePolicy.IncomingObservation(
      currentTime: currentTime,
      isFinished: isFinished,
      serverUpdatedAt: serverUpdatedAt,
      originKey: ProgressMergePolicy.serverOriginKey,
      signalsExplicitResetOrUnfinished: signalsExplicitResetOrUnfinished,
      ebookProgress: ebookProgress,
      ebookLocation: ebookLocation
    )
  }

  @Test func serverEbookPullAppliesUnderTransposedOrdering() {
    let policy = ProgressMergePolicy()
    let current = current(
      ebookProgress: 0.2, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    let incoming = serverPull(
      ebookProgress: 0.75, serverUpdatedAt: Date(timeIntervalSince1970: 2_000))

    #expect(policy.resolveEbook(current: current, incoming: incoming) == .applyServer)
  }

  @Test func nearZeroServerEbookProgressRecordsNeedsResolution() {
    let policy = ProgressMergePolicy()
    let current = current(
      ebookProgress: 0.020_001, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    let incoming = serverPull(
      ebookProgress: 0.005, serverUpdatedAt: Date(timeIntervalSince1970: 2_000))

    #expect(policy.resolveEbook(current: current, incoming: incoming) == .needsResolution)
  }

  @Test func explicitEbookResetBypassesTheZeroOverwriteGuard() {
    let policy = ProgressMergePolicy()
    let current = current(
      ebookProgress: 0.4, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    let incoming = ProgressMergePolicy.IncomingObservation(
      currentTime: 120,
      isFinished: false,
      serverUpdatedAt: Date(timeIntervalSince1970: 2_000),
      originKey: ProgressMergePolicy.serverOriginKey,
      signalsExplicitResetOrUnfinished: true,
      ebookProgress: 0
    )

    #expect(policy.resolveEbook(current: current, incoming: incoming) == .applyServer)
  }

  @Test func ebookPendingWriteDoesNotProtectAudioPosition() {
    let policy = ProgressMergePolicy()
    let current = current(
      currentTime: 120,
      ebookProgress: 0.4,
      serverUpdatedAt: Date(timeIntervalSince1970: 1_000),
      hasUnacknowledgedEbookOperation: true
    )
    let incoming = serverPull(
      currentTime: 240, ebookProgress: 0.8, isFinished: true,
      serverUpdatedAt: Date(timeIntervalSince1970: 2_000))

    let result = policy.resolveComposite(current: current, incoming: incoming)

    #expect(result.audioPosition == .applyServer)
    #expect(result.ebookPosition == .keepLocal)
    #expect(result.sharedFinish == .applyServer)
  }

  @Test func audioPendingWriteDoesNotProtectEbookPosition() {
    let policy = ProgressMergePolicy()
    let current = current(
      currentTime: 120,
      ebookProgress: 0.4,
      serverUpdatedAt: Date(timeIntervalSince1970: 1_000),
      hasUnacknowledgedAudioOperation: true
    )
    let incoming = serverPull(
      currentTime: 240, ebookProgress: 0.8, serverUpdatedAt: Date(timeIntervalSince1970: 2_000))

    let result = policy.resolveComposite(current: current, incoming: incoming)

    #expect(result.audioPosition == .keepLocal)
    #expect(result.ebookPosition == .applyServer)
  }

  @Test func finishedFlagIsNeverInferredFromEbookProgressOne() {
    let policy = ProgressMergePolicy()
    let current = current(
      ebookProgress: 0.8, isFinished: false, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    let incoming = serverPull(
      ebookProgress: 1, isFinished: false, serverUpdatedAt: Date(timeIntervalSince1970: 2_000))

    let result = policy.resolveComposite(current: current, incoming: incoming)

    #expect(result.ebookPosition == .applyServer)
    #expect(result.sharedFinish == .applyServer)
    #expect(incoming.isFinished == false)
  }

  @Test func finishFlipAndLosingPulledEbookPositionResolveOnTheirOwnMerits() {
    let policy = ProgressMergePolicy()
    let current = current(
      ebookProgress: 0.8, isFinished: false, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    let incoming = serverPull(
      ebookProgress: 0.005, isFinished: true, serverUpdatedAt: Date(timeIntervalSince1970: 2_000))

    let result = policy.resolveComposite(current: current, incoming: incoming)

    #expect(result.ebookPosition == .needsResolution)
    #expect(result.sharedFinish == .applyServer)
  }

  // MARK: - Reset evidence (ADR 0011)

  @Test func ebookResetEvidenceAppliesAZeroWithNoServerTimestamp() {
    let policy = ProgressMergePolicy()
    let current = current(ebookProgress: 0.4, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    let incoming = serverPull(
      ebookProgress: 0, serverUpdatedAt: nil, signalsExplicitResetOrUnfinished: true)

    #expect(policy.resolveEbook(current: current, incoming: incoming) == .applyServer)
  }

  @Test func ebookResetEvidenceNeverOutranksAnUnacknowledgedEbookWrite() {
    let policy = ProgressMergePolicy()
    let current = current(
      ebookProgress: 0.4, serverUpdatedAt: Date(timeIntervalSince1970: 1_000),
      hasUnacknowledgedEbookOperation: true)
    let incoming = serverPull(
      ebookProgress: 0, serverUpdatedAt: nil, signalsExplicitResetOrUnfinished: true)

    #expect(policy.resolveEbook(current: current, incoming: incoming) == .keepLocal)
  }

  @Test func ebookZeroOnTheSameRowStillNeedsResolutionWithoutEvidence() {
    let policy = ProgressMergePolicy()
    let current = current(ebookProgress: 0.4, serverUpdatedAt: Date(timeIntervalSince1970: 1_000))
    let incoming = serverPull(ebookProgress: 0, serverUpdatedAt: Date(timeIntervalSince1970: 2_000))

    #expect(policy.resolveEbook(current: current, incoming: incoming) == .needsResolution)
  }
}
