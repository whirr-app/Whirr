import Testing

@testable import ABSApi

@Suite("Server compatibility")
struct ServerCompatibilityTests {
  @Test("accepts the minimum version and newer versions")
  func acceptsMinimumAndNewerVersions() throws {
    #expect(try ABSServerCompatibilityGate.validate(serverVersion: "2.35.1") == ABSServerVersion(2, 35, 1))
    #expect(try ABSServerCompatibilityGate.validate(serverVersion: "2.36.0") == ABSServerVersion(2, 36, 0))
    #expect(try ABSServerCompatibilityGate.validate(serverVersion: "3.0.0") == ABSServerVersion(3, 0, 0))
  }

  @Test("rejects older and unparseable versions with an actionable error")
  func rejectsOlderAndUnparseableVersions() {
    for rawVersion in ["2.35.0", "2.34.99", "", "unknown", "2.35"] {
      do {
        _ = try ABSServerCompatibilityGate.validate(serverVersion: rawVersion)
        Issue.record("Expected version \(rawVersion) to be rejected")
      } catch let error as APIError {
        #expect(
          {
            if case .incompatibleServer = error { return true }
            return false
          }())
        #expect(error.description.contains("2.35.1"))
        #expect(error.description.lowercased().contains("upgrade"))
      } catch {
        Issue.record("Unexpected error type for version \(rawVersion): \(error)")
      }
    }
  }
}
