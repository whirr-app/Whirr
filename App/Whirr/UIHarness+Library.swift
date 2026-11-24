#if DEBUG || PERF_INVESTIGATION
  import AppModel
  import DesignSystem
  import Persistence
  import SwiftUI
  import SyncEngine

  /// `WHIRR_UI_HARNESS_SCREEN=library`: the real `LibraryBrowseRootView` over a fake
  /// `LibraryReading`/`SyncCoordinating` pair. It exists for the Library list's page background:
  /// this is the only screen whose plain `List` carries pinned section headers and the A-Z
  /// section index, which decide where the top edge treatment stops. None of that is visible on
  /// `home`, `podcast-show`, or `search`.
  ///
  /// Scenario fake: the catalogue is synced account data, so the browse read is a fixture of 102
  /// titles rather than an empty database. The model, list and navigation are the shipping ones.
  extension UIHarnessRootView {
    var libraryBody: some View {
      HarnessLibraryScreen(session: session)
    }
  }

  /// Its own view rather than a computed property, as `HarnessSearchScreen` is: the browse mode
  /// and the sync-indicator controller are `@State`, which an extension cannot add.
  struct HarnessLibraryScreen: View {
    let session: UIHarnessSession
    /// Which tab the shell opens on. The Library list is the subject, so it is the default; the
    /// filler tabs only give the real tab bar its production shape.
    var initialTab: HarnessLibraryTab = .library

    /// The List's own model, built from the harness reads the way the shell builds it from
    /// `LibraryReading`/`SyncCoordinating`. `LibraryBrowseModel.init` subscribes to its own filtered
    /// browse observation, so the screen holds it here rather than rebuilding it per body.
    @State private var browseModel = LibraryBrowseModel(
      library: HarnessLibraryBrowseReading(), sync: HarnessSyncCoordinating())

    @State private var selectedTab: HarnessLibraryTab?
    /// Counts Library reselects the way `LibraryShellView.tabSelectionBinding` does, so reselect
    /// drives the root's scroll-to-top path rather than only the tab bar's own.
    @State private var libraryReselects = 0
    @State private var mode = LibraryBrowsePresentation.Mode.titles
    @State private var selectionEntry = LibrarySelectionEntry()
    @State private var authorSeriesDestination: HarnessAuthorSeriesDestination?

    var body: some View {
      // The production tab shape, not a bare `NavigationStack`: the tab bar and its bottom
      // accessory own the scroll view's bottom inset, and the top edge effect resolves against
      // the same scroll view. Dropping either would measure a different view tree.
      TabView(selection: tabSelection) {
        Tab("Home", systemImage: "house", value: HarnessLibraryTab.home) {
          Text("Harness filler tab")
            .foregroundStyle(WhirrColorToken.textSecondary.color)
        }
        Tab("Library", systemImage: "books.vertical", value: HarnessLibraryTab.library) {
          NavigationStack {
            LibraryBrowseRootView(
              mode: $mode,
              selectionEntry: selectionEntry,
              browseModel: browseModel,
              authorSeriesReading: HarnessAuthorSeriesReading(),
              libraryCollections: .unavailable,
              coverClient: session.coverClient,
              downloadStatus: session.downloadStatus,
              finishedStatus: session.finishedStatus,
              actions: session.actions,
              playback: session.playback,
              onSelectTitle: { _ in },
              onSelectEntity: { entity in
                switch entity.kind {
                case .author:
                  authorSeriesDestination = .author(
                    id: entity.entityID, libraryID: entity.libraryID)
                case .series:
                  authorSeriesDestination = .series(
                    id: entity.entityID, libraryID: entity.libraryID)
                case .book, .podcast, .episode:
                  break
                }
              },
              onPresentReader: { _, _, _ in },
              onSearch: { _ in },
              onSelectCollection: { _ in },
              scrollToTopRequest: libraryReselects
            )
            // Mirrors `LibraryShellView.rootToolbar(for:)`'s persistent trailing items on the
            // Library section (Select, filter, Settings) in the same order. The glass group above
            // the list is part of what the top edge effect resolves against.
            .toolbar {
              if LibraryShellPresentation.showsSelectionEntry(in: mode) {
                ToolbarItem(placement: .topBarTrailing) {
                  SelectionEntryButton(
                    screen: .libraryTitles, isEnabled: selectionEntry.hasSelectableRows
                  ) {
                    selectionEntry.editMode = .active
                  }
                }
              }
              ToolbarItem(placement: .topBarTrailing) {
                BrowseFilterMenu(model: browseModel)
              }
              ToolbarItem(placement: .topBarTrailing) {
                Button {
                } label: {
                  Label("Settings", systemImage: LibraryShellPresentation.settingsSystemImage)
                }
              }
            }
            .navigationDestination(item: $authorSeriesDestination) { destination in
              AuthorSeriesView(
                makeModel: {
                  AuthorSeriesModel(
                    target: destination.target,
                    reading: HarnessAuthorSeriesReading(),
                    library: HarnessLibraryBrowseReading())
                },
                coverClient: session.coverClient,
                paletteService: session.paletteService,
                finishedStatus: session.finishedStatus,
                playback: session.playback,
                actions: session.actions,
                onSelectItem: { _ in },
                onPresentReader: { _, _, _ in },
                onSearch: { _ in })
            }
          }
        }
        Tab(
          "Podcasts", systemImage: "antenna.radiowaves.left.and.right",
          value: HarnessLibraryTab.podcasts
        ) {
          Text("Harness filler tab")
            .foregroundStyle(WhirrColorToken.textSecondary.color)
        }
      }
      .modifier(HarnessBottomAccessory())
      .preferredColorScheme(UIHarnessRootView.harnessColorScheme)
    }

    /// `initialTab` until the first selection, then whatever the user picked. `@State` cannot be
    /// seeded from a property without an initialiser this view otherwise does not need.
    private var tabSelection: Binding<HarnessLibraryTab> {
      Binding(
        get: { selectedTab ?? initialTab },
        set: { selection in
          if selection == .library, (selectedTab ?? initialTab) == .library {
            libraryReselects += 1
          }
          selectedTab = selection
        })
    }
  }

  enum HarnessLibraryTab: Hashable {
    case home
    case library
    case podcasts
  }

  /// A multi-letter title list, unlike `HarnessLibraryReading`'s single fixture: one item yields
  /// one section header, and a single header cannot show where a pinned one lands once the rows
  /// above it scroll away.
  struct HarnessLibraryBrowseReading: LibraryReading {
    /// The one fixture served with no usable duration, so a tile's unknown-duration fallback (a
    /// status badge where a progress bar cannot be computed) has somewhere to render.
    static let unknownDurationItemID = "harness-lib-36"

    /// Seeded once and read twice: this stream feeds the destination's progress bars, and
    /// `playbackStatuses` below derives the badges from the same rows. Two hand-maintained fixtures
    /// would drift into a tile drawing a full bar beside a "not started" badge.
    static let playbackProgress: [String: ItemPlaybackProgress] = [
      "harness-lib-6": ItemPlaybackProgress(
        currentTime: 0, ebookProgress: 0.15, isFinished: false),
      "harness-lib-30": ItemPlaybackProgress(currentTime: 33_264, isFinished: false),
      "harness-lib-31": ItemPlaybackProgress(
        currentTime: 0, ebookProgress: 1, isFinished: true),
      "harness-lib-36": ItemPlaybackProgress(currentTime: 1_200, isFinished: false),
    ]

    static let playbackStatuses: [String: ItemPlaybackStatus] = playbackProgress.reduce(
      into: [String: ItemPlaybackStatus]()
    ) { statuses, entry in
      statuses[entry.key] = entry.value.isFinished ? .finished : .inProgress
    }

    /// The count is load-bearing: 102 gives each media slice 51 books, one beyond the 50-row
    /// page; below 51 in a slice the loading-more path is unreachable.
    private static let prolificTitles:
      [(id: String, title: String, author: String, series: String?, category: ItemMediaCategory)] = (1...102).map {
        index in
        let category: ItemMediaCategory = index.isMultiple(of: 2) ? .ebook : .audiobook
        let cycle = (index - 1) / 8
        let position = (index - 1) % 8
        let series =
          position.isMultiple(of: 2)
          ? "The Long Orbit \(cycle + 1) #\(position / 2 + 1)"
          : nil
        return (
          id: "harness-prolific-\(index)",
          title: "The Long Orbit \(index)",
          author: "Mira Voss",
          series: series,
          category: category
        )
      }

    /// `series` and `category` are needed: the Authors and Series modes derive their rows from
    /// these items (`LibraryEntityGrouping`), so without them the counts, media-kind badges and
    /// borrowed series covers would never render.
    static let titles: [(id: String, title: String, author: String, series: String?, category: ItemMediaCategory)] =
      [
        ("harness-lib-1", "Abaddon's Gate", "James S. A. Corey", "The Expanse #3", .audiobook),
        ("harness-lib-2", "Absolution", "Patrick Flanery", nil, .ebook),
        ("harness-lib-3", "Acceptance", "Jeff VanderMeer", "Southern Reach #3", .audiobook),
        ("harness-lib-4", "Ace, King, Knave", "Maria McCann", nil, .ebook),
        ("harness-lib-5", "The Adventures of Amina Al-Sirafi", "S. A. Chakraborty", nil, .audiobook),
        ("harness-lib-6", "Annihilation", "Jeff VanderMeer", "Southern Reach #1", .ebook),
        ("harness-lib-7", "Authority", "Jeff VanderMeer", "Southern Reach #2", .audiobook),
        ("harness-lib-8", "Blindsight", "Peter Watts", nil, .audiobook),
        ("harness-lib-9", "The Bone Clocks", "David Mitchell", nil, .audiobook),
        ("harness-lib-10", "Caliban's War", "James S. A. Corey", "The Expanse #2", .audiobook),
        ("harness-lib-11", "Children of Time", "Adrian Tchaikovsky", "Children of Time #1", .audiobook),
        ("harness-lib-12", "Cryptonomicon", "Neal Stephenson", nil, .ebook),
        ("harness-lib-13", "The Dispossessed", "Ursula K. Le Guin", nil, .audiobook),
        ("harness-lib-14", "Embassytown", "China Miéville", nil, .audiobook),
        ("harness-lib-15", "A Field Guide to Getting Lost", "Rebecca Solnit", nil, .ebook),
        ("harness-lib-16", "Gnomon", "Nick Harkaway", nil, .audiobook),
        ("harness-lib-17", "House of Leaves", "Mark Z. Danielewski", nil, .ebook),
        ("harness-lib-18", "The Left Hand of Darkness", "Ursula K. Le Guin", nil, .ebook),
        ("harness-lib-19", "Leviathan Wakes", "James S. A. Corey", "The Expanse #1", .audiobook),
        ("harness-lib-20", "Piranesi", "Susanna Clarke", nil, .audiobook),
        ("harness-lib-21", "Project Hail Mary", "Andy Weir", nil, .audiobook),
        ("harness-lib-22", "Station Eleven", "Emily St. John Mandel", nil, .audiobook),
        ("harness-lib-23", "Tress of the Emerald Sea", "Brandon Sanderson", nil, .ebook),
        ("harness-lib-24", "The Wind-Up Bird Chronicle", "Haruki Murakami", nil, .audiobook),
        ("harness-lib-25", "Children of Time", "Adrian Tchaikovsky", "Children of Time #1", .ebook),
        ("harness-lib-26", "Shards of Earth", "Adrian Tchaikovsky", "The Final Architecture #1", .audiobook),
        ("harness-lib-27", "Eyes of the Void", "Adrian Tchaikovsky", "The Final Architecture #2.5", .audiobook),
        (
          "harness-lib-28",
          "The Long Way to a Small, Angry Planet and Other Interstellar Travel Notes",
          "Adrian Tchaikovsky",
          "The Final Architecture #3",
          .ebook
        ),
        ("harness-lib-29", "Service Model", "Adrian Tchaikovsky", nil, .audiobook),
        // Anthony Doerr is the three-kind case: a named series, a cross-format editions card,
        // and two loose books that each draw as their own row.
        ("harness-lib-30", "Cloud Cuckoo Land", "Anthony Doerr", nil, .audiobook),
        ("harness-lib-31", "Cloud Cuckoo Land", "Anthony Doerr", nil, .ebook),
        ("harness-lib-32", "All the Light We Cannot See", "Anthony Doerr", nil, .audiobook),
        ("harness-lib-33", "Memory Wall", "Anthony Doerr", nil, .ebook),
        (
          "harness-lib-34", "The Lighthouse Letters", "Anthony Doerr", "The Lighthouse Letters #1",
          .audiobook
        ),
        ("harness-lib-35", "The Long Crossing", "Anthony Doerr", "The Lighthouse Letters #2", .ebook),
        // A bare series keeps the sequence nil and its empty author absent from the destination
        // summary.
        ("harness-lib-36", "A Book Without an Author", "", "The Unnamed Shelf", .audiobook),
        // N. K. Jemisin's nine ebook-only books keep the portrait-only shelf visibly varied.
        (
          "harness-lib-37", "The Hundred Thousand Kingdoms", "N. K. Jemisin",
          "The Inheritance Trilogy #1",
          .ebook
        ),
        (
          "harness-lib-38", "The Broken Kingdoms", "N. K. Jemisin", "The Inheritance Trilogy #2",
          .ebook
        ),
        (
          "harness-lib-39", "The Kingdom of Gods", "N. K. Jemisin", "The Inheritance Trilogy #3",
          .ebook
        ),
        ("harness-lib-40", "The City We Became", "N. K. Jemisin", "The Great Cities #1", .ebook),
        ("harness-lib-41", "The World We Make", "N. K. Jemisin", "The Great Cities #2", .ebook),
        ("harness-lib-42", "How Long 'til Black Future Month?", "N. K. Jemisin", nil, .ebook),
        ("harness-lib-43", "The Awakened Kingdom", "N. K. Jemisin", nil, .ebook),
        ("harness-lib-44", "The Killing Moon", "N. K. Jemisin", "The Dreamblood Duology", .ebook),
        ("harness-lib-45", "The Shadowed Sun", "N. K. Jemisin", nil, .ebook),
      ] + prolificTitles + scaledTitles

    /// Volume for a browse-scroll measurement, honouring `WHIRR_UI_HARNESS_SCALE`. Empty at the
    /// default scale of 1, leaving the 102-item slices and 45 hand-written titles untouched. Titles
    /// spread across the alphabet and cycle leading articles and diacritics: the cost measured is
    /// `LibraryBrowsePresentation.sectionID`, which folds and cases every title, and same-letter
    /// filler would land in one section and understate the grouping and string work.
    private static let scaledTitles:
      [(id: String, title: String, author: String, series: String?, category: ItemMediaCategory)] = {
        let scale = max(1, HarnessAblation.fixtureScale)
        guard scale > 1 else { return [] }
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let articles = ["", "The ", "A ", "An "]
        let stems = ["Orbit", "Ördög", "Lantern", "Naïve Hour", "Quiet Tide", "Émigré"]
        return (0..<((scale - 1) * 102)).map { index in
          let letter = letters[index % letters.count]
          let article = articles[(index / letters.count) % articles.count]
          let stem = stems[index % stems.count]
          return (
            id: "harness-scaled-\(index)",
            title: "\(article)\(letter)\(stem) \(index)",
            author: "Scaled Author \(index % 97)",
            series: index.isMultiple(of: 3) ? "Scaled Series #\(index % 41)" : nil,
            category: index.isMultiple(of: 2) ? .ebook : .audiobook
          )
        }
      }()

    /// Cached rather than recomputed per access: at scale this is thousands of rows, and rebuilding
    /// them inside an observation call would put harness cost in a measured window.
    private static let summaries: [ItemSummary] = {
      let titleSummaries = titles.map { entry in
        ItemSummary(
          serverItemId: entry.id,
          mediaKind: "book",
          title: entry.title,
          author: entry.author.isEmpty ? nil : entry.author,
          durationSeconds:
            entry.id == Self.unknownDurationItemID ? 0 : UIHarnessFixtures.duration,
          category: entry.category,
          seriesName: entry.series
        )
      }
      return titleSummaries + [mixedSummary]
    }()

    private static let mixedSummary = ItemSummary(
      serverItemId: UIHarnessFixtures.mixedItemID,
      mediaKind: "book",
      title: UIHarnessFixtures.mixedTitle,
      author: UIHarnessFixtures.mixedAuthor,
      durationSeconds: UIHarnessFixtures.duration,
      category: UIHarnessFixtures.mixedCategory,
      hasReadableEbook: UIHarnessFixtures.mixedHasReadableEbook)

    var itemCount: Int { Self.summaries.count }

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
    /// started: it passes Unplayed and fails In Progress and Finished, and a podcast show drops out
    /// of every engaged playback state. Spelled out, as `HarnessLibraryReading` does, so the
    /// harness cannot show a filtered list as if it were unfiltered.
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
      AsyncStream {
        $0.yield(LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: nil))
      }
    }

    func observeAggregateSyncStatus() -> AsyncStream<LibrarySyncStatus> {
      AsyncStream {
        $0.yield(LibrarySyncStatus(isRunning: false, lastRunIncomplete: false, lastCompletedAt: nil))
      }
    }

    func observeItemDetail(itemId: String) -> AsyncStream<ItemSummary?> {
      AsyncStream { $0.yield(Self.summaries.first { $0.serverItemId == itemId }) }
    }

    func observeItems(ids: [String]) -> AsyncStream<[ItemSummary]> {
      AsyncStream { $0.yield(Self.summaries.filter { ids.contains($0.serverItemId) }) }
    }

    func observeItemPlaybackProgress(itemIDs: Set<String>)
      -> AsyncStream<[String: ItemPlaybackProgress]>
    {
      let progress = Self.playbackProgress.filter { itemIDs.contains($0.key) }
      return AsyncStream { $0.yield(progress) }
    }

    func observeItemPlaybackStatuses() -> AsyncStream<[String: ItemPlaybackStatus]> {
      AsyncStream { $0.yield(Self.playbackStatuses) }
    }
  }

  /// Authors and Series over the same fixture set, so the two non-default browse modes render
  /// their own pinned headers and index rather than an empty state.
  enum HarnessAuthorSeriesDestination: Hashable, Identifiable {
    case author(id: String, libraryID: String)
    case series(id: String, libraryID: String)

    var id: String {
      switch self {
      case .author(let id, let libraryID): "author#\(libraryID)#\(id)"
      case .series(let id, let libraryID): "series#\(libraryID)#\(id)"
      }
    }

    var target: AuthorSeriesModel.Target {
      switch self {
      case .author(let id, let libraryID): .author(id: id, libraryID: libraryID)
      case .series(let id, let libraryID): .series(id: id, libraryID: libraryID)
      }
    }
  }

  struct HarnessAuthorSeriesReading: AuthorSeriesReading {
    private static let audiobookLibraryID = "harness-audiobooks"
    private static let ebookLibraryID = "harness-ebooks"

    private static func libraryID(for category: ItemMediaCategory) -> String {
      category == .ebook ? ebookLibraryID : audiobookLibraryID
    }

    private static func identities(
      kind: SearchResultKind, index: Int
    ) -> [AuthorSeriesEntity.Identity] {
      [
        AuthorSeriesEntity.Identity(
          entityID: "harness-\(kind.rawValue)-\(index)-audio", libraryID: audiobookLibraryID),
        AuthorSeriesEntity.Identity(
          entityID: "harness-\(kind.rawValue)-\(index)-ebook", libraryID: ebookLibraryID),
      ]
    }

    func entities(
      kind: SearchResultKind, libraryID: String?, limit: Int, offset: Int
    ) async throws -> AuthorSeriesBrowsePage {
      // Drawn from the fixture items, so the names the "server" lists are the names the local join
      // can match. A hand-written list that drifted from the items would show every row as a bare
      // name and hide the enrichment this harness exists to eyeball.
      let names =
        kind == .author
        ? Array(
          Set(
            HarnessLibraryBrowseReading.titles
              .filter { $0.author.isEmpty == false }
              .map(\.author)
          )
        ).sorted()
        : Array(
          Set(
            HarnessLibraryBrowseReading.titles.compactMap {
              LibraryEntityGrouping.seriesDescriptor(from: $0.series)?.name
            })
        ).sorted()
      let entities = names.enumerated().map { index, name in
        AuthorSeriesEntity(
          kind: kind, name: name, identities: Self.identities(kind: kind, index: index),
          bookCount: nil)
      }
      return AuthorSeriesBrowsePage(entities: entities, hasMore: false)
    }

    func entity(
      kind: SearchResultKind, entityID: String, libraryID: String?
    ) async throws -> AuthorSeriesEntity? {
      try await entities(kind: kind, libraryID: libraryID, limit: 50, offset: 0)
        .entities
        .first { entity in
          entity.identities.contains { identity in
            identity.entityID == entityID
              && (libraryID == nil || identity.libraryID == libraryID)
          }
        }
    }

    /// The entity detail page, from the same fixtures. Each identity is served from its own media
    /// slice so the detail model's two independent cursors and the mixed-format merge are visible
    /// without a live server.
    func items(
      kind: SearchResultKind, entityID: String, libraryID: String?, limit: Int, offset: Int
    ) async throws -> SearchPage {
      guard
        let name = try await entities(kind: kind, libraryID: libraryID, limit: limit, offset: 0)
          .entities
          .first(where: { entity in
            entity.identities.contains { identity in
              identity.entityID == entityID && identity.libraryID == libraryID
            }
          })?.name
      else { return SearchPage(rows: [], hasMore: false) }

      let matches = HarnessLibraryBrowseReading.titles.filter { entry in
        guard libraryID == nil || Self.libraryID(for: entry.category) == libraryID else {
          return false
        }
        return kind == .author
          ? entry.author == name
          : LibraryEntityGrouping.seriesDescriptor(from: entry.series)?.name == name
      }

      let page = Array(matches.dropFirst(offset).prefix(limit))
      let rows = page.map { entry in
        SearchResultRow(
          kind: .book, entityID: entry.id, title: entry.title,
          subtitle: entry.author.isEmpty ? nil : entry.author,
          mediaCategory: entry.category, seriesName: entry.series,
          durationSeconds:
            entry.id == HarnessLibraryBrowseReading.unknownDurationItemID
            ? 0
            : UIHarnessFixtures.duration,
          libraryID: libraryID ?? Self.libraryID(for: entry.category))
      }
      return SearchPage(rows: rows, hasMore: offset + rows.count < matches.count)
    }
  }
#endif
