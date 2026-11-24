import ReaderCore

@MainActor
extension ReaderModel {
  func makeProgressDisplay() -> ReaderProgressDisplay {
    makeProgressDisplay(for: currentPosition)
  }

  func makeProgressDisplay(for currentPosition: ReadingPosition?) -> ReaderProgressDisplay {
    guard let currentPosition else {
      return ReaderProgressDisplay(
        text: ReaderCopy.progressPercent(0),
        pageText: nil,
        percentText: ReaderCopy.progressPercent(0),
        percentage: 0,
        chapterTitle: nil,
        page: nil,
        pageCount: nil,
        chapterTimeRemainingText: nil,
        bookTimeRemainingText: nil)
    }
    let percentText = ReaderCopy.progressPercent(currentPosition.ebookProgress)
    guard let positions = publication?.positions else {
      return ReaderProgressDisplay(
        text: percentText,
        pageText: nil,
        percentText: percentText,
        percentage: currentPosition.ebookProgress,
        chapterTitle: nil,
        page: nil,
        pageCount: nil,
        chapterTimeRemainingText: nil,
        bookTimeRemainingText: nil)
    }
    let toc = publication?.toc ?? []
    // An entry's href keeps the navigation document's fragment while a position's is the bare
    // resource, so an href match is rare; the entry's start position is what places every later
    // page of the chapter inside it.
    let chapterIndex = toc.lastIndex(where: { entry in
      if entry.href == currentPosition.href { return true }
      guard let start = entry.position, let current = currentPosition.position else { return false }
      return start <= current
    })
    let chapter = chapterIndex.map { toc[$0].title }
    let isChapterOpening =
      chapterIndex.map {
        toc[$0].position != nil && toc[$0].position == currentPosition.position
      } ?? false
    let chapterEndProgression = chapterIndex.flatMap {
      ReadingTime.chapterEndProgression(in: toc, currentIndex: $0)
    }
    let estimate = ReadingTime.estimate(
      totalProgression: currentPosition.totalProgression,
      chapterEndProgression: chapterEndProgression,
      positionCount: positions.count)
    let chapterTimeRemainingText = estimate.chapterSeconds.flatMap {
      ReaderCopy.chapterTimeRemaining(seconds: $0)
    }
    let bookTimeRemainingText = estimate.bookSeconds.flatMap {
      ReaderCopy.bookTimeRemaining(seconds: $0)
    }
    // Readium positions are already one-based; the rail must not shift them or it disagrees with
    // the chapter list's page numbers.
    let page = currentPosition.position
    let pageCount = positions.count
    let pageText = ReaderCopy.progressPageText(page: page, pageCount: pageCount)
    return ReaderProgressDisplay(
      text: ReaderCopy.progressText(
        progress: currentPosition.ebookProgress,
        chapterTitle: chapter,
        page: page,
        pageCount: pageCount,
        bookTimeRemainingText: bookTimeRemainingText),
      pageText: pageText,
      percentText: percentText,
      percentage: currentPosition.ebookProgress,
      chapterTitle: chapter,
      isChapterOpening: isChapterOpening,
      page: page,
      pageCount: pageCount,
      chapterTimeRemainingText: chapterTimeRemainingText,
      bookTimeRemainingText: bookTimeRemainingText)
  }
}
