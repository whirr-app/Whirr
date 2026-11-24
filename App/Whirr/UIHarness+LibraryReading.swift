#if DEBUG || PERF_INVESTIGATION
  import ABSApi
  import AppModel
  import DesignSystem
  import Foundation
  import MediaPlayer
  import Persistence
  import PlayerCore
  import ReaderCore
  import SwiftUI
  import SyncEngine
  import UIKit
  import os

  struct HarnessLibraryReading: LibraryReading {
    var itemCount: Int { Self.summaries.count }

    private static var summary: ItemSummary {
      ItemSummary(
        serverItemId: UIHarnessFixtures.itemID,
        mediaKind: "book",
        title: UIHarnessFixtures.title,
        author: UIHarnessFixtures.author,
        durationSeconds: UIHarnessFixtures.duration,
        category: ItemMediaCategory.derive(
          mediaKind: "book", numAudioFiles: UIHarnessFixtures.trackCount, ebookFormat: nil),
        hasReadableEbook: ItemMediaCategory.hasReadableEbook(ebookFormat: nil),
        // The hero's credit block is author over series over narrator, and the point of the
        // block is how those three read against each other. Without these the harness would
        // reserve two invisible rows and show a one-line ladder, which is not what is under review.
        seriesName: UIHarnessFixtures.seriesName,
        narratorName: UIHarnessFixtures.narratorName,
        expandedMetadataFetchedAt: .distantPast
      )
    }

    private static var mixedSummary: ItemSummary {
      ItemSummary(
        serverItemId: UIHarnessFixtures.mixedItemID,
        mediaKind: "book",
        title: UIHarnessFixtures.mixedTitle,
        author: UIHarnessFixtures.mixedAuthor,
        durationSeconds: UIHarnessFixtures.duration,
        category: UIHarnessFixtures.mixedCategory,
        hasReadableEbook: UIHarnessFixtures.mixedHasReadableEbook
      )
    }

    private static var shortSeriesSummary: ItemSummary {
      ItemSummary(
        serverItemId: UIHarnessFixtures.shortSeriesItemID,
        mediaKind: "book",
        title: UIHarnessFixtures.shortSeriesTitle,
        author: UIHarnessFixtures.shortSeriesAuthor,
        durationSeconds: UIHarnessFixtures.duration,
        category: ItemMediaCategory.derive(
          mediaKind: "book", numAudioFiles: UIHarnessFixtures.trackCount, ebookFormat: nil),
        hasReadableEbook: ItemMediaCategory.hasReadableEbook(ebookFormat: nil),
        seriesName: UIHarnessFixtures.shortSeriesName,
        narratorName: UIHarnessFixtures.shortSeriesNarrator,
        expandedMetadataFetchedAt: .distantPast
      )
    }

    private static var noSeriesSummary: ItemSummary {
      ItemSummary(
        serverItemId: UIHarnessFixtures.noSeriesItemID,
        mediaKind: "book",
        title: UIHarnessFixtures.noSeriesTitle,
        author: UIHarnessFixtures.noSeriesAuthor,
        durationSeconds: UIHarnessFixtures.duration,
        category: ItemMediaCategory.derive(
          mediaKind: "book", numAudioFiles: UIHarnessFixtures.trackCount, ebookFormat: nil),
        hasReadableEbook: ItemMediaCategory.hasReadableEbook(ebookFormat: nil),
        seriesName: nil,
        narratorName: UIHarnessFixtures.noSeriesNarrator,
        expandedMetadataFetchedAt: .distantPast
      )
    }

    private static var ebookSummary: ItemSummary {
      ItemSummary(
        serverItemId: UIHarnessFixtures.ebookItemID,
        mediaKind: "book",
        title: UIHarnessFixtures.ebookTitle,
        author: UIHarnessFixtures.ebookAuthor,
        durationSeconds: nil,
        category: UIHarnessFixtures.ebookCategory,
        hasReadableEbook: UIHarnessFixtures.ebookHasReadableEbook,
        seriesName: nil,
        narratorName: nil,
        expandedMetadataFetchedAt: .distantPast
      )
    }

    private static var summaries: [ItemSummary] {
      [summary, mixedSummary, shortSeriesSummary, noSeriesSummary, ebookSummary]
    }

    private static func summary(for itemID: String) -> ItemSummary? {
      summaries.first { $0.serverItemId == itemID }
    }

    func observeBrowseList(libraryId: String) -> AsyncStream<[ItemSummary]> {
      AsyncStream { $0.yield(Self.summaries) }
    }

    func observeBrowseList(category: ItemMediaCategory?) -> AsyncStream<[ItemSummary]> {
      let summaries = Self.summaries
      return AsyncStream {
        $0.yield(summaries.filter { category == nil || $0.category == category })
      }
    }

    /// The harness seeds no `download` or `mediaProgress` rows, so every fixture item is never
    /// started: it passes Unplayed and fails In Progress and Finished. Podcast shows drop out of
    /// every engaged playback state, as `ItemFilterPredicate.itemPlayback` drops them. The
    /// filters are applied rather than ignored so the harness cannot show a filtered list as if
    /// it were unfiltered.
    func observeBrowseList(filters: BrowseFilters) -> AsyncStream<LibraryBrowseSnapshot> {
      let summaries = Self.summaries
      let matches =
        filters.downloadedOnly == false
          && (filters.playback == .any || filters.playback == .unfinished)
        ? summaries.filter {
          (filters.categories?.contains($0.category) ?? true)
            && (filters.playback == .any || $0.category != .podcast)
        }
        : []
      return AsyncStream {
        $0.yield(LibraryBrowseSnapshot(items: matches, unfilteredItemCount: summaries.count))
      }
    }

    func observeSyncStatus(libraryId: String) -> AsyncStream<LibrarySyncStatus> {
      AsyncStream { $0.yield(LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: nil)) }
    }

    func observeAggregateSyncStatus() -> AsyncStream<LibrarySyncStatus> {
      AsyncStream { $0.yield(LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: nil)) }
    }

    func observeItemDetail(itemId: String) -> AsyncStream<ItemSummary?> {
      AsyncStream { $0.yield(Self.summary(for: itemId)) }
    }

    func observeItems(ids: [String]) -> AsyncStream<[ItemSummary]> {
      AsyncStream { $0.yield(Self.summaries.filter { ids.contains($0.serverItemId) }) }
    }

    func observeItemPlaybackStatuses() -> AsyncStream<[String: ItemPlaybackStatus]> {
      // FinishedStatusStore is built from this library fixture, while author destinations read
      // browse-fixture rows; publish the browse IDs here so their badges share one projection.
      AsyncStream { $0.yield(HarnessLibraryBrowseReading.playbackStatuses) }
    }
  }
#endif
