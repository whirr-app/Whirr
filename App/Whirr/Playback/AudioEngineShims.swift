@preconcurrency import AVFoundation
import CoreSupport
import MediaToolbox
import PlayerCore

/// The slice of `AVQueuePlayer` behaviour `AVQueuePlayerAudioEngine` needs, wrapped so
/// `AVAudioEngineAdapterTests` can inject a fake instead of touching real AVFoundation.
/// `@MainActor` because `AVQueuePlayer` itself is (ARCHITECTURE.md §4).
@MainActor
protocol AudioQueuePlayerControlling: AnyObject {
  var rate: Float { get set }
  var volume: Float { get set }
  /// Fires when the player's `timeControlStatus` toggles into or out of
  /// `.waitingToPlayAtSpecifiedRate`. The adapter's sole source for `AudioEngineEvent.buffering`
  /// and the `.ready` that follows a rebuffer recovery. Set once, at construction.
  var onBufferingStateChanged: (@MainActor @Sendable (Bool) -> Void)? { get set }

  /// The queue's remaining items, current item first (matches `AVQueuePlayer.items()`).
  func items() -> [AudioPlayerItemHandle]
  func insert(_ item: AudioPlayerItemHandle, after afterItem: AudioPlayerItemHandle?)
  func remove(_ item: AudioPlayerItemHandle)
  func removeAllItems()
  func play()
  func pause()
  func addPeriodicTimeObserver(
    forInterval interval: CMTime, using block: @escaping @MainActor @Sendable (CMTime) -> Void
  ) -> Any
  /// Calls `block` with the player's current time when playback crosses any of `times` in the
  /// current item. Removed with `removeTimeObserver`.
  func addBoundaryTimeObserver(
    forTimes times: [CMTime], using block: @escaping @MainActor @Sendable (CMTime) -> Void
  ) -> Any
  func removeTimeObserver(_ observer: Any)
}

/// The slice of `AVPlayerItem` behavior the adapter needs. The real conformance performs KVO/
/// notification observation internally and surfaces already-translated callbacks, so
/// `AVQueuePlayerAudioEngine`'s own logic never touches KVO or `NotificationCenter` and is fully
/// testable via a fake conforming to this protocol.
@MainActor
protocol AudioPlayerItemHandle: AnyObject {
  /// The resolved resource this item was built from, including the exact headers stamped onto its
  /// asset. Item identity includes those headers: AVFoundation does not provide a way to update an
  /// existing asset's request headers after construction.
  var resource: PlaybackTrackResource { get }
  /// The `PlaybackTrack.index` this item was created for. Lets the adapter recognise an
  /// already-enqueued item (e.g. one `AVQueuePlayer` auto-advanced to) without a side table.
  var trackIndex: Int { get }
  /// The resolved stream URL, retained as a convenience for the adapter's URL-specific behavior.
  var url: URL { get }
  /// The Trim Silences map this item's composition was cut by; `nil` for a plain item. Position and
  /// duration on the item are in played time and cross to source time through it.
  var trim: PlayerTrimMap? { get }
  /// Latched by either failure observer. Once an item has failed, it is never eligible for reuse.
  var isUnusable: Bool { get }
  var isReady: Bool { get }
  /// `nil` until AVFoundation has resolved the item's duration, which for a progressively loaded
  /// stream can be well after `readyToPlay`. Read at ready and then followed through
  /// `onDurationChanged`; `PlayerCore` uses it only to extend a declared duration that under-runs
  /// the real audio.
  var duration: CMTime? { get }
  var timePitchAlgorithm: AVAudioTimePitchAlgorithm { get set }
  /// How far ahead of the playhead AVFoundation should keep buffering, in seconds. `0` is its
  /// default: choose a window automatically. See `AVQueuePlayerAudioEngine.applyForwardBuffer`
  /// for why a streamed item overrides it.
  var preferredForwardBufferDuration: TimeInterval { get set }

  /// Fires once the item's status becomes `.readyToPlay`.
  var onReady: (@MainActor @Sendable () -> Void)? { get set }
  /// Fires once the item's status becomes `.failed`, with its error and the HTTP status its error
  /// log last recorded (`0` if none); a rejected request often yields only a generic media error,
  /// so the `401` is only there. See `AudioEngineFailure.init(assetLoadError:responseStatusCode:)`.
  var onFailed: (@MainActor @Sendable (Error, Int) -> Void)? { get set }
  /// Fires on `AVPlayerItemFailedToPlayToEndTime`: AVFoundation giving up mid-play, which `status`
  /// may not report as `.failed`. Carries the notification's error (or
  /// `AudioEngineAdapterError.unknownPlaybackFailure`) and the error log's HTTP status, as
  /// `onFailed` does.
  var onFailedToPlayToEnd: (@MainActor @Sendable (Error, Int) -> Void)? { get set }
  /// Fires on `AVPlayerItemDidPlayToEndTime` for this item.
  var onDidPlayToEnd: (@MainActor @Sendable () -> Void)? { get set }
  /// Fires whenever the item's duration resolves or is revised, carrying it in seconds. An
  /// indefinite or invalid duration is never forwarded.
  var onDurationChanged: (@MainActor @Sendable (Double) -> Void)? { get set }

  /// Seeks the item. `toleranceBefore`/`toleranceAfter` bound how far AVFoundation may snap
  /// from the requested time; pass `.zero`/`.zero` for a sample-accurate landing (an audiobook
  /// scrub must land where the finger released).
  func seek(
    to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
    completion: @escaping @MainActor @Sendable (Bool) -> Void)

  /// Loads the item's audio track and makes a Voice Boost tap from `processor` its audio mix.
  /// Never blocks: the mix lands later on the main actor. Only the first call does anything, and
  /// nothing lands after `cancelAudioProcessorAttach()` or a failure.
  func attachAudioProcessor(_ processor: VoiceBoostTapFactory)
  /// The engine has let go of this item: an attach still loading its track must not land.
  func cancelAudioProcessorAttach()
}

/// Builds a fresh `AudioPlayerItemHandle` for a resolved stream URL. A protocol (rather than a
/// free function) purely so tests can inject a fake that never touches `AVURLAsset`/`AVPlayerItem`.
@MainActor
protocol AudioPlayerItemFactory {
  /// The caller that owns credentialed access has already stamped the headers (a direct-play
  /// authorization header, empty for a local file); a conformance forwards them, never mints one.
  /// `mimeType` is authoritative: AVFoundation needs it for local files with an ambiguous suffix.
  func makeItem(resource: PlaybackTrackResource) -> AudioPlayerItemHandle
  /// An item over a composition the engine was handed ready-made, so nothing here loads. The
  /// handle keeps the source `resource`, and `trim` is the map the composition was cut by.
  func makeItem(
    resource: PlaybackTrackResource, preparedAsset: AVAsset, trim: PlayerTrimMap
  ) -> AudioPlayerItemHandle
}

/// Errors surfaced from `RealAudioPlayerItemHandle` when `AVPlayerItem.error` is nil at a
/// `.failed` status transition (AVFoundation permits this in principle even though it is rare in
/// practice).
enum AudioEngineAdapterError: Error {
  case unknownPlaybackFailure
}

// MARK: - Production conformances

/// Production `AudioPlayerItemFactory`: builds a real `AVURLAsset`/`AVPlayerItem` pair.
/// ARCHITECTURE.md §2 rule 5 allows only stream resources returned inside a successfully created
/// playback session's `audioTracks[]`. The URL is resolved and handed in by the caller
/// (`AVQueuePlayerAudioEngine.configure(tracks:)`); this factory never mints one.
@MainActor
final class AVFoundationPlayerItemFactory: AudioPlayerItemFactory {
  /// The key AVFoundation reads per-asset request headers from (no public symbol): the only
  /// supported way to authorise an `AVURLAsset` short of an `AVAssetResourceLoaderDelegate`. Direct
  /// play needs it, as `/api/items/{id}/file/{ino}` answers `401` (API-CONVENTIONS.md rule 6a).
  private nonisolated static let httpHeaderFieldsOptionKey = "AVURLAssetHTTPHeaderFieldsKey"

  nonisolated static func assetOptions(headers: [String: String], mimeType: String?) -> [String: Any] {
    var options: [String: Any] = [:]
    if headers.isEmpty == false {
      options[Self.httpHeaderFieldsOptionKey] = headers
    }
    let baseMIMEType =
      mimeType?
      .split(separator: ";").first
      .map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let baseMIMEType, baseMIMEType.isEmpty == false {
      options[AVURLAssetOverrideMIMETypeKey] = baseMIMEType
    }
    return options
  }

  func makeItem(resource: PlaybackTrackResource) -> AudioPlayerItemHandle {
    #if DEBUG
      let source = resource.url.isFileURL ? "local" : "stream"
      let fileExists = resource.url.isFileURL && FileManager.default.fileExists(atPath: resource.url.path)
      let fileSize =
        (try? resource.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        ?? -1
      DeviceTraceLog.emit(
        "WHIRRENG item source=\(source) track=\(resource.trackIndex) ext=\(resource.url.pathExtension) "
          + "exists=\(fileExists ? 1 : 0) bytes=\(Int64(fileSize)) headerCount=\(resource.headers.count) "
          + "mime=\(resource.mimeType ?? "-")")
    #endif
    let options = Self.assetOptions(headers: resource.headers, mimeType: resource.mimeType)
    let asset = AVURLAsset(url: resource.url, options: options)
    let item = AVPlayerItem(asset: asset)
    return RealAudioPlayerItemHandle(item: item, resource: resource)
  }

  func makeItem(
    resource: PlaybackTrackResource, preparedAsset: AVAsset, trim: PlayerTrimMap
  ) -> AudioPlayerItemHandle {
    RealAudioPlayerItemHandle(
      item: AVPlayerItem(asset: preparedAsset), resource: resource, trim: trim)
  }
}

/// Real `AudioPlayerItemHandle`: owns the KVO/notification observation an `AVPlayerItem` needs and
/// translates it into the plain callbacks the adapter consumes. Observation tokens are torn down
/// in `deinit`; callers drop their reference (via `load`'s replace path or `stop`) once an item is
/// no longer wanted, which is what releases them.
@MainActor
final class RealAudioPlayerItemHandle: NSObject, AudioPlayerItemHandle {
  let resource: PlaybackTrackResource
  let item: AVPlayerItem
  let trim: PlayerTrimMap?
  var trackIndex: Int { resource.trackIndex }
  var url: URL { resource.url }
  private(set) var isUnusable = false
  /// Whether this item's asset was built with any HTTP header fields, i.e. whether the request
  /// carried a credential at all. A bool, never the header value or the URL, since sanitisation
  /// keeps both out of the trace. This is the redacted marker for that question.
  private let isCredentialled: Bool

  var onReady: (@MainActor @Sendable () -> Void)?
  var onFailed: (@MainActor @Sendable (Error, Int) -> Void)?
  var onFailedToPlayToEnd: (@MainActor @Sendable (Error, Int) -> Void)?
  var onDidPlayToEnd: (@MainActor @Sendable () -> Void)?
  var onDurationChanged: (@MainActor @Sendable (Double) -> Void)?

  private var statusObservation: NSKeyValueObservation?
  private var hasAudioProcessorAttach = false
  private var isAudioProcessorAttachCancelled = false
  private var durationObservation: NSKeyValueObservation?
  private var endObserver: NSObjectProtocol?
  private var failedToEndObserver: NSObjectProtocol?

  var isReady: Bool { item.status == .readyToPlay }

  var duration: CMTime? {
    let value = item.duration
    return value.isValid && !value.isIndefinite ? value : nil
  }

  var timePitchAlgorithm: AVAudioTimePitchAlgorithm {
    get { item.audioTimePitchAlgorithm }
    set { item.audioTimePitchAlgorithm = newValue }
  }

  var preferredForwardBufferDuration: TimeInterval {
    get { item.preferredForwardBufferDuration }
    set { item.preferredForwardBufferDuration = newValue }
  }

  init(item: AVPlayerItem, resource: PlaybackTrackResource, trim: PlayerTrimMap? = nil) {
    self.item = item
    self.resource = resource
    self.trim = trim
    self.isCredentialled = resource.headers.isEmpty == false
    super.init()

    // KVO/NotificationCenter callbacks are typed `@Sendable` by the modern AVFoundation overlay
    // (they can in principle fire off-main), even though AVPlayerItem/AVQueuePlayer are
    // documented main-actor types in practice. Each hop back goes through `Task { @MainActor in }`
    // before touching any `self` state, rather than assuming the calling thread.
    statusObservation = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
      let status = observedItem.status
      let error = observedItem.error
      Task { @MainActor [weak self] in
        guard let self else { return }
        switch status {
        case .readyToPlay:
          self.onReady?()
        case .failed:
          self.isUnusable = true
          let statusCode = observedItem.errorLog()?.events.last?.errorStatusCode ?? 0
          #if DEBUG
            // The `.failed` event carries only a generic `localizedDescription`. The error log
            // names the request, telling a direct-play `401` from a transcode-shaped `404`; it is
            // credential-free (no token in a stream URL) and the query is dropped anyway.
            let event = observedItem.errorLog()?.events.last
            let resolvedError = error ?? AudioEngineAdapterError.unknownPlaybackFailure
            DeviceTraceLog.emit(
              Self.failureTraceMessage(
                isLocal: self.url.isFileURL,
                isCredentialled: self.isCredentialled,
                path: event?.uri.flatMap { URLComponents(string: $0)?.percentEncodedPath },
                statusCode: event?.errorStatusCode ?? 0,
                error: resolvedError,
                hasErrorComment: event?.errorComment != nil))
          #endif
          self.onFailed?(error ?? AudioEngineAdapterError.unknownPlaybackFailure, statusCode)
        case .unknown:
          break
        @unknown default:
          break
        }
      }
    }

    // Separate from `\.status`: a progressively loaded stream reaches `readyToPlay` with an
    // indefinite duration and resolves it later, so the ready transition alone would miss it.
    durationObservation = item.observe(\.duration, options: [.new]) { [weak self] observedItem, _ in
      let duration = observedItem.duration
      guard duration.isValid, duration.isIndefinite == false else { return }
      let seconds = CMTimeGetSeconds(duration)
      guard seconds.isFinite, seconds > 0 else { return }
      Task { @MainActor [weak self] in
        self?.onDurationChanged?(seconds)
      }
    }

    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.onDidPlayToEnd?()
      }
    }

    failedToEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
    ) { [weak self] notification in
      let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.isUnusable = true
        let statusCode = self.item.errorLog()?.events.last?.errorStatusCode ?? 0
        let resolvedError = error ?? AudioEngineAdapterError.unknownPlaybackFailure
        #if DEBUG
          // Keep this aligned with the status path: the error log contributes only validated
          // fields, and `errorComment` is recorded as a presence bit rather than free text.
          let event = self.item.errorLog()?.events.last
          DeviceTraceLog.emit(
            Self.failureTraceMessage(
              isLocal: self.url.isFileURL,
              isCredentialled: self.isCredentialled,
              path: event?.uri.flatMap { URLComponents(string: $0)?.percentEncodedPath },
              statusCode: event?.errorStatusCode ?? 0,
              error: resolvedError,
              hasErrorComment: event?.errorComment != nil))
        #endif
        self.onFailedToPlayToEnd?(resolvedError, statusCode)
      }
    }
  }

  /// Builds the `WHIRRENG failure` trace from fixed validated fields only. `errorComment` is
  /// server/framework-controlled free text, so only its presence is recorded. DeviceTraceLog
  /// messages are public on device, and no unbounded foreign string may enter one (SECURITY.md
  /// §Logging). Error values contribute domain/code, never their descriptions.
  nonisolated static func failureTraceMessage(
    isLocal: Bool,
    isCredentialled: Bool,
    path: String?,
    statusCode: Int,
    error: Error,
    hasErrorComment: Bool
  ) -> String {
    let nsError = error as NSError
    let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
    return "WHIRRENG failure source=\(isLocal ? "local" : "stream") "
      + "credentialled=\(isCredentialled ? 1 : 0) path=\(path ?? "-") "
      + "status=\(statusCode) domain=\(nsError.domain) "
      + "code=\(nsError.code) underlyingDomain=\(underlying?.domain ?? "-") "
      + "underlyingCode=\(underlying?.code ?? 0) commentPresent=\(hasErrorComment ? 1 : 0)"
  }

  func seek(
    to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime,
    completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    Task { @MainActor [weak item] in
      guard let item else { return }
      let finished = await item.seek(
        to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter)
      completion(finished)
    }
  }

  func attachAudioProcessor(_ processor: VoiceBoostTapFactory) {
    guard !hasAudioProcessorAttach, !isAudioProcessorAttachCancelled, !isUnusable else { return }
    hasAudioProcessorAttach = true
    let asset = item.asset
    Task { @MainActor [weak self] in
      let track = (try? await asset.loadTracks(withMediaType: .audio))?.first
      guard let self, !self.isAudioProcessorAttachCancelled, !self.isUnusable else { return }
      guard let track, let tap = processor.makeTap() else {
        #if DEBUG
          DeviceTraceLog.emit(
            "WHIRRENG voiceboost attach-failed track=\(self.trackIndex) hasAudioTrack=\(track == nil ? 0 : 1)")
        #endif
        return
      }
      let parameters = AVMutableAudioMixInputParameters(track: track)
      parameters.audioTapProcessor = tap
      let mix = AVMutableAudioMix()
      mix.inputParameters = [parameters]
      self.item.audioMix = mix
      #if DEBUG
        DeviceTraceLog.emit(
          "WHIRRENG voiceboost attach track=\(self.trackIndex) source=\(self.url.isFileURL ? "local" : "stream")")
      #endif
    }
  }

  func cancelAudioProcessorAttach() {
    isAudioProcessorAttachCancelled = true
  }

  deinit {
    statusObservation?.invalidate()
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    if let failedToEndObserver {
      NotificationCenter.default.removeObserver(failedToEndObserver)
    }
  }
}

/// Real `AudioQueuePlayerControlling`, wrapping an actual `AVQueuePlayer`. Keeps a side table from
/// real `AVPlayerItem` identity back to the `RealAudioPlayerItemHandle` that wraps it, since
/// `AVQueuePlayer.items()` only ever returns bare `AVPlayerItem`s.
@MainActor
final class RealAudioQueuePlayer: NSObject, AudioQueuePlayerControlling {
  private let player: AVQueuePlayer
  private var handlesByItem: [ObjectIdentifier: RealAudioPlayerItemHandle] = [:]
  private var timeControlObservation: NSKeyValueObservation?

  var onBufferingStateChanged: (@MainActor @Sendable (Bool) -> Void)?

  var rate: Float {
    get { player.rate }
    set { player.rate = newValue }
  }

  var volume: Float {
    get { player.volume }
    set { player.volume = newValue }
  }

  init(player: AVQueuePlayer = AVQueuePlayer()) {
    self.player = player
    super.init()
    timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
      let isWaiting = observedPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate
      Task { @MainActor [weak self] in
        self?.onBufferingStateChanged?(isWaiting)
      }
    }
  }

  func items() -> [AudioPlayerItemHandle] {
    player.items().compactMap { handlesByItem[ObjectIdentifier($0)] }
  }

  func insert(_ item: AudioPlayerItemHandle, after afterItem: AudioPlayerItemHandle?) {
    guard let real = item as? RealAudioPlayerItemHandle else { return }
    handlesByItem[ObjectIdentifier(real.item)] = real
    let afterReal = (afterItem as? RealAudioPlayerItemHandle)?.item
    player.insert(real.item, after: afterReal)
  }

  func remove(_ item: AudioPlayerItemHandle) {
    guard let real = item as? RealAudioPlayerItemHandle else { return }
    player.remove(real.item)
    handlesByItem.removeValue(forKey: ObjectIdentifier(real.item))
  }

  func removeAllItems() {
    player.removeAllItems()
    handlesByItem.removeAll()
  }

  func play() { player.play() }
  func pause() { player.pause() }

  func addPeriodicTimeObserver(
    forInterval interval: CMTime, using block: @escaping @MainActor @Sendable (CMTime) -> Void
  ) -> Any {
    player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
      // AVPlayer is explicitly delivering this callback on the main serial queue. Calling through
      // in that same turn preserves callback order and avoids building a second queue of
      // unstructured main-actor tasks that can replay stale positions after pause/resume.
      MainActor.assumeIsolated {
        block(time)
      }
    }
  }

  func addBoundaryTimeObserver(
    forTimes times: [CMTime], using block: @escaping @MainActor @Sendable (CMTime) -> Void
  ) -> Any {
    player.addBoundaryTimeObserver(forTimes: times.map { NSValue(time: $0) }, queue: .main) {
      [weak self] in
      // Delivered on the main queue, as the periodic observer is; the boundary callback carries no
      // time of its own, so the player's is read in the same turn. It can read a hair short of
      // the boundary it crossed, which would miss a range starting exactly there.
      MainActor.assumeIsolated {
        guard let self else { return }
        let current = self.player.currentTime()
        let crossed = times.filter { $0 <= current + CMTime(value: 1, timescale: 10) }.max()
        block(crossed.map { CMTimeMaximum($0, current) } ?? current)
      }
    }
  }

  func removeTimeObserver(_ observer: Any) {
    player.removeTimeObserver(observer)
  }

  deinit {
    timeControlObservation?.invalidate()
  }
}
