import ABSApi
import Foundation
import Observation
import PlayerCore
import WatchPlayback
import WatchProtocol

/// What each `WatchPlaybackMachine` effect does. Every asynchronous step keeps its own `attempt`
/// wrapper, so a request that makes the attempt stale cancels the step while it runs, and a step
/// never hands an effect back for the caller to run outside that wrapper.
extension WatchPlaybackController {
  func runCloseRow(ending: Bool, finished: Bool, uploadAfter: Bool) async {
    if await closeLocalProgress(ending: ending, finished: finished), uploadAfter { requestUpload() }
  }

  func runStopTicker() {
    offlineTimer?.cancel()
    offlineTimer = nil
    // A checkpoint counts continuous play, so a pause ends the count.
    _ = model.offlineSync.checkpointDue(playing: false)
  }

  func runAskPeer(selection: WatchSelection, id: Attempt) async {
    await attempt(id) {
      let position = await askPhoneToPause(starting: selection)
      await complete(.peerAnswered(id, position: position))
    }
  }

  func runPrepare(selection: WatchSelection, handoffPosition: Double?, id: Attempt) async {
    await attempt(id) {
      do {
        try await prepare(selection, handoffPosition: handoffPosition)
        await complete(.prepared(id))
      } catch {
        await complete(.failed(id, WatchPlaybackFailure(error)))
      }
    }
  }

  func runCatchUp(selection: WatchSelection, id: Attempt) async {
    await attempt(id) {
      do {
        try await catchUpToSharedProgress(selection, id)
        await reopenRow()
        await complete(.caughtUp(id))
      } catch {
        await failedMoving(id, error)
      }
    }
  }

  func runRenew(selection: WatchSelection, id: Attempt) async {
    await attempt(id) {
      do {
        guard let coordinator else { throw WatchLibraryError.notAuthenticated }
        // The machine bounds renewals; the coordinator loads the renewed files itself.
        _ = try await coordinator.renewIndependent(
          selection: selection, position: audio.position, rate: audio.selectedRate)
        await reopenRow()
        await complete(.renewed(id))
      } catch {
        await complete(.failed(id, WatchPlaybackFailure(error)))
      }
    }
  }

  func runReopenRow(id: Attempt) async {
    await attempt(id) {
      await reopenRow()
      await complete(.reopened(id))
    }
  }

  func runPlayAudio(id: Attempt) async {
    await attempt(id) {
      do {
        guard let coordinator else { throw WatchLibraryError.notAuthenticated }
        try await coordinator.play()
        await complete(.audioStarted(id))
      } catch {
        await complete(.failed(id, WatchPlaybackFailure(error)))
      }
    }
  }

  func runSeek(target: Double, id: Attempt) async {
    await attempt(id) {
      do {
        guard let coordinator else { throw WatchLibraryError.notAuthenticated }
        try await coordinator.seek(to: target)
        await complete(.seekFinished(id))
      } catch {
        await failedMoving(id, error)
      }
    }
  }

  func runSendToPhone(selection: WatchSelection, id: Attempt) async {
    await attempt(id) {
      let outcome: WatchPlaybackMachine.ContinueOutcome =
        switch await companion.send(selection: selection, action: .play, value: audio.position) {
        case .sent: .accepted
        case .phoneUnavailable: .phoneUnavailable
        default: .unreachable
        }
      await complete(.continueAnswered(id, outcome))
    }
  }

  func runGrowRow(duration: Double) async {
    do { try await localProgress?.grow(to: duration) } catch {
      WatchDiagnostics.record(.progressPersistenceFailed)
    }
  }
}
