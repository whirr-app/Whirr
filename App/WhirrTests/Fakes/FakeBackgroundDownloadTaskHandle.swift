import Foundation
import TestSupport

@testable import Whirr

/// Test double for `BackgroundDownloadTaskHandle`. No real `URLSessionDownloadTask` is involved:
/// tests drive it directly. `nonisolated` over `Locked` boxes: the protocol declares every member
/// `nonisolated`, so the conformance cannot take the target's default MainActor isolation.
/// `@unchecked`: the adapter and the test drive one handle from one test task, never concurrently.
nonisolated final class FakeBackgroundDownloadTaskHandle: BackgroundDownloadTaskHandle,
  @unchecked Sendable
{
  private let taskDescriptionBox: Locked<String?>
  private let expectedBytesBox = Locked<Int64>(0)
  private let resumeBox = Locked(0)
  private let suspendBox = Locked(0)
  private let cancelBox = Locked(0)

  var taskDescription: String? {
    get { taskDescriptionBox.value }
    set { taskDescriptionBox.withValue { $0 = newValue } }
  }

  var countOfBytesClientExpectsToReceive: Int64 {
    get { expectedBytesBox.value }
    set { expectedBytesBox.withValue { $0 = newValue } }
  }

  var resumeCallCount: Int { resumeBox.value }
  var suspendCallCount: Int { suspendBox.value }
  var cancelCallCount: Int { cancelBox.value }

  init(taskDescription: String? = nil) {
    taskDescriptionBox = Locked(taskDescription)
  }

  func resume() {
    resumeBox.withValue { $0 += 1 }
  }

  func suspend() {
    suspendBox.withValue { $0 += 1 }
  }

  func cancel() {
    cancelBox.withValue { $0 += 1 }
  }
}
