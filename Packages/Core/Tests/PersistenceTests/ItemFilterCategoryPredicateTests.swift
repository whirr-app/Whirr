import GRDB
import Testing

@testable import Persistence

@Suite struct ItemFilterCategoryPredicateTests {

  @Test("the ebook filter keeps documents but rejects PDF sidecars on audiobooks")
  func ebookFilterMatchesReadableMixedAndStandaloneDocumentsOnly() async throws {
    let database = try AppDatabase.inMemory()
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)

    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "mixed",
        mediaKind: "book", title: "Mixed", sortTitle: "mixed", numAudioFiles: 2,
        ebookFormat: "epub"))
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "mixed-pdf",
        mediaKind: "book", title: "Mixed PDF", sortTitle: "mixed-pdf", numAudioFiles: 2,
        ebookFormat: "pdf"))
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "mixed-normalized-epub",
        mediaKind: "book", title: "Mixed EPUB", sortTitle: "mixed-normalized-epub",
        numAudioFiles: 2, ebookFormat: " .EPUB "))
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "pure-ebook",
        mediaKind: "book", title: "Pure Ebook", sortTitle: "pure-ebook", numAudioFiles: 0,
        ebookFormat: "epub"))
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "standalone-pdf",
        mediaKind: "book", title: "Standalone PDF", sortTitle: "standalone-pdf",
        numAudioFiles: 0, ebookFormat: "pdf"))
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "pure-audiobook",
        mediaKind: "book", title: "Pure Audiobook", sortTitle: "pure-audiobook", numAudioFiles: 2))
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "podcast",
        mediaKind: "podcast", title: "Podcast", sortTitle: "podcast"))
    _ = try itemDAO.upsert(
      ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "podcast-with-ebook",
        mediaKind: "podcast", title: "Podcast With Ebook", sortTitle: "podcast-with-ebook",
        numAudioFiles: 2, ebookFormat: "epub"))

    let ids = try database.read { db in
      try ItemRecord.fetchAll(
        db,
        sql: """
          SELECT item.* FROM item
          WHERE (\(ItemFilterCategoryPredicate.sql(.ebook)))
          ORDER BY item.serverItemId
          """,
        arguments: []
      )
      .map(\.serverItemId)
    }

    #expect(ids == ["mixed", "mixed-normalized-epub", "pure-ebook", "standalone-pdf"])
  }

  @Test("Swift membership mirrors the supported mixed-format policy")
  func swiftMembershipMatrix() {
    struct Cell {
      let primary: ItemMediaCategory
      let hasReadableEbook: Bool
      let expected: Set<ItemMediaCategory>
    }
    let cells = [
      Cell(primary: .audiobook, hasReadableEbook: false, expected: [.audiobook]),
      Cell(primary: .audiobook, hasReadableEbook: true, expected: [.audiobook, .ebook]),
      Cell(primary: .ebook, hasReadableEbook: false, expected: [.ebook]),
      Cell(primary: .ebook, hasReadableEbook: true, expected: [.ebook]),
      Cell(primary: .podcast, hasReadableEbook: false, expected: [.podcast]),
      Cell(primary: .podcast, hasReadableEbook: true, expected: [.podcast]),
    ]

    for cell in cells {
      for category in ItemMediaCategory.allCases {
        #expect(
          ItemFilterCategoryPredicate.matches(
            category,
            primaryCategory: cell.primary,
            hasReadableEbook: cell.hasReadableEbook)
            == cell.expected.contains(category))
      }
    }
  }

  @Test("SQL and Swift category membership agree across the media signal matrix")
  func sqlAndSwiftMembershipAgree() async throws {
    let database = try AppDatabase.inMemory()
    let itemDAO = ItemDAO(database: database)
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    let matrix: [(id: String, mediaKind: String, audio: Int?, format: String?)] = [
      ("audio", "book", 2, nil),
      ("audio-epub", "book", 2, "epub"),
      ("audio-pdf", "book", 2, "pdf"),
      ("audio-normalized-epub", "book", 2, " .EPUB "),
      ("epub", "book", 0, "epub"),
      ("pdf", "book", 0, "pdf"),
      ("empty", "book", 0, "  "),
      ("whitespace", "book", 0, "\t\n"),
      ("podcast", "podcast", nil, nil),
      ("podcast-epub", "podcast", 2, "epub"),
    ]
    for row in matrix {
      _ = try itemDAO.upsert(
        ItemRecord(
          accountId: accountId, libraryId: libraryId, serverItemId: row.id,
          mediaKind: row.mediaKind, title: row.id, sortTitle: row.id,
          numAudioFiles: row.audio, ebookFormat: row.format))
    }

    for category in ItemMediaCategory.allCases {
      let sqlIDs = try database.read { db in
        try Set(
          String.fetchAll(
            db,
            sql: "SELECT item.serverItemId FROM item WHERE \(ItemFilterCategoryPredicate.sql(category))"))
      }
      let swiftIDs = Set(
        matrix.filter { row in
          let primary = ItemMediaCategory.derive(
            mediaKind: row.mediaKind, numAudioFiles: row.audio, ebookFormat: row.format)
          return ItemFilterCategoryPredicate.matches(
            category,
            primaryCategory: primary,
            hasReadableEbook: ItemMediaCategory.hasReadableEbook(ebookFormat: row.format))
        }.map(\.id))
      #expect(sqlIDs == swiftIDs, "membership drift for \(category.rawValue)")
    }
  }

  @Test("non-ebook filter categories delegate to the identity predicate")
  func nonEbookCategoriesRemainByteIdentical() {
    let categories: [ItemMediaCategory?] = [nil, .audiobook, .podcast]
    for category in categories {
      #expect(
        ItemFilterCategoryPredicate.sql(category) == ItemCategoryPredicate.sql(category))
    }
  }

  private static func seedAccountAndLibrary(_ database: AppDatabase) async throws -> (Int64, Int64) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "client", serverBaseURL: "https://example.com", serverUserId: "user",
        serverVersion: "2.35.1")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib1", mediaType: "book", name: "Library")
      try library.insert(db)
      return (account.id!, library.id!)
    }
  }
}
