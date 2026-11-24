import ABSApi
import Foundation

public enum ServerPodcastPathGenerationField: String, Sendable, Equatable {
  case folderPath
  case title
  case segment
  case childPath
}

public enum ServerPodcastPathGenerationReason: String, Sendable, Equatable {
  case missing
  case notAbsolute
  case invalidEncoding
  case traversal
  case containsControlCharacter
  case tooLong
  case noUsableSegment
  case notContained
}

/// A privacy-safe refusal. It identifies only the field and reason; no title, server path, or URL
/// is retained for diagnostics.
public enum ServerPodcastPathGenerationError: Error, Sendable, Equatable, CustomStringConvertible {
  case refused(
    field: ServerPodcastPathGenerationField,
    reason: ServerPodcastPathGenerationReason)

  public var description: String {
    switch self {
    case .refused(let field, let reason):
      return "Server podcast path refused (\(field.rawValue): \(reason.rawValue))."
    }
  }
}

/// Pure, bounded path generation for a server-declared folder. The result is the filesystem path
/// sent in the JSON create body, so server-declared spaces and Unicode remain literal values;
/// only unsafe native title characters are replaced before the path is validated locally.
public enum ServerPodcastPathGeneration {
  public static let maximumPathBytes = PodcastWriteBounds.maximumStringBytes
  /// 255 bytes is a conservative filesystem-component ceiling, tighter than
  /// the 16 KiB whole-path bound used by ABSApi's podcast write validation.
  public static let maximumSegmentBytes = 255
  public static let fallbackSegment = "Podcast"

  public static func generate(
    folderFullPath: String,
    nativeFeedTitle: String
  ) -> Result<String, ServerPodcastPathGenerationError> {
    let normalizedFolder: String
    switch normalizedFolderPath(folderFullPath) {
    case .success(let path):
      normalizedFolder = path
    case .failure(let error):
      return .failure(error)
    }

    let separatorBytes = normalizedFolder == "/" ? 0 : 1
    let availableSegmentBytes = maximumPathBytes - normalizedFolder.utf8.count - separatorBytes
    guard availableSegmentBytes > 0 else {
      return .failure(refusal(.childPath, .tooLong))
    }
    let segmentLimit = min(maximumSegmentBytes, availableSegmentBytes)

    var segment = boundedSegment(
      sanitizedTitle(nativeFeedTitle), maximumBytes: segmentLimit)
    if segment.isEmpty {
      segment = boundedSegment(fallbackSegment, maximumBytes: segmentLimit)
    }
    guard segment.isEmpty == false else {
      return .failure(refusal(.segment, .noUsableSegment))
    }

    let childPath = normalizedFolder == "/" ? "/" + segment : normalizedFolder + "/" + segment
    guard childPath.utf8.count <= maximumPathBytes,
      isUsableAbsolutePath(childPath),
      isContained(childPath, within: normalizedFolder)
    else {
      return .failure(refusal(.childPath, .notContained))
    }
    return .success(childPath)
  }

  private static func normalizedFolderPath(
    _ value: String
  ) -> Result<String, ServerPodcastPathGenerationError> {
    guard value.isEmpty == false else { return .failure(refusal(.folderPath, .missing)) }
    guard value.hasPrefix("/") else { return .failure(refusal(.folderPath, .notAbsolute)) }
    guard value.utf8.count <= maximumPathBytes else {
      return .failure(refusal(.folderPath, .tooLong))
    }
    guard value.contains("?") == false, value.contains("#") == false,
      value.unicodeScalars.contains(where: isControl) == false
    else {
      return .failure(refusal(.folderPath, .containsControlCharacter))
    }

    let components = value.split(separator: "/", omittingEmptySubsequences: true)
    var normalizedComponents = [String]()
    normalizedComponents.reserveCapacity(components.count)
    for rawComponent in components {
      guard let decoded = String(rawComponent).removingPercentEncoding else {
        return .failure(refusal(.folderPath, .invalidEncoding))
      }
      guard decoded != ".", decoded != "..", decoded.contains("/") == false,
        decoded.unicodeScalars.contains(where: isControl) == false
      else {
        return .failure(refusal(.folderPath, .traversal))
      }
      // Keep the server's declared spelling. Percent escapes are checked by the same local
      // predicate as ABSApi, but decoding/re-encoding here could change a literal folder name.
      normalizedComponents.append(String(rawComponent))
    }

    let normalized =
      normalizedComponents.isEmpty
      ? "/"
      : "/" + normalizedComponents.joined(separator: "/")
    guard normalized.utf8.count <= maximumPathBytes else {
      return .failure(refusal(.folderPath, .tooLong))
    }
    guard isUsableAbsolutePath(normalized) else {
      return .failure(refusal(.folderPath, .invalidEncoding))
    }
    return .success(normalized)
  }

  private static func sanitizedTitle(_ title: String) -> String {
    var characters = [Character]()
    var pendingWhitespace = false

    for character in title {
      let scalars = character.unicodeScalars
      if scalars.allSatisfy({ $0.properties.isWhitespace }) {
        if characters.isEmpty == false {
          pendingWhitespace = true
        }
        continue
      }

      if pendingWhitespace {
        characters.append(" ")
        pendingWhitespace = false
      }

      if scalars.contains(where: isControlOrReserved) {
        characters.append("-")
      } else {
        characters.append(character)
      }
    }

    var result = trimEdgeDotsAndWhitespace(String(characters))
    if isReservedWindowsDeviceName(result) {
      result = "_" + result
    }
    return result
  }

  private static func boundedSegment(_ value: String, maximumBytes: Int) -> String {
    guard maximumBytes > 0 else { return "" }
    var prefix = ""
    for character in value {
      guard prefix.utf8.count + character.utf8.count <= maximumBytes else {
        break
      }
      prefix.append(contentsOf: String(character))
    }
    prefix = trimEdgeDotsAndWhitespace(prefix)
    if isReservedWindowsDeviceName(prefix) {
      prefix = "_" + prefix
      prefix = boundedSegmentWithoutReservedRewrite(prefix, maximumBytes: maximumBytes)
    }
    return trimEdgeDotsAndWhitespace(prefix)
  }

  private static func boundedSegmentWithoutReservedRewrite(
    _ value: String,
    maximumBytes: Int
  ) -> String {
    var prefix = ""
    for character in value {
      guard prefix.utf8.count + character.utf8.count <= maximumBytes else {
        break
      }
      prefix.append(contentsOf: String(character))
    }
    return trimEdgeDotsAndWhitespace(prefix)
  }

  private static func trimEdgeDotsAndWhitespace(_ value: String) -> String {
    var characters = Array(value)
    while let first = characters.first,
      first == "." || first.unicodeScalars.allSatisfy({ $0.properties.isWhitespace })
    {
      characters.removeFirst()
    }
    while let last = characters.last,
      last == "." || last.unicodeScalars.allSatisfy({ $0.properties.isWhitespace })
    {
      characters.removeLast()
    }
    return String(characters)
  }

  private static func isReservedWindowsDeviceName(_ value: String) -> Bool {
    let base =
      value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map(String.init)?.uppercased() ?? ""
    switch base {
    case "CON", "PRN", "AUX", "NUL":
      return true
    default:
      if base.count == 4,
        base.hasPrefix("COM") || base.hasPrefix("LPT"),
        let digit = base.last,
        ("1"..."9").contains(String(digit))
      {
        return true
      }
      return false
    }
  }

  private static func isControlOrReserved(_ scalar: Unicode.Scalar) -> Bool {
    if isControl(scalar) { return true }
    switch scalar.value {
    case 35, 37, 42, 47, 58, 60, 62, 63, 92, 124:
      return true
    case 34:
      return true
    default:
      return false
    }
  }

  private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
    let category = scalar.properties.generalCategory
    return category == .control || category == .lineSeparator || category == .paragraphSeparator
  }

  /// This mirrors ABSApi's `isUsableAbsolutePath` check and additionally rejects controls that
  /// would be unsafe for URLComponents. Keeping the check here makes path validation local; Whirr
  /// never probes the server filesystem.
  private static func isUsableAbsolutePath(_ value: String) -> Bool {
    guard value.isEmpty == false,
      value.utf8.count <= maximumPathBytes,
      value.hasPrefix("/"),
      value.contains("?") == false,
      value.contains("#") == false,
      value.contains("\0") == false,
      value.unicodeScalars.contains(where: isControl) == false
    else { return false }

    return value.split(separator: "/", omittingEmptySubsequences: true).allSatisfy { component in
      guard let decoded = component.removingPercentEncoding else { return false }
      return decoded != "." && decoded != ".." && decoded.contains("/") == false
    }
  }

  private static func isContained(_ childPath: String, within folderPath: String) -> Bool {
    guard childPath != folderPath else { return false }
    if folderPath == "/" {
      return childPath.hasPrefix("/") && childPath.dropFirst().isEmpty == false
    }
    return childPath.hasPrefix(folderPath + "/")
  }

  private static func refusal(
    _ field: ServerPodcastPathGenerationField,
    _ reason: ServerPodcastPathGenerationReason
  ) -> ServerPodcastPathGenerationError {
    .refused(field: field, reason: reason)
  }
}
