import Foundation
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@Suite(.timeLimit(.minutes(1))) struct PodcastCloudBackgroundTimeTests {
  @Test func aSendRunsInsideOneAllowance() async {
    let lifecycle = FakeAppLifecycle()
    let ran = Locked(false)

    await PodcastCloudLifecycleBackgroundTime(lifecycle: lifecycle).run { ran.withValue { $0 = true } }

    #expect(ran.value)
    #expect(await lifecycle.waitForBackgroundTasks { begun, ended in begun == 1 && ended == 1 } == .observed)
  }

  /// iOS terminates an app that holds an allowance past its expiry, so the allowance ends as the
  /// handler runs, not once the cancelled send has wound down, and it is not ended twice.
  @Test func expiryCancelsTheSendAndEndsTheAllowanceAtOnce() async {
    let lifecycle = FakeAppLifecycle()
    let cancelled = Locked(false)
    let release = AsyncStream<Void>.makeStream()

    let running = Task {
      await PodcastCloudLifecycleBackgroundTime(lifecycle: lifecycle).run {
        await withTaskCancellationHandler {
          for await _ in release.stream {}
        } onCancel: {
          cancelled.withValue { $0 = true }
        }
      }
    }
    #expect(await lifecycle.waitForBackgroundTasks { begun, _ in begun == 1 } == .observed)

    lifecycle.simulateBackgroundTaskExpiration()
    #expect(cancelled.value)
    #expect(await lifecycle.waitForBackgroundTasks { _, ended in ended == 1 } == .observed)

    release.continuation.finish()
    await running.value
    #expect(await lifecycle.waitForBackgroundTasks { begun, ended in begun == 1 && ended == 1 } == .observed)
  }
}
