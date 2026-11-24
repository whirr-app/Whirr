import AppModel
import Foundation
import UniformTypeIdentifiers

nonisolated enum OPMLFileSupport {
  /// System-declared XML plus the system's filename-extension match. No exported/imported custom
  /// type or project/Info.plist declaration is required by this list.
  static var allowedContentTypes: [UTType] {
    var types: [UTType] = [.xml]
    if let opml = UTType(filenameExtension: "opml"), types.contains(opml) == false {
      types.append(opml)
    }
    return types
  }

  static func read(_ url: URL) throws -> Data {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile != false,
      (values.fileSize ?? 0) <= PodcastSubscriptionOPMLModel.maximumImportBytes
    else { throw OPMLFileError.invalidFile }
    return try Data(contentsOf: url, options: .mappedIfSafe)
  }
}

private enum OPMLFileError: Error {
  case invalidFile
}
