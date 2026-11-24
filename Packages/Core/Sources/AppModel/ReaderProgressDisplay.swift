import Foundation

public struct ReaderProgressDisplay: Sendable, Equatable {
  public let text: String
  public let pageText: String?
  public let percentText: String
  public let percentage: Double
  public let chapterTitle: String?
  /// Whether this is the first page of `chapterTitle`'s chapter, where the book sets its own
  /// heading and a running header would only repeat it.
  public let isChapterOpening: Bool
  public let page: Int?
  public let pageCount: Int?
  public let chapterTimeRemainingText: String?
  public let bookTimeRemainingText: String?

  public init(
    text: String,
    pageText: String?,
    percentText: String,
    percentage: Double,
    chapterTitle: String?,
    isChapterOpening: Bool = false,
    page: Int?,
    pageCount: Int?,
    chapterTimeRemainingText: String? = nil,
    bookTimeRemainingText: String? = nil
  ) {
    self.text = text
    self.pageText = pageText
    self.percentText = percentText
    self.percentage = percentage
    self.chapterTitle = chapterTitle
    self.isChapterOpening = isChapterOpening
    self.page = page
    self.pageCount = pageCount
    self.chapterTimeRemainingText = chapterTimeRemainingText
    self.bookTimeRemainingText = bookTimeRemainingText
  }
}
