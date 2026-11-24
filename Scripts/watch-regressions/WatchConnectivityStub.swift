// Host regression seam: the real Watch orchestration runs without paired-device hardware.
import Foundation

public enum WCSessionActivationState { case activated, notActivated }
public final class WCSession: @unchecked Sendable {
  public static let `default` = WCSession()
  public var activationState: WCSessionActivationState = .notActivated
  public private(set) var applicationContext: [String: Any] = [:]
  public func updateApplicationContext(_ context: [String: Any]) throws { applicationContext = context }
  public var outstandingUserInfoTransfers: [WCSessionUserInfoTransfer] = []
  @discardableResult
  public func transferUserInfo(_ userInfo: [String: Any] = [:]) -> WCSessionUserInfoTransfer {
    let transfer = WCSessionUserInfoTransfer(userInfo: userInfo)
    outstandingUserInfoTransfers.append(transfer)
    return transfer
  }
}
public final class WCSessionUserInfoTransfer: @unchecked Sendable {
  public let userInfo: [String: Any]
  init(userInfo: [String: Any]) { self.userInfo = userInfo }
  public func cancel() {}
}
