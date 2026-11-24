import Foundation

/// Canonicalizes the optional ebook format/extension values used by Persistence and its callers.
/// A leading dot is presentation syntax, not part of the format identity.
public enum EbookFormatNormalizer {
  public static func normalize(_ raw: String?) -> String? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let withoutLeadingDots = trimmed.drop(while: { $0 == "." })
    guard withoutLeadingDots.isEmpty == false else { return nil }
    return withoutLeadingDots.lowercased()
  }
}
