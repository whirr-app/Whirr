import Foundation
import Persistence

/// `PodcastCloudInstallationAnchor`'s fake: an in-memory stand-in for the `ThisDeviceOnly`
/// Keychain item that anchors installation identity. The real
/// `KeychainPodcastCloudInstallationAnchor` is covered in the App target.
///
/// Read and write failure are separately controllable because the resolution table treats them
/// differently: an unreadable anchor is a refusal that persists nothing, while a failed write is
/// an ordinary persistence fault that must surface.
public final class FakePodcastCloudInstallationAnchor: PodcastCloudInstallationAnchor, @unchecked Sendable {
  public enum Failure: Error, Sendable, Equatable {
    case unreadable
    case unwritable
  }

  private struct State {
    var stored: UUID?
    var readsFail = false
    var writesFail = false
    var reads = 0
    var writes = 0
  }

  private let state = Locked(State())

  public init(stored: UUID? = nil, readsFail: Bool = false, writesFail: Bool = false) {
    state.withValue {
      $0.stored = stored
      $0.readsFail = readsFail
      $0.writesFail = writesFail
    }
  }

  public var value: UUID? { state.value.stored }
  public var reads: Int { state.value.reads }
  public var writes: Int { state.value.writes }

  public func setReadsFail(_ failing: Bool) { state.withValue { $0.readsFail = failing } }
  public func setWritesFail(_ failing: Bool) { state.withValue { $0.writesFail = failing } }

  /// The restore signature: the database crossed devices and the anchor did not.
  public func clear() { state.withValue { $0.stored = nil } }

  public func read() throws -> UUID? {
    let outcome: Result<UUID?, Error> = state.withValue { current in
      current.reads += 1
      if current.readsFail { return .failure(Failure.unreadable) }
      return .success(current.stored)
    }
    return try outcome.get()
  }

  public func write(_ uuid: UUID) throws {
    let outcome: Result<Void, Error> = state.withValue { current in
      current.writes += 1
      if current.writesFail { return .failure(Failure.unwritable) }
      current.stored = uuid
      return .success(())
    }
    try outcome.get()
  }
}
