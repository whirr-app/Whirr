import Foundation

/// A PDF that accompanies an audiobook: maps, tables, figures the narrator refers to. It is
/// viewed, never read, so nothing here makes an item an ebook. `ino` is the same server-side
/// inode string `EbookFileInfo.ino` carries and addresses the file through the per-file download
/// route.
public struct SupplementFileInfo: Sendable, Equatable {
  public let ino: String
  public let filename: String?
  public let size: Int

  public init(ino: String, filename: String?, size: Int) {
    self.ino = ino
    self.filename = filename
    self.size = size
  }
}

extension BookMedia {
  /// One list from both wire shapes, primary first and deduplicated by `ino`:
  /// - `media.ebookFile`, when it is a PDF on an item that has audio (the item is then still an
  ///   audiobook, as `ItemMediaCategory.hasReadableEbook` admits only EPUB);
  /// - each item-root `libraryFiles[]` PDF that is not the primary ebook.
  ///
  /// `fileType` is not trusted alone and `isSupplementary` has only been observed as `null`, so
  /// the extension decides. An entry without a positive size is skipped, as in ebook download
  /// planning: a download cannot be validated against an unknown length.
  static func makeSupplements(
    primary: EbookFileDTO?, libraryFiles: [EbookFileDTO], hasAudio: Bool
  ) -> [SupplementFileInfo] {
    guard hasAudio else { return [] }
    var seen = Set<String>()
    var supplements: [SupplementFileInfo] = []
    for file in [primary].compactMap({ $0 }) + libraryFiles {
      guard let ino = file.ino,
        EbookFileInfo.normalizedExtension(file.ext) == "pdf",
        let size = file.size, size > 0,
        seen.insert(ino).inserted
      else { continue }
      supplements.append(SupplementFileInfo(ino: ino, filename: file.filename, size: size))
    }
    return supplements
  }
}
