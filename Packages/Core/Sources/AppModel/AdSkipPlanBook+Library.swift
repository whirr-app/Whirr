import AdSkip
import CryptoKit
import Foundation
import Persistence

/// The library and the plans it supports: every analysable episode's print and every learned ad's,
/// the stage-1 windows each recurs in, and the coverage a transcript file has.
///
/// Nothing here asks the queue or deletes rows. A print that cannot be read is thrown back as
/// `UnreadablePrints`; the coordinator owns the delete and the load that follows it.
///
/// The `async` members take `on coordinator: isolated AdSkipCoordinator`, so they run on the
/// coordinator's executor and cannot be called from anywhere else. They read no coordinator state:
/// the parameter is the isolation, nothing more.
extension AdSkipPlanBook {
  /// A print that could not be read, with the episodes it belonged to. The coordinator deletes
  /// their rows and loads the library again, as the one recursive load used to.
  struct UnreadablePrints: Error {
    let identities: [AdSkipEpisodeIdentity]
  }

  /// A transcript file's duration, coverage and silences, cached by file name so the queue does
  /// not decode every transcript on every pass. A file name is never reused.
  func transcriptCoverage(fileName: String) -> TranscriptCoverage? {
    if let cached = transcriptCoverages[fileName] { return cached }
    guard let stored = try? dependencies.transcripts.read(fileName: fileName) else { return nil }
    let coverage = TranscriptCoverage(
      duration: stored.duration, spans: stored.coverageSpans, silences: stored.pipelineSilences)
    transcriptCoverages[fileName] = coverage
    return coverage
  }

  // MARK: - Planning

  /// The row's stage-1 plan; nil exactly when `stageOneWindows` is. `local` is the local-episode
  /// set the library is loaded against, read where the load begins.
  func stageOnePlan(
    of row: AdSkipEpisodeRecord, local: [AdSkipEpisodeIdentity: AdSkipLocalEpisode],
    on coordinator: isolated AdSkipCoordinator
  ) async throws -> StageOnePlan? {
    guard dependencies.transcribesWholeFiles == false, row.audioPrintFileName != nil else {
      return nil
    }
    if let planned = stageOnePlans[row.identity] { return planned }
    let library = try await loadedAudioLibrary(local: local, on: coordinator)
    guard let query = library.queryIndex[row.identity] else {
      return StageOnePlan(windows: [], audioEdges: [])
    }
    let plan: StageOnePlan
    // A stored plan is what this exact library planned last time; one that cannot be read is
    // planned again.
    if let rowId = row.id,
      let stored = try? await dependencies.episodes.stageOnePlan(
        forEpisodeId: rowId, libraryKey: library.key)
    {
      plan = StageOnePlan(
        windows: stored.windows.map { TimeSpan(start: $0.start, end: $0.end) },
        audioEdges: stored.audioEdges.map { TimeSpan(start: $0.start, end: $0.end) },
        crossShow: stored.crossShow.map {
          CrossShowAlignment(
            span: TimeSpan(start: $0.start, end: $0.end), episode: EpisodeKey($0.episodeKey))
        },
        sameShowEdges: stored.sameShowEdges.map { TimeSpan(start: $0.start, end: $0.end) })
    } else {
      if let carried = carriedStageOnePlans.removeValue(forKey: row.identity) {
        plan = carried
      } else {
        stageOneQueries += 1
        plan = await Self.query(query, in: library)
      }
      if let rowId = row.id {
        // A cache: a plan that fails to save is made again next time.
        try? await dependencies.episodes.saveStageOnePlan(
          StoredStageOnePlan(
            windows: plan.windows.map { StoredTimeSpan(start: $0.start, end: $0.end) },
            audioEdges: plan.audioEdges.map { StoredTimeSpan(start: $0.start, end: $0.end) },
            crossShow: plan.crossShow.map {
              StoredCrossShowAlignment(
                start: $0.span.start, end: $0.span.end, episodeKey: $0.episode.rawValue)
            },
            sameShowEdges: plan.sameShowEdges.map { StoredTimeSpan(start: $0.start, end: $0.end) }),
          forEpisodeId: rowId, libraryKey: library.key)
      }
    }
    // A stored plan updates the stage-2 state as a query does.
    stageOnePlans[row.identity] = plan
    if lastStageOne[row.identity] != plan.windows {
      // A different plan is a new start for stage 2.
      lastStageOne[row.identity] = plan.windows
      stageTwoRounds[row.identity] = nil
      stageTwoAwaiting.remove(row.identity)
    }
    return plan
  }

  /// One stage-1 query: the library's alignments with `library.references[query]`, off the actor.
  static func query(_ query: Int, in library: AudioLibrary) async -> StageOnePlan {
    let references = library.references
    let recurrence = await Task.detached(priority: .utility) {
      AudioRecurrence.recurrence(of: query, in: references)
    }.value
    return StageOnePlan(
      windows: TranscriptionWindows.stageOne(runs: recurrence.runs),
      audioEdges: library.audioEdges(of: query, alignments: recurrence.alignments),
      crossShow: library.crossShow(of: query, alignments: recurrence.alignments),
      sameShowEdges: library.sameShow(of: query, alignments: recurrence.alignments))
  }

  /// The library, loaded once per change to the set of prints. A print that cannot be read is
  /// thrown to the coordinator, which has its episode decoded again, once, as an unreadable
  /// transcript does.
  func loadedAudioLibrary(
    local: [AdSkipEpisodeIdentity: AdSkipLocalEpisode],
    on coordinator: isolated AdSkipCoordinator
  ) async throws -> AudioLibrary {
    if let audioLibrary { return audioLibrary }
    let rows = try await dependencies.episodes.allEpisodes().filter {
      $0.state != .failed && $0.audioPrintFileName != nil
        && dependencies.isAnalysable(local[$0.identity])
    }
    var library = AudioLibrary()
    var printed: [(AdSkipEpisodeRecord, AudioPrint)] = []
    var unreadable: [AdSkipEpisodeIdentity] = []
    for row in rows {
      guard let name = row.audioPrintFileName,
        let data = try? dependencies.transcripts.readAudioPrint(fileName: name),
        let print = AudioPrint(littleEndianData: data)
      else {
        unreadable.append(row.identity)
        continue
      }
      printed.append((row, print))
    }
    // Linked copies carry each other's keys, so they never match each other.
    let groups = Self.linkedKeyGroups(
      keys: printed.map(\.0.identity.episodeKey),
      links: Self.identityLinks(rows: printed.map(\.0), local: local))
    let shows = Self.shows(of: Array(local.values))
    // A print file's name is never reused and a creative's print never changes, so each names its
    // print's content. An episode's show decides which of its alignments are another show's.
    for (row, print) in printed {
      let key = row.identity.episodeKey
      let keys = groups[key] ?? [key]
      let show = shows[row.identity] ?? ""
      library.queryIndex[row.identity] = library.references.count
      library.references.append(AudioRecurrence.Reference(print: print, keys: keys))
      library.episodeKeys.append(key)
      library.shows.append(show)
      library.showByEpisode[row.identity] = show
      library.entries.append(Self.compositionLine("e", row.audioPrintFileName ?? "", keys, show: show))
    }
    library.groups = groups
    try await Self.addLearnedPrints(to: &library, from: dependencies.signatures)
    library.key = SHA256.hash(
      data: Data(([Self.stageOnePlanRules] + library.entries).joined(separator: "\n").utf8)
    )
    .map { String(format: "%02x", $0) }.joined()
    if unreadable.isEmpty == false {
      throw UnreadablePrints(identities: unreadable)
    }
    carriedStageOnePlans = await plansCarried(into: library, on: coordinator)
    uncheckedCarriedPlans = Set(carriedStageOnePlans.keys)
    retainedPlans = nil
    audioLibrary = library
    return library
  }

  /// Bumped whenever `AudioRecurrence` or `TranscriptionWindows.stageOne` changes behaviour without
  /// a constant below changing, or a plan holds something new, so no stored plan outlives the
  /// rules it was made under.
  static let stageOnePlanRevision = 4

  /// The rules a stored stage-1 plan was made under.
  static let stageOnePlanRules = [
    "\(stageOnePlanRevision)", "\(AdSkipRules.revision)", "\(AudioPrint.sampleRate)",
    "\(AudioPrint.frameLength)", "\(AudioPrint.hopLength)", "\(AudioRecurrence.blockFrames)",
    "\(AudioRecurrence.maximumBitErrorRate)", "\(AudioRecurrence.minimumVotes)",
    "\(AudioRecurrence.offsetsPerChunk)", "\(AudioRecurrence.chunkFrames)",
    "\(AudioRecurrence.commonOccurrences)", "\(AudioRecurrence.refinementFrames)",
    "\(TranscriptionWindows.mergeSeconds)", "\(TranscriptionWindows.minimumRunSeconds)",
    "\(TranscriptionWindows.marginSeconds)",
  ].joined(separator: ",")

  static func compositionLine(
    _ kind: String, _ name: String, _ keys: Set<EpisodeKey>, show: String? = nil
  ) -> String {
    ([kind, name] + (show.map { [$0] } ?? []) + keys.map(\.rawValue).sorted())
      .joined(separator: "\u{1F}")
  }

  /// Each episode's show: its source, account and item, joined across
  /// sources by a linked copy and by the feed's fingerprint, so one show followed through
  /// RSS and Audiobookshelf is one show. Named by the least of its source keys.
  static func shows(of episodes: [AdSkipLocalEpisode]) -> [AdSkipEpisodeIdentity: String] {
    func show(_ identity: AdSkipEpisodeIdentity) -> String {
      [identity.source.rawValue, identity.accountId.map(String.init) ?? "", identity.itemID]
        .joined(separator: "\u{1F}")
    }
    let feed = "feed\u{1F}"
    var nodes: Set<String> = []
    var links: [(String, String)] = []
    for episode in episodes {
      let own = show(episode.identity)
      nodes.insert(own)
      let feedNode = episode.feedFingerprint.map { [feed + $0] } ?? []
      for linked in episode.linkedIdentities.map(show) + feedNode {
        nodes.insert(linked)
        links.append((own, linked))
      }
    }
    let groups = linkedKeyGroups(keys: nodes.sorted(), links: links)
    return Dictionary(
      episodes.map { episode in
        let own = show(episode.identity)
        return (episode.identity, groups[own]?.filter { $0.hasPrefix(feed) == false }.min() ?? own)
      }, uniquingKeysWith: { first, _ in first })
  }

  /// Every key's connected component under the links.
  static func linkedKeyGroups<Key: Hashable & Comparable>(
    keys: [Key], links: [(Key, Key)]
  ) -> [Key: Set<Key>] {
    var parent = Dictionary(keys.map { ($0, $0) }, uniquingKeysWith: { first, _ in first })
    func root(_ key: Key) -> Key {
      var key = key
      while let next = parent[key], next != key { key = next }
      return key
    }
    for (a, b) in links where parent[a] != nil && parent[b] != nil {
      let (ra, rb) = (root(a), root(b))
      if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
    }
    let components = Dictionary(grouping: keys, by: root)
    return Dictionary(
      keys.map { ($0, Set(components[root($0)] ?? [$0])) }, uniquingKeysWith: { first, _ in first })
  }

  // MARK: - Learned prints

  /// The keys a learned ad's print carries in the audio library, which are the episodes it may
  /// not open a window on: its teachers, when every one is a printed episode in the library and
  /// they all lie in one of its linked groups. Otherwise none. A teacher that has left the phone
  /// is outside every group. Dropping it instead would bar the print from the remaining
  /// teachers, and their windows would not open on words the text rule matches.
  static func audioKeys(
    teachers: Set<EpisodeKey>, groups: [EpisodeKey: Set<EpisodeKey>]
  ) -> Set<EpisodeKey> {
    guard let first = teachers.first, let group = groups[first], teachers.isSubset(of: group) else { return [] }
    return teachers
  }

  /// Adds every learned ad's print to the library, after the episodes'. A pure step over the
  /// store, so it needs neither the book nor the actor.
  static func addLearnedPrints(
    to library: inout AudioLibrary, from signatures: AdSignatureStore
  ) async throws {
    for creative in try await signatures.learnedAudioPrints() {
      let keys = Self.audioKeys(teachers: Set(creative.teachers.map(EpisodeKey.init)), groups: library.groups)
      library.creativeKeys[creative.id] = keys
      guard let print = AudioPrint(littleEndianData: creative.audioPrint) else { continue }
      if creative.confirmed, print.isEmpty == false { library.confirmedPrints[creative.id] = print }
      library.references.append(AudioRecurrence.Reference(print: print, keys: keys))
      library.entries.append(Self.compositionLine("c", "\(creative.id)", keys))
    }
  }

  // MARK: - Identity

  /// Identity links: an RSS episode and its Audiobookshelf copies, and files with equal
  /// fingerprints.
  static func identityLinks(
    rows: [AdSkipEpisodeRecord], local: [AdSkipEpisodeIdentity: AdSkipLocalEpisode]
  ) -> [(EpisodeKey, EpisodeKey)] {
    let analysed = Set(rows.map(\.identity))
    var links: [(EpisodeKey, EpisodeKey)] = []
    for row in rows {
      for linked in local[row.identity]?.linkedIdentities ?? [] where analysed.contains(linked) {
        links.append((row.identity.episodeKey, linked.episodeKey))
      }
    }
    let byFingerprint = Dictionary(grouping: rows, by: \.fingerprint)
    for copies in byFingerprint.values where copies.count > 1 {
      let keys = copies.map(\.identity.episodeKey).sorted()
      for key in keys.dropFirst() { links.append((keys[0], key)) }
    }
    return links
  }

  // MARK: - Invalidation

  /// Forgets every plan: a print arrived or left, so any episode's windows may have changed. The
  /// plans are kept aside for the next library, which carries those it cannot have changed.
  func invalidateAudioPlans() {
    if let audioLibrary, dependencies.replansIncrementally {
      retainedPlans = RetainedPlans(
        entries: audioLibrary.entries,
        entryByEpisode: audioLibrary.queryIndex.mapValues { audioLibrary.entries[$0] },
        plans: carriedStageOnePlans.merging(stageOnePlans) { _, planned in planned })
    }
    audioLibrary = nil
    confirmedReachCache = [:]
    stageOnePlans = [:]
    carriedStageOnePlans = [:]
    uncheckedCarriedPlans = []
  }
}
