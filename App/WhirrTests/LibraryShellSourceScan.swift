import Foundation
import Testing

extension ViewSourceScan {
  /// Shell contracts cover the state owner and all same-type composition extensions.
  static func libraryShellText() throws -> String {
    let urls = try sources()
    return try [
      "LibraryShellView.swift", "LibraryShellView+Tabs.swift",
      "LibraryShellView+Destinations.swift", "LibraryShellView+Presentation.swift",
      "LibraryShellView+PresentationHost.swift",
    ].map { name in
      let url = try #require(urls.first { $0.lastPathComponent == name })
      return try executableText(of: url)
    }.joined(separator: "\n")
  }

  /// The Downloads screen is one `DownloadsView` across four files. Contracts about "the screen"
  /// mean all of them, the same way `libraryShellText()` means the whole shell.
  static func downloadsScreenText() throws -> String {
    let urls = try sources()
    return try [
      "DownloadsView.swift", "DownloadsView+List.swift",
      "DownloadsView+Selection.swift", "DownloadsView+Storage.swift",
    ].map { name in
      let url = try #require(urls.first { $0.lastPathComponent == name })
      return try executableText(of: url)
    }.joined(separator: "\n")
  }
}
