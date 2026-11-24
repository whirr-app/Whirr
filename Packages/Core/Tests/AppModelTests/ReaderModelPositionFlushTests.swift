import Foundation
import Persistence
import PlayerCore
import ReaderCore
import SyncEngine
import Synchronization
import TestSupport
import Testing

@testable import AppModel

extension ReaderModelTests {
  // MARK: - Position persistence and flush

  @Test("close flushes one pending position and scene background does not duplicate it")
  func closeFlushesExactlyOnceAcrossLifecycle() async {
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess()
    let lifecycle = FakeAppLifecycle()
    let renderer = FakeEPUBRendering()
    let model = makeModel(
      stateReading: stateReading, progress: progress, renderer: renderer, lifecycle: lifecycle)
    await open(model, stateReading: stateReading)
    renderer.emit(position(total: 0.2, href: "chapter-1"))
    await waitUntil { model.currentPosition != nil }

    lifecycle.simulateBackground()
    await waitUntil { await progress.writtenPositions.count == 1 }
    await model.close()

    #expect(await progress.writtenPositions.count == 1)
  }

  @Test("a failed reader-position write is retried on the next background flush")
  func failedPositionWriteIsRetriedOnNextBackgroundFlush() async {
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess(writeFailuresRemaining: 1)
    let lifecycle = FakeAppLifecycle()
    let renderer = FakeEPUBRendering()
    let model = makeModel(
      stateReading: stateReading, progress: progress, renderer: renderer, lifecycle: lifecycle)
    await open(model, stateReading: stateReading)

    let reported = position(total: 0.2, href: "chapter-1")
    renderer.emit(reported)
    await waitUntil { model.currentPosition == reported }

    lifecycle.simulateBackground()
    #expect(await waitUntil { await progress.writeAttemptCount == 1 })
    #expect(await progress.writtenPositions.isEmpty)

    lifecycle.simulateBackground()
    #expect(await waitUntil { await progress.writtenPositions == [reported] })
    #expect(await progress.writeAttemptCount == 2)

    await model.close()
  }

  @Test("background flushes the position, then waits for one sync, inside one background task")
  func backgroundFlushesThenSyncsUnderOneBackgroundTask() async {
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess(gateSync: true)
    let lifecycle = FakeAppLifecycle()
    let renderer = FakeEPUBRendering()
    let model = makeModel(
      stateReading: stateReading, progress: progress, renderer: renderer, lifecycle: lifecycle)
    await open(model, stateReading: stateReading)
    renderer.emit(position(total: 0.2, href: "chapter-1"))
    await waitUntil { model.currentPosition != nil }

    lifecycle.simulateBackground()
    #expect(await waitUntil { await progress.syncRequestCount == 1 })
    #expect(await progress.events == ["write", "sync"])
    #expect(lifecycle.backgroundTaskBeginCount == 1)
    #expect(lifecycle.activeBackgroundTaskCount == 1)

    await progress.releaseSync()
    await lifecycle.waitForBackgroundTasks { begun, ended in begun == 1 && ended == 1 }
    #expect(await progress.syncWasCancelled == false)
    await model.close()
  }

  @Test("background-task expiry cancels the sync and still ends the task once")
  func backgroundTaskExpiryCancelsTheSync() async {
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess(gateSync: true)
    let lifecycle = FakeAppLifecycle()
    let model = makeModel(stateReading: stateReading, progress: progress, lifecycle: lifecycle)
    await open(model, stateReading: stateReading)

    lifecycle.simulateBackground()
    #expect(await waitUntil { await progress.syncRequestCount == 1 })
    lifecycle.simulateBackgroundTaskExpiration()
    await progress.releaseSync()

    await lifecycle.waitForBackgroundTasks { begun, ended in begun == 1 && ended == 1 }
    #expect(await progress.syncWasCancelled)
    #expect(lifecycle.backgroundTaskEndCount == 1)
    await model.close()
  }

  @Test("a reader that never opened neither begins a background task nor requests a sync")
  func neverOpenedReaderDoesNothingOnBackground() async {
    let lifecycle = FakeAppLifecycle()
    let openedStateReading = TestReaderStateReading()
    let openedProgress = TestReaderProgressAccess()
    let opened = makeModel(
      stateReading: openedStateReading, progress: openedProgress, lifecycle: lifecycle)
    await open(opened, stateReading: openedStateReading)
    let idleProgress = TestReaderProgressAccess()
    let idle = makeModel(progress: idleProgress, lifecycle: lifecycle)
    await waitUntil { lifecycle.lifecycleSubscriberCount == 2 }

    lifecycle.simulateBackground()
    await lifecycle.waitForBackgroundTasks { begun, ended in begun == 1 && ended == 1 }
    #expect(await openedProgress.syncRequestCount == 1)
    await awaitQuiescence("idle reader stays idle") {
      "\(lifecycle.backgroundTaskBeginCount)-\(await idleProgress.syncRequestCount)"
    }
    #expect(lifecycle.backgroundTaskBeginCount == 1)
    #expect(await idleProgress.syncRequestCount == 0)
    await opened.close()
    _ = idle
  }

  @Test("deinit flushes a pending position once")
  func deinitFlushesExactlyOnce() async {
    let progress = TestReaderProgressAccess()
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering()
    var model: ReaderModel? = makeModel(
      stateReading: stateReading, progress: progress, renderer: renderer)
    await open(model!, stateReading: stateReading)
    renderer.emit(position(total: 0.2, href: "chapter-1"))
    await waitUntil { model?.currentPosition != nil }
    model = nil
    await waitUntil { await progress.writtenPositions.count == 1 }
    #expect(await progress.writtenPositions.count == 1)
  }
}
