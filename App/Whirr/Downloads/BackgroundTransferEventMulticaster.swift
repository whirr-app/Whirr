import ABSApi
import CoreSupport
import Foundation
import SyncEngine

/// Fan-out for `BackgroundTransferEvent`s: `DownloadCoordinator` is rebuilt per `AppEnvironment`
/// but the adapter is a process singleton, so without this a second `DownloadCoordinator.make`
/// would race the first for elements off the one stream.
typealias BackgroundTransferEventMulticaster = AsyncEventMulticaster<BackgroundTransferEvent>

/// The `BackgroundTransferring` conformance `AppEnvironment` composes every `DownloadCoordinator`
/// around. Intents forward to the shared `BackgroundDownloadHardware.adapter`; `events` hands back
/// an independent multicast subscription (see `BackgroundTransferEventMulticaster`).
struct MulticastBackgroundTransferring: BackgroundTransferring {
  var events: AsyncStream<BackgroundTransferEvent> {
    BackgroundDownloadHardware.transferEventMulticaster.subscribe()
  }

  func enqueue(_ request: AuthorizedTransferRequest, destination: DownloadDestinationToken) async {
    await BackgroundDownloadHardware.adapter.enqueue(request, destination: destination)
  }

  func pause(identity: TransferIdentity) async {
    await BackgroundDownloadHardware.adapter.pause(identity: identity)
  }

  func resume(identity: TransferIdentity) async {
    await BackgroundDownloadHardware.adapter.resume(identity: identity)
  }

  func cancel(identity: TransferIdentity) async {
    await BackgroundDownloadHardware.adapter.cancel(identity: identity)
  }

  func currentTasks() async -> [BackgroundTransferSnapshot] {
    await BackgroundDownloadHardware.adapter.currentTasks()
  }

  func undeliveredFinishes() async -> Set<TransferIdentity> {
    await BackgroundDownloadHardware.adapter.undeliveredFinishes()
  }

  func acknowledgeFinish(identity: TransferIdentity) async {
    await BackgroundDownloadHardware.adapter.acknowledgeFinish(identity: identity)
  }
}
