import Foundation
import TestSupport

@testable import Whirr

/// Test double for `BackgroundDownloadSessionProviding`; tests never build a real
/// background-configured `URLSession`. Records every task it is asked to mint and can be
/// pre-loaded with tasks a reattach should discover. `nonisolated` over `Locked` boxes, not the
/// target's default MainActor isolation: the adapter reaches its session factory from nonisolated
/// code, which a MainActor-isolated conformance would not satisfy.
nonisolated final class FakeBackgroundDownloadSessionProviding: BackgroundDownloadSessionProviding,
  @unchecked Sendable
{
  private let madeRequestsBox = Locked<[URLRequest]>([])
  private let madeTasksBox = Locked<[FakeBackgroundDownloadTaskHandle]>([])
  private let pendingTasksBox = Locked<[BackgroundDownloadTaskHandle]>([])
  private let invalidateAndCancelBox = Locked(0)

  var madeRequests: [URLRequest] { madeRequestsBox.value }
  var madeTasks: [FakeBackgroundDownloadTaskHandle] { madeTasksBox.value }
  var invalidateAndCancelCallCount: Int { invalidateAndCancelBox.value }

  var pendingTasksToReturn: [BackgroundDownloadTaskHandle] {
    get { pendingTasksBox.value }
    set { pendingTasksBox.withValue { $0 = newValue } }
  }

  func makeDownloadTask(for request: URLRequest) -> BackgroundDownloadTaskHandle {
    madeRequestsBox.withValue { $0.append(request) }
    let task = FakeBackgroundDownloadTaskHandle()
    madeTasksBox.withValue { $0.append(task) }
    return task
  }

  func pendingTasks(completion: @escaping @Sendable ([BackgroundDownloadTaskHandle]) -> Void) {
    completion(pendingTasksToReturn)
  }

  func invalidateAndCancel() {
    invalidateAndCancelBox.withValue { $0 += 1 }
  }
}
