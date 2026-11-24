import ABSApi
import DesignSystem
import Persistence
import SwiftUI
import UIKit

private struct ArtworkServingByteReader: ArtworkByteReading {
  let client: any ArtworkServing

  func data(for key: ArtworkKey) async -> Data? {
    await client.data(for: key)
  }
}

struct CoverImageView: View {
  enum Role: Hashable, Sendable {
    case libraryThumbnail
    case homeCard
    case highFidelity
    /// The item-detail cover. Keyed by `DetailArtwork`, not by `displaySize`, so the hero, the
    /// context-menu preview and the bulk cover pass share one cache entry per cover.
    case detail
  }

  /// How the decoded cover fills its square frame. Only the image composition changes, never the
  /// frame, so no layout, grid, or cache-key geometry moves with the choice.
  enum Presentation: Equatable, Sendable {
    /// Fill the square, cropping whatever overflows. The only mode on dense rows, where cropping is
    /// imperceptible and row geometry is heavily pinned.
    case fill
    /// Fit the whole cover inside the square, leaving the residual margins transparent so the
    /// surface's own background (a detail hero's wash, a Home tile's card) shows through. For
    /// surfaces on a coloured background, where cropping a portrait cover would lose its title and
    /// author and painted bars would read as a panel. The long-press preview takes the cover's
    /// shape instead, so needs no margin (see `ItemContextMenuPreview`).
    case fitTransparent
  }

  /// A hairline on the artwork's own edges, for a cover drawn on a coloured surface that would
  /// otherwise have nothing to end against.
  ///
  /// Handed to this view like the marks: stroked on the caller's frame, a `.fitTransparent`
  /// portrait cover would get a square drawn around it.
  struct Rim: Equatable {
    var color: Color
    var lineWidth: CGFloat
  }

  let itemID: String
  let title: String
  let displaySize: CGFloat
  let client: any ArtworkServing
  /// Explicit provider identity for non-ABS artwork. Nil means ABS.
  var source: ArtworkSource?
  /// Drawn when `source` ends unavailable or failed (an episode's own image that cannot be had falls
  /// back to its show's). Nil keeps the generated cover or blank placeholder.
  var fallbackSource: ArtworkSource?
  /// Only used to set the generated cover shown when the server has no artwork for the item.
  var author: String?
  var role: Role = .libraryThumbnail
  /// Fill-crop by default. Large surfaces on a coherent background opt into `.fitTransparent`;
  /// podcast artwork always keeps `.fill` (pinned-ratio contract).
  var presentation: Presentation = .fill
  /// Where a `.fitTransparent` cover sits in the margin. Grids with corner marks pass `.top`, or
  /// a centred square cover would leave a mark floating above the art. Ignored by `.fill`.
  var fitAlignment: Alignment = .center
  /// Corner marks drawn on the artwork, not the frame: only this view knows where it ended up.
  var artworkMarks: CoverArtworkMarks = .none
  var artworkRim: Rim?
  /// Draws `CoverGlow` behind the artwork, at the artwork's own shape. Outside this view's clip, so
  /// it reaches as far as the caller's clip lets it. No glow while the placeholder shows: the art's
  /// shape is not known yet.
  var artworkGlow = false
  /// Row-thumbnail radius by default. A much larger tile passes its own: the same clip that reads
  /// as slightly softened at 44pt reads as a hard square at 72.
  var cornerRadius: CGFloat = WhirrSpacing.xxSmall
  /// No default anywhere on this path: every surface drawing an ABS item must name the same
  /// revision for it, or the item's single palette row is re-derived each time another one asks.
  var revision: ArtworkRevision
  var priority: ArtworkPriority = .visible
  var cache: any PreparedArtworkCaching = PreparedArtworkCache.shared
  var pipeline: ArtworkImagePipeline = .shared
  /// Told the finished cover each body pass draws, for a caller that needs the picture on screen
  /// after the prepared cache has dropped it.
  var drawnArtwork: DrawnArtwork?

  init(
    itemID: String,
    title: String,
    displaySize: CGFloat,
    client: any ArtworkServing,
    source: ArtworkSource?,
    fallbackSource: ArtworkSource? = nil,
    author: String? = nil,
    role: Role = .libraryThumbnail,
    presentation: Presentation = .fill,
    fitAlignment: Alignment = .center,
    artworkMarks: CoverArtworkMarks = .none,
    artworkRim: Rim? = nil,
    artworkGlow: Bool = false,
    cornerRadius: CGFloat = WhirrSpacing.xxSmall,
    revision: ArtworkRevision,
    priority: ArtworkPriority = .visible,
    cache: any PreparedArtworkCaching = PreparedArtworkCache.shared,
    pipeline: ArtworkImagePipeline = .shared,
    drawnArtwork: DrawnArtwork? = nil
  ) {
    self.itemID = itemID
    self.title = title
    self.displaySize = displaySize
    self.client = client
    self.source = source
    self.fallbackSource = fallbackSource
    self.author = author
    self.role = role
    self.presentation = presentation
    self.fitAlignment = fitAlignment
    self.artworkMarks = artworkMarks
    self.artworkRim = artworkRim
    self.artworkGlow = artworkGlow
    self.cornerRadius = cornerRadius
    self.revision = revision
    self.priority = priority
    self.drawnArtwork = drawnArtwork
    #if PERF_INVESTIGATION
      self.cache =
        MicrostutterAblation.coldArtwork
        ? MicrostutterArtworkFixture.cache : cache
      self.pipeline =
        MicrostutterAblation.coldArtwork
        ? MicrostutterArtworkFixture.pipeline : pipeline
    #else
      self.cache = cache
      self.pipeline = pipeline
    #endif
  }

  @Environment(\.displayScale) private var displayScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var loadedImage: UIImage?
  @State private var loadedKey: ArtworkKey?
  /// Retention for a cover the synchronous cache already served on this body pass.
  ///
  /// Not observed: writing it must not invalidate the body (recording a cache hit into
  /// `loadedImage` forces a second pass, on 37% of tiles in a real library). Stops a
  /// `PreparedArtworkCache` eviction of a visible cover becoming a placeholder flash.
  @State private var retained = RetainedArtwork()
  @State private var seedImage: UIImage?
  @State private var seedKey: ArtworkKey?
  /// Keys the pipeline has already come back empty for. Until a key lands here the placeholder
  /// stays blank, so a cover that is merely slow never flashes generated art first.
  @State private var missingKey: ArtworkKey?
  /// The key whose image arrived inside `promptCompletionWindow` of this view asking for it, so
  /// it lands without the crossfade.
  @State private var promptKey: ArtworkKey?
  /// The fallback's cover, drawn for `fallbackDrawnFor` (the primary key it stands in for) while
  /// the primary cannot be had.
  @State private var fallbackImage: UIImage?
  @State private var fallbackDrawnFor: ArtworkKey?

  /// The ablation branch is `_ConditionalContent`, not `AnyView`: an erased baseline would change
  /// the structural identity of every cover and make the control arm the thing being measured.
  @ViewBuilder
  var body: some View {
    #if DEBUG || PERF_INVESTIGATION
      if HarnessAblation.noCoverArtwork {
        Color.gray.opacity(0.25)
          .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      } else {
        artworkBody
      }
    #else
      artworkBody
    #endif
  }

  @ViewBuilder
  private var artworkBody: some View {
    let _ = harnessNote(.coverBody)
    let key = artworkKey
    let preparedImage = cache.image(for: key)
    let primaryImage = preparedImage ?? retainedImage(for: key)
    let image = primaryImage ?? (fallbackDrawnFor == key ? fallbackImage : nil)
    let preparedSeed =
      preparedImage == nil
      ? cache.firstImage(for: Self.preparedSeedKeys(for: key, seedVariants: seedVariants))
      : nil
    // A cache entry seen before this view has completed the key is a first-frame prepared hit.
    // Once the async task records `loadedKey`, the same cache entry is its cold completion and is
    // eligible for the normal crossfade.
    let isPreparedHit = preparedImage != nil && loadedKey != key
    let _ = retained.notePainted(preparedImage != nil ? key : nil)
    let _ = drawnArtwork?.note(primaryImage, for: key)
    let seed = missingKey == key ? nil : (preparedSeed?.image ?? validSeedImage(for: key))
    let marks = HarnessSwitch.coverMarks(artworkMarks)
    #if PERF_INVESTIGATION
      // Every tile evaluates this body exactly twice on a device against a real library, and an
      // 8x prepared-cache budget does not change that, so the doubling is not eviction. These
      // counters separate the candidates: whether the synchronous tier is ever consulted
      // successfully, which branch each pass takes, and whether the second pass is served by the
      // cache or only by this view's own `loadedImage` state.
      let _ = MicrostutterProbe.shared.note(
        preparedImage == nil ? "Cover.sync.miss" : "Cover.sync.hit")
      let _ = MicrostutterProbe.shared.note("Cover.scale.\(displayScale)")
      let _ = MicrostutterProbe.shared.note("Cover.size.\(Int(displaySize))")
      let _ = MicrostutterProbe.shared.note(
        image != nil
          ? (preparedImage == nil ? "Cover.branch.imageFromState" : "Cover.branch.imageFromCache")
          : (seed != nil ? "Cover.branch.seed" : "Cover.branch.placeholder"))
    #endif
    artworkContent(image: image, seed: seed, marks: marks, isMissing: missingKey == key)
      .ablatable(HarnessSwitch.skipsCoverOuterClip) {
        $0.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      }
      .background {
        if artworkGlow, let drawn = image ?? seed {
          CoverGlow(
            aspectRatio: Self.glowAspectRatio(presentation: presentation, imageSize: drawn.size),
            alignment: fitAlignment
          )
          .transition(.opacity)
        }
      }
      .animation(
        Self.completionAnimation(
          isPreparedHit: isPreparedHit, isPromptCompletion: promptKey == key,
          reduceMotion: reduceMotion),
        value: image != nil
      )
      .task(id: key) {
        await loadArtwork(for: key)
      }
  }

  /// The one branch this pass draws: a real image, a smaller cached seed, or the placeholder.
  /// Split from `artworkBody` so the state it resolves and the modifiers around the result stay
  /// readable.
  @ViewBuilder
  private func artworkContent(
    image: UIImage?, seed: UIImage?, marks: CoverArtworkMarks, isMissing: Bool
  ) -> some View {
    if let image {
      CoverArtImage(
        uiImage: image, presentation: presentation, cornerRadius: cornerRadius,
        fitAlignment: fitAlignment, marks: marks, rim: artworkRim
      )
      .transition(.opacity)
    } else if let seed {
      CoverArtImage(
        uiImage: seed, presentation: presentation, cornerRadius: cornerRadius,
        fitAlignment: fitAlignment, marks: marks, rim: artworkRim
      )
      .transition(.opacity)
    } else {
      CoverPlaceholder(
        accessibilityLabel: title,
        title: title,
        author: author,
        state: isMissing ? .missing : .loading
      )
      // A placeholder paints the whole frame, so its corners are the artwork's corners.
      .overlay { CoverArtworkMarksOverlay(marks: marks) }
      .overlay { CoverArtRim(rim: artworkRim, cornerRadius: cornerRadius) }
      .reportsCoverArtworkBounds()
      .transition(.opacity)
    }
  }

  /// The keyed load: a prepared-cache hit paints and revalidates, else the pipeline outcome runs
  /// with its seed probe, fallback and reprobe schedule.
  private func loadArtwork(for key: ArtworkKey) async {
    let initialPrepared = cache.image(for: key)
    #if PERF_INVESTIGATION
      // Unconditional: the existing pair below fires only under the cold-artwork ablation, and
      // the question here is what the cache holds during an ordinary scroll.
      MicrostutterProbe.shared.note(
        initialPrepared == nil ? "Cover.task.miss" : "Cover.task.hit")
      if MicrostutterAblation.coldArtwork {
        MicrostutterProbe.shared.note(
          initialPrepared == nil
            ? "Artwork.preparedCache.miss"
            : "Artwork.preparedCache.hit")
        if initialPrepared == nil {
          MicrostutterProbe.shared.note("Artwork.request.started")
        }
      }
    #endif
    if let prepared = initialPrepared {
      retained.key = key
      retained.image = prepared
      // The unobserved write above is only enough when the body already drew this entry. A hit
      // that arrived after the body missed (Home's palette work or a prefetcher filling the
      // shared cache in between) must invalidate, or the placeholder is never replaced.
      if retained.paintedKey != key {
        promptKey = key
        loadedKey = key
        loadedImage = prepared
      }
      #if PERF_INVESTIGATION
        if MicrostutterAblation.coldArtwork {
          MicrostutterProbe.shared.note("Artwork.visible.success")
        }
      #endif
      // Never re-poll a cover the synchronous cache already served while a surface is moving.
      // A browse sweep materialises hundreds of tiles; revalidating each puts that many
      // conditional fetches on the scroll path, and their continuations stall the run loop
      // (ten `.task` tails in one 25 ms turn). Safe: the entry is displayable, and the cover
      // revalidates next time it appears at rest. Artwork clears and sync still invalidate.
      guard ArtworkScrollActivity.shared.isScrolling == false else {
        return
      }

      // Paint the prepared bytes before waiting. A changed response is bounded to this key by
      // the keyed task's cancellation and replaces both the displayed and prepared image.
      if let replacement = await pipeline.revalidate(
        for: key, priority: priority, client: client)
      {
        guard Task.isCancelled == false else { return }
        loadedKey = key
        loadedImage = replacement
        cache.insert(replacement, for: key)
      }
      return
    }

    let candidates = ArtworkSeedLadder.candidates(for: key, seedVariants: seedVariants)
    let requestedAt = ContinuousClock.now
    async let realOutcome = pipeline.outcome(for: key, priority: priority, client: client)
    let seedTask = Task { @MainActor in
      guard
        let seed = await pipeline.seedImage(
          candidates: candidates, byteReader: ArtworkServingByteReader(client: client)),
        Task.isCancelled == false
      else {
        return
      }
      seedKey = seed.key
      seedImage = seed.image
    }
    defer { seedTask.cancel() }

    let outcome = await realOutcome
    guard Task.isCancelled == false else { return }
    switch outcome {
    case .image(let prepared):
      promptKey =
        Self.isPromptCompletion(elapsed: ContinuousClock.now - requestedAt) ? key : nil
      loadedKey = key
      loadedImage = prepared
      #if PERF_INVESTIGATION
        if MicrostutterAblation.coldArtwork {
          // A nonnil image after an initial prepared-cache miss proves a successful visible
          // pipeline outcome. Not labelled as an exact decoder invocation.
          MicrostutterProbe.shared.note("Artwork.pipeline.image.success")
          MicrostutterProbe.shared.note("Artwork.visible.success")
        }
      #endif
      seedKey = nil
      seedImage = nil
    case .unavailable:
      // The seed decides the verdict: a smaller cached rung proves the cover exists, so it must
      // finish before generated art can be promoted over it. It reads caches only, so the wait
      // is short.
      await seedTask.value
      await drawFallbackIfNeeded(for: key, after: outcome)
      // `.generated` is a placeholder identity, not evidence that the item has no artwork.
      if fallbackDrawnFor != key,
        Self.shouldMarkMissing(for: outcome, key: key, seeded: validSeedImage(for: key) != nil)
      {
        // Only a completed fetch that proved the item has no usable artwork may promote the
        // placeholder to its generated cover.
        missingKey = key
      }
    case .failed:
      // A cancellation or a transport failure says nothing about whether the item has artwork.
      // The quiet placeholder, or a seed from a smaller cached width, outranks generated art
      // for a cover this attempt could not reach. Wait for the seed: offline, the failure
      // arrives almost immediately, and `defer` would otherwise cancel the one probe that can
      // still put pixels on screen.
      await seedTask.value
      await drawFallbackIfNeeded(for: key, after: outcome)
    }

    // Whatever the seed found is already in `seedImage`. Cancel the probe now: `defer` would
    // only do it when this task ends, and the waits below would keep a byte read alive for
    // minutes.
    seedTask.cancel()
    await reprobe(key: key, after: outcome)
  }

  /// Re-asks for a cover this task has already been told it cannot have.
  ///
  /// Both endings are answers about one moment (a book uploaded minutes ago with no cover yet; a
  /// connection since restored), but the keyed task runs once per key, so the verdict would stick
  /// until the view is rebuilt.
  private func reprobe(key: ArtworkKey, after outcome: ArtworkFetchOutcome) async {
    let schedule = Self.reprobeSchedule(
      for: role, outcome: outcome, seeded: validSeedImage(for: key) != nil)
    for delay in schedule {
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard Task.isCancelled == false else { return }
      let retried = await pipeline.outcome(for: key, priority: priority, client: client)
      guard Task.isCancelled == false else { return }
      switch retried {
      case .image(let prepared):
        loadedKey = key
        loadedImage = prepared
        // The generated cover, if one was promoted, gives way to the real one.
        missingKey = nil
        fallbackImage = nil
        fallbackDrawnFor = nil
        seedKey = nil
        seedImage = nil
        return
      case .unavailable:
        // A retry that reaches the server and is told there is no cover has answered the question
        // the first attempt could not. Settling on generated art beats retrying into a blank
        // tile, but never over a seed, which is the real cover at a smaller width.
        await drawFallbackIfNeeded(for: key, after: retried)
        guard
          fallbackDrawnFor != key,
          Self.shouldMarkMissing(
            for: retried, key: key, seeded: validSeedImage(for: key) != nil)
        else { continue }
        missingKey = key
        return
      case .failed:
        await drawFallbackIfNeeded(for: key, after: retried)
        continue
      }
    }
  }

  /// Fetches the fallback's cover for a primary that ended without an image, once. A seed of the
  /// primary on screen outranks it (see `shouldDrawFallback`).
  private func drawFallbackIfNeeded(for key: ArtworkKey, after outcome: ArtworkFetchOutcome) async {
    guard fallbackDrawnFor != key,
      Self.shouldDrawFallback(
        after: outcome, fallbackKey: Self.fallbackKey(for: key, fallbackSource: fallbackSource),
        seeded: validSeedImage(for: key) != nil),
      let fallbackKey = Self.fallbackKey(for: key, fallbackSource: fallbackSource)
    else { return }
    let fetched = await pipeline.outcome(for: fallbackKey, priority: priority, client: client)
    guard Task.isCancelled == false, let image = fetched.image else { return }
    fallbackImage = image
    fallbackDrawnFor = key
  }

  /// The image and its seed present identically (else the shape pops on completion). A fitted
  /// image is inset from the frame, so the enclosing square clip's corners fall in the margin:
  /// the image is rounded here, at its own edges.
  struct CoverArtImage: View {
    let uiImage: UIImage
    let presentation: Presentation
    var cornerRadius: CGFloat = 0
    var fitAlignment: Alignment = .center
    var marks: CoverArtworkMarks = .none
    var rim: Rim?

    var body: some View {
      switch presentation {
      case .fill:
        // `.fill` on the image itself reports the oversized rectangle that covers the proposal, so
        // a non-square image would lay out wider or taller than its slot, and the clip, marks and
        // bounds below would all follow that; a flexible frame does not shrink it back. The clear
        // base takes the proposal and the image only draws over it.
        Color.clear
          .overlay {
            Image(uiImage: uiImage)
              .resizable()
              .aspectRatio(contentMode: .fill)
          }
          // The layout is the frame and only the drawing overflows, so the frame's corners
          // are the artwork's corners and the marks go here.
          .overlay { CoverArtworkMarksOverlay(marks: marks) }
          .overlay { CoverArtRim(rim: rim, cornerRadius: cornerRadius) }
          // A filled cover is its frame, so this reports the frame. The fallback and the real
          // measurement agree, and a caller need not know which presentation it was given.
          .reportsCoverArtworkBounds()
      case .fitTransparent:
        Image(uiImage: uiImage)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
          // Inside the fitted image's own bounds, so before the frame below. A portrait cover
          // fitted into a square box is inset on both sides, and a mark on the box's corner would
          // hang in that inset.
          .overlay { CoverArtworkMarksOverlay(marks: marks) }
          // Same bounds: the fitted artwork's own edge, not the box's.
          .overlay { CoverArtRim(rim: rim, cornerRadius: cornerRadius) }
          // Same bounds again, reported upwards for a caller that draws its own decoration on the
          // cover. Measured before the frame below, or it would measure the box.
          .reportsCoverArtworkBounds()
          // Places the fitted image within the caller's frame. `.center` letterboxes; a caller
          // marking the artwork's corners asks for `.top` so a row of covers shares one top edge.
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: fitAlignment)
      }
    }
  }

  /// Draws a `Rim` on whatever it covers, or nothing at all when there is none.
  ///
  /// `strokeBorder` rather than `stroke`: a stroke straddles the shape's path, so the outer half of
  /// a rim on the artwork's own edge is clipped away and the line renders at half the weight it
  /// asks for. A border is drawn wholly inside.
  private struct CoverArtRim: View {
    let rim: Rim?
    let cornerRadius: CGFloat

    var body: some View {
      if let rim {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(rim.color, lineWidth: rim.lineWidth)
          .allowsHitTesting(false)
      }
    }
  }

  private var artworkKey: ArtworkKey {
    Self.artworkKey(
      itemID: itemID,
      client: client,
      source: source,
      displaySize: displaySize,
      displayScale: displayScale,
      role: role,
      revision: revision)
  }

  /// Widths of the smaller surfaces in use: Home/podcast cards (140pt), show header (120pt),
  /// episode rows and card (56pt), browse/search rows and mini-player (44pt). Largest-first so the
  /// best cache hit wins. Add a width only while a surface requests it: probing one nothing caches
  /// always misses.
  private var seedVariants: [ArtworkVariant] {
    let scale = Double(displayScale)
    return [
      // 140pt: HomeView.cardCoverSize; PodcastsView/PodcastShowsView cardSize are also 140pt.
      .homeCard(displaySize: Double(HomeView.cardCoverSize), displayScale: scale),
      // 120pt: PodcastShowView.coverSize.
      .libraryThumbnail(displaySize: 120, displayScale: scale),
      // 56pt: HomeMoreView.coverSize, PlayerMetric.queueRowCoverSize, and the episode card's
      // borrowed PodcastEpisodeCardViewPresentation.Metric.artworkDisplaySize.
      .libraryThumbnail(displaySize: Double(HomeMoreView.coverSize), displayScale: scale),
      // 44pt: WhirrMetric.minimumTouchTarget.
      .libraryThumbnail(displaySize: Double(WhirrMetric.minimumTouchTarget), displayScale: scale),
    ]
  }

  /// A larger variant can keep the same item's thumbnail until ready. A changed item, scope, or
  /// revision never receives the previous identity's late pixels.
  private func retainedImage(for key: ArtworkKey) -> UIImage? {
    if let loadedKey, Self.canRetainImage(from: loadedKey, for: key) { return loadedImage }
    if let retainedKey = retained.key, Self.canRetainImage(from: retainedKey, for: key) {
      return retained.image
    }
    return nil
  }

  private func validSeedImage(for key: ArtworkKey) -> UIImage? {
    guard let seedKey, let seedImage, Self.canUseSeed(from: seedKey, for: key) else { return nil }
    return seedImage
  }
}
