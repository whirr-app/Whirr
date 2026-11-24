import ABSApi
import Foundation
import SyncEngine

/// `NativeEpisodeServerSaveItemDetailReading`'s fake. Read `n` (counting from 1) answers with
/// plan `n`, and the last plan repeats; a plan is the detail to return or the error to throw
/// (`CancellationError()` for a read that is cancelled). `stubBeforeReturn` runs first on every
/// read, which is where a test blocks a read, mutates state in the middle of one, or records a
/// decode drop into the diagnostics the caller passed.
public final class FakeNativeEpisodeServerSaveItemDetailReading:
  NativeEpisodeServerSaveItemDetailReading, @unchecked Sendable
{
  /// One read: which credential account it used, for which item, and whether the caller passed
  /// decode diagnostics.
  public struct Call: Sendable, Equatable {
    public let account: TokenAccount
    public let itemID: String
    public let hadDiagnostics: Bool

    public init(account: TokenAccount, itemID: String, hadDiagnostics: Bool) {
      self.account = account
      self.itemID = itemID
      self.hadDiagnostics = hadDiagnostics
    }
  }

  public typealias Plan = Result<ItemDetail, any Error>
  public typealias BeforeReturn =
    @Sendable (_ readNumber: Int, _ diagnostics: DecodeDiagnostics?) async -> Void

  private struct State {
    var plans: [Plan]
    var planIndex = 0
    var reads = 0
    var beforeReturn: BeforeReturn?
  }

  private let state: Locked<State>

  /// Every read, in order.
  public let recorder = CallRecorder<Call>(
    label: "FakeNativeEpisodeServerSaveItemDetailReading.fetchItemDetail")
  public var calls: [Call] { recorder.calls }
  public var callCount: Int { recorder.count }
  /// The credential account of every read, in order.
  public var recordedAccounts: [TokenAccount] { recorder.calls.map(\.account) }
  /// The reads that passed no decode diagnostics.
  public var callCountWithoutDiagnostics: Int {
    recorder.calls.filter { $0.hadDiagnostics == false }.count
  }

  /// - Parameter plans: at least one; the last repeats once the rest are used.
  public init(plans: [Plan]) {
    precondition(plans.isEmpty == false, "a fake item detail reader needs a plan")
    state = Locked(State(plans: plans))
  }

  public convenience init(_ detail: ItemDetail) {
    self.init(plans: [.success(detail)])
  }

  /// Replaces the plans and restarts them from the first one.
  public func stubPlans(_ plans: [Plan]) {
    precondition(plans.isEmpty == false, "a fake item detail reader needs a plan")
    state.withValue {
      $0.plans = plans
      $0.planIndex = 0
    }
  }

  /// Runs before every read answers; `nil` removes it.
  public func stubBeforeReturn(_ hook: BeforeReturn?) {
    state.withValue { $0.beforeReturn = hook }
  }

  public func fetchItemDetail(
    account: TokenAccount,
    itemID: String,
    diagnostics: DecodeDiagnostics?
  ) async throws -> ItemDetail {
    let number = state.withValue { state -> Int in
      state.reads += 1
      return state.reads
    }
    recorder.record(Call(account: account, itemID: itemID, hadDiagnostics: diagnostics != nil))
    if let hook = state.value.beforeReturn { await hook(number, diagnostics) }
    let plan = state.withValue { state -> Plan in
      let plan = state.plans[min(state.planIndex, state.plans.count - 1)]
      state.planIndex += 1
      return plan
    }
    return try plan.get()
  }
}
