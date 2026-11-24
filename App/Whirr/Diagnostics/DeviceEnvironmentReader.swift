import AppModel
import Foundation
import UIKit

/// The install facts a bug report needs, read live so the file always describes the moment it was
/// made. Nothing identifying: the hardware identifier names a product line, and
/// `UIDevice.current.name` is never read.
nonisolated struct DeviceEnvironmentReader: ProblemReportEnvironmentReading, Sendable {
  let serverVersion: @Sendable () -> String?

  init(serverVersion: @escaping @Sendable () -> String? = { nil }) {
    self.serverVersion = serverVersion
  }

  func readEnvironment() async -> ProblemReportEnvironment {
    let (systemName, systemVersion) = await MainActor.run {
      (UIDevice.current.systemName, UIDevice.current.systemVersion)
    }
    let info = Bundle.main.infoDictionary
    return ProblemReportEnvironment(
      appVersion: info?["CFBundleShortVersionString"] as? String,
      buildNumber: info?["CFBundleVersion"] as? String,
      systemName: systemName,
      systemVersion: systemVersion,
      deviceModel: Self.modelIdentifier(),
      localeIdentifier: Locale.current.identifier,
      isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
      freeDiskBytes: Self.freeDiskBytes(),
      serverVersion: serverVersion())
  }

  /// `iPhone18,1` on hardware. The simulator reports its host architecture, so the simulated
  /// model comes from the environment variable it sets instead.
  static func modelIdentifier(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String {
    if let simulated = environment["SIMULATOR_MODEL_IDENTIFIER"], simulated.isEmpty == false {
      return simulated
    }
    var systemInfo = utsname()
    uname(&systemInfo)
    let machine = withUnsafeBytes(of: &systemInfo.machine) { buffer -> String in
      let bytes = buffer.prefix { $0 != 0 }
      return String(decoding: bytes, as: UTF8.self)
    }
    return machine.isEmpty ? "unknown" : machine
  }

  private static func freeDiskBytes() -> Int64? {
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }
}
