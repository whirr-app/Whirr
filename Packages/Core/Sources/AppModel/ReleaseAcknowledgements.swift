import Foundation

/// The licence and attribution information shown by the app for production packages.
///
/// `attribution` is the one-line credit; `licenseText` is the verbatim notice from the package's
/// own LICENSE file, bundled as a resource. Both ship: MIT and BSD-3-Clause require the full
/// permission notice to accompany a distributed binary, which a credit line does not satisfy.
public struct ReleaseAcknowledgement: Equatable, Hashable, Identifiable, Sendable {
  public let packageIdentity: String
  public let displayName: String
  public let version: String
  public let licenseIdentifier: String
  public let attribution: String
  public let repositoryURL: String

  public var id: String { packageIdentity }

  /// The package's verbatim LICENSE file, or `nil` if the resource is missing. The release audit
  /// treats that as a failure rather than letting the screen render an empty section.
  public var licenseText: String? {
    ReleaseAcknowledgements.licenseText(forIdentity: packageIdentity)
  }

  public init(
    packageIdentity: String,
    displayName: String,
    version: String,
    licenseIdentifier: String,
    attribution: String,
    repositoryURL: String
  ) {
    self.packageIdentity = packageIdentity
    self.displayName = displayName
    self.version = version
    self.licenseIdentifier = licenseIdentifier
    self.attribution = attribution
    self.repositoryURL = repositoryURL
  }
}

/// The reviewed production dependency acknowledgements for the current release graph.
public enum ReleaseAcknowledgements {
  private static let licensesDirectory = "Licenses"

  static func licenseText(forIdentity identity: String) -> String? {
    guard
      let url = Bundle.module.url(
        forResource: identity, withExtension: "txt", subdirectory: licensesDirectory)
    else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
  }

  /// Display order for the acknowledgements screen.
  public static var displayOrdered: [ReleaseAcknowledgement] {
    entries.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
  }

  /// Every licence resource bundled, so the audit can catch attribution left behind by a removed
  /// dependency as well as a package added without one.
  public static func bundledLicenceIdentities() -> Set<String>? {
    guard
      let urls = Bundle.module.urls(
        forResourcesWithExtension: "txt", subdirectory: licensesDirectory)
    else { return nil }
    return Set(urls.map { $0.deletingPathExtension().lastPathComponent })
  }

  public static let entries: [ReleaseAcknowledgement] = [
    ReleaseAcknowledgement(
      packageIdentity: "grdb.swift",
      displayName: "GRDB.swift",
      version: "7.11.1",
      licenseIdentifier: "MIT",
      attribution: "GRDB.swift — Copyright (C) 2015-2025 Gwendal Roué. Used under the MIT License.",
      repositoryURL: "https://github.com/groue/GRDB.swift"
    ),
    ReleaseAcknowledgement(
      packageIdentity: "swift-toolkit",
      displayName: "Readium Swift Toolkit",
      version: "3.11.0",
      licenseIdentifier: "BSD-3-Clause",
      attribution: "Readium Swift Toolkit — Copyright (c) 2017, Readium. Used under the BSD 3-Clause License.",
      repositoryURL: "https://github.com/readium/swift-toolkit"
    ),
    ReleaseAcknowledgement(
      packageIdentity: "cryptoswift",
      displayName: "CryptoSwift",
      version: "1.10.0",
      licenseIdentifier: "LicenseRef-CryptoSwift",
      attribution:
        "This product includes software developed by the \"Marcin Krzyzanowski\" (http://krzyzanowskim.com/).",
      repositoryURL: "https://github.com/krzyzanowskim/CryptoSwift"
    ),
    ReleaseAcknowledgement(
      packageIdentity: "differencekit",
      displayName: "DifferenceKit",
      version: "1.3.0",
      licenseIdentifier: "Apache-2.0",
      attribution: "DifferenceKit — Ryo Aoyama and contributors. Used under the Apache License 2.0.",
      repositoryURL: "https://github.com/ra1028/DifferenceKit"
    ),
    ReleaseAcknowledgement(
      packageIdentity: "fuzi",
      displayName: "Fuzi (Readium fork)",
      version: "4.0.0",
      licenseIdentifier: "MIT",
      attribution: "Fuzi — Copyright (c) 2015 Ce Zheng. Used under the MIT License.",
      repositoryURL: "https://github.com/readium/Fuzi"
    ),
    ReleaseAcknowledgement(
      packageIdentity: "gcdwebserver",
      displayName: "GCDWebServer",
      version: "4.0.1",
      licenseIdentifier: "BSD-3-Clause",
      attribution:
        "GCDWebServer — Copyright (c) 2012-2014, Pierre-Olivier Latour. Used under the BSD 3-Clause License.",
      repositoryURL: "https://github.com/readium/GCDWebServer"
    ),
    ReleaseAcknowledgement(
      packageIdentity: "sqlite.swift",
      displayName: "SQLite.swift",
      version: "0.16.0",
      licenseIdentifier: "MIT",
      attribution: "SQLite.swift — Copyright (c) 2014-2015 Stephen Celis. Used under the MIT License.",
      repositoryURL: "https://github.com/stephencelis/SQLite.swift"
    ),
    ReleaseAcknowledgement(
      packageIdentity: "swiftsoup",
      displayName: "SwiftSoup",
      version: "2.13.7",
      licenseIdentifier: "MIT",
      attribution:
        "SwiftSoup — Copyright (c) 2009-2025 Jonathan Hedley; Copyright (c) 2016-2025 Nabil Chatbi (Swift port). Used under the MIT License.",
      repositoryURL: "https://github.com/scinfu/SwiftSoup"
    ),
    ReleaseAcknowledgement(
      packageIdentity: "zip",
      displayName: "Zip",
      version: "2.1.2",
      licenseIdentifier: "MIT",
      attribution: "Zip — Copyright (c) 2015 Roy Marmelstein. Used under the MIT License.",
      repositoryURL: "https://github.com/marmelroy/Zip"
    ),
    ReleaseAcknowledgement(
      packageIdentity: "zipfoundation",
      displayName: "ZIPFoundation (Readium fork)",
      version: "3.0.1",
      licenseIdentifier: "MIT",
      attribution: "ZIPFoundation — Copyright (c) 2017-2024 Thomas Zoechling. Used under the MIT License.",
      repositoryURL: "https://github.com/readium/ZIPFoundation"
    ),
  ]
}
