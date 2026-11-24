import Foundation

/// One admission rule shared byte-for-byte by ABS and RSS artwork transports.
public enum CoverImageAdmission {
  /// Full-size cover art is allowed up to 20 MiB: enough for high-resolution artwork while
  /// preventing an unexpectedly large image response from consuming the general API budget.
  public static let maximumResponseBytes = 20 * 1024 * 1024

  public static func admit(data: Data, contentType: String?) throws -> CoverImageResult {
    guard data.count <= maximumResponseBytes else { throw APIError.payloadTooLarge }
    guard let contentType,
      contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased().hasPrefix("image/")
    else { throw APIError.decoding }
    return CoverImageResult(data: data, contentType: contentType)
  }
}
