import Foundation

public struct ABSServerVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init(_ major: Int, _ minor: Int, _ patch: Int) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  public init?(rawValue: String) {
    let components = rawValue.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3,
      components.allSatisfy({ $0.isEmpty == false && $0.allSatisfy(\Character.isNumber) }),
      let major = Int(components[0]),
      let minor = Int(components[1]),
      let patch = Int(components[2])
    else {
      return nil
    }

    self.init(major, minor, patch)
  }

  public static func < (lhs: ABSServerVersion, rhs: ABSServerVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }

  public var description: String {
    "\(major).\(minor).\(patch)"
  }
}

public enum ABSServerCompatibilityGate {
  public static let minimumVersion = ABSServerVersion(2, 35, 1)

  @discardableResult
  public static func validate(serverVersion: String) throws -> ABSServerVersion {
    guard let version = ABSServerVersion(rawValue: serverVersion), version >= minimumVersion else {
      throw APIError.incompatibleServer(
        required: minimumVersion,
        detected: ABSServerVersion(rawValue: serverVersion)
      )
    }
    return version
  }
}
