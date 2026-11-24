import Foundation

/// Shared metadata predicates. Callers retain their domain errors and optional-value policy.
enum WatchDownloadValidation {
  // The planner historically permits opaque file:-prefixed IDs; the store rejects them.
  static func validIdentifier(_ value: String, rejectsFileScheme: Bool = false) -> Bool {
    if rejectsFileScheme && value.lowercased().hasPrefix("file:") { return false }
    guard value.isEmpty == false, value.utf8.count <= 512,
      value.contains("://") == false, value.hasPrefix("/") == false, value.contains("/") == false,
      value.contains("\\") == false, value.contains("..") == false,
      value.contains("?") == false, value.contains("#") == false
    else { return false }
    return value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
  }

  static func validSize<T: BinaryInteger>(_ value: T) -> Bool { value > 0 }

  static func validDuration(_ value: Double) -> Bool { value.isFinite && value > 0 }
}
