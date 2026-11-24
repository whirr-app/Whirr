import Foundation
import Testing

@testable import Whirr

/// A composition that outlives one signed-in account must build its client with the account-bound
/// factory: removal drops the graph from the cache but cannot stop whatever retains it, and an
/// unbound retained client would authenticate as the next account against the old server. The
/// app's other clients serve pre-authentication work with no account to bind. A new unbound site
/// has to be added to that list by hand.
@Suite("ABSClient factory use")
struct ABSClientFactoryScanTests {
  /// Every `ABSClient.production` call in these files must name an account.
  static let accountLifetimeSources: Set<String> = [
    "PodcastBackgroundRefresh+SharedServices.swift",
    "AppEnvironment+SetupComposition.swift",
  ]

  /// Endpoint probes and candidates, and the Watch setup transfer over its own in-memory store.
  static let preAuthenticationSources: Set<String> = [
    "AppEnvironment+EndpointComposition.swift",
    "EndpointSwitchCoordinator.swift",
    "WatchSetupLogin.swift",
  ]

  @Test("the shared services and setup discovery build their client with the bound factory")
  func accountLifetimeCompositionsUseTheBoundFactory() throws {
    let calls = try Self.productionCalls()
    for name in Self.accountLifetimeSources.sorted() {
      let fileCalls = calls.filter { $0.file == name }
      #expect(fileCalls.isEmpty == false, "\(name) builds no ABSClient; this scan no longer covers it")
      for call in fileCalls {
        #expect(Self.namesAnAccount(call.arguments), "\(name) builds an unbound ABSClient")
      }
    }
  }

  @Test("only pre-authentication sites build an unbound client")
  func unboundClientsAreConfinedToPreAuthenticationSites() throws {
    let unbound = Set(
      try Self.productionCalls().filter { Self.namesAnAccount($0.arguments) == false }.map(\.file))

    #expect(unbound.subtracting(Self.preAuthenticationSources).sorted() == [])
  }

  private struct Call {
    let file: String
    let arguments: String
  }

  private static func productionCalls() throws -> [Call] {
    try ViewSourceScan.appSources().flatMap { source -> [Call] in
      let text = try ViewSourceScan.executableText(of: source)
      return argumentLists(after: "ABSClient.production(", in: text).map {
        Call(file: source.lastPathComponent, arguments: $0)
      }
    }
  }

  /// The text of every call's argument list, up to its balancing parenthesis.
  private static func argumentLists(after marker: String, in text: String) -> [String] {
    var lists: [String] = []
    var searchStart = text.startIndex
    while let range = text.range(of: marker, range: searchStart..<text.endIndex) {
      var depth = 1
      var index = range.upperBound
      while index < text.endIndex, depth > 0 {
        if text[index] == "(" { depth += 1 }
        if text[index] == ")" { depth -= 1 }
        index = text.index(after: index)
      }
      lists.append(String(text[range.upperBound..<index]))
      searchStart = index
    }
    return lists
  }

  /// True when `account:` is an argument label whose value is not the literal `nil`. A label such
  /// as `tokenAccount:` does not count.
  private static func namesAnAccount(_ arguments: String) -> Bool {
    var searchStart = arguments.startIndex
    while let range = arguments.range(of: "account:", range: searchStart..<arguments.endIndex) {
      searchStart = range.upperBound
      if range.lowerBound > arguments.startIndex,
        arguments[arguments.index(before: range.lowerBound)].isLetter
      {
        continue
      }
      let value = arguments[range.upperBound...]
        .prefix { $0 != "," && $0 != ")" && $0 != "\n" }
        .trimmingCharacters(in: .whitespaces)
      if value.isEmpty == false, value != "nil" { return true }
    }
    return false
  }
}
