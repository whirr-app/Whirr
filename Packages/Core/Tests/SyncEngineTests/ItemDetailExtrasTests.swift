import Foundation
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Pure mapping tests for `ItemDetailExtras.makeChapters(from:duration:)`. No network or actor is
/// involved, as in `ProgressMergePolicyTests`.
@Suite struct ItemDetailExtrasTests {

  @Test("a chapter with a nil start is dropped; a mid-list nil end derives from the next chapter's start")
  func dropsNilStartAndDerivesMidListEndFromNextStart() {
    let chapters = [
      Chapter(id: 1, start: nil, end: 50, title: "No start, dropped"),
      Chapter(id: 2, start: 0, end: nil, title: "Chapter One"),
      Chapter(id: 3, start: 100, end: 200, title: "Chapter Two"),
    ]

    let result = ItemDetailExtras.makeChapters(from: chapters, duration: 500)

    #expect(
      result == [
        ItemChapterInfo(title: "Chapter One", start: 0, end: 100),
        ItemChapterInfo(title: "Chapter Two", start: 100, end: 200),
      ])
  }

  @Test("the last chapter's nil end derives from the item's overall duration when present")
  func lastChapterNilEndDerivesFromDuration() {
    let chapters = [
      Chapter(id: 1, start: 0, end: 100, title: "Chapter One"),
      Chapter(id: 2, start: 100, end: nil, title: "Chapter Two"),
    ]

    let result = ItemDetailExtras.makeChapters(from: chapters, duration: 400)

    #expect(
      result == [
        ItemChapterInfo(title: "Chapter One", start: 0, end: 100),
        ItemChapterInfo(title: "Chapter Two", start: 100, end: 400),
      ])
  }

  @Test("the last chapter's nil end falls back to its own start when no duration is available")
  func lastChapterNilEndFallsBackToStartWithoutDuration() {
    let chapters = [
      Chapter(id: 1, start: 50, end: nil, title: "Only Chapter")
    ]

    let result = ItemDetailExtras.makeChapters(from: chapters, duration: nil)

    #expect(result == [ItemChapterInfo(title: "Only Chapter", start: 50, end: 50)])
  }

  @Test("an empty chapter list maps to an empty result")
  func emptyChaptersMapToEmptyResult() {
    #expect(ItemDetailExtras.makeChapters(from: [], duration: 500) == [])
  }
}
