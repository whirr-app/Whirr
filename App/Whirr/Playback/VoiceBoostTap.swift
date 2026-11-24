import AVFoundation
import CoreSupport
import MediaToolbox
import Synchronization

/// The switch and counters every tap from one `VoiceBoostTapFactory` shares. It lives behind a
/// pointer the factory owns, so the render thread reads it without touching a reference count.
nonisolated struct VoiceBoostSharedState: ~Copyable {
  let isEnabled = Atomic<Bool>(false)
  /// Frames the taps have been handed, processed or not: proof that a tap runs at all.
  let framesRendered = Atomic<Int>(0)
  /// `prepare` calls given a format the chain does not process, plus render calls whose buffer
  /// list did not match the prepared format. Each one plays the source audio untouched.
  let formatBypasses = Atomic<Int>(0)
}

/// Makes the `MTAudioProcessingTap` that runs `VoiceBoostDSP` on one player item, and holds the
/// one switch all of its taps follow.
///
/// A tap retains the factory into its storage until finalized, so the shared state outlives every
/// tap that reads it, whatever order AVFoundation releases things in.
nonisolated final class VoiceBoostTapFactory: @unchecked Sendable {
  // Unchecked: `shared` is written only through its atomics, and the rest is immutable.
  private let shared: UnsafeMutablePointer<VoiceBoostSharedState>
  let stages: VoiceBoostStages
  let parameters: VoiceBoostParameters

  init(stages: VoiceBoostStages = .all, parameters: VoiceBoostParameters = .standard) {
    self.stages = stages
    self.parameters = parameters
    shared = .allocate(capacity: 1)
    shared.initialize(to: VoiceBoostSharedState())
  }

  deinit {
    shared.deinitialize(count: 1)
    shared.deallocate()
  }

  /// Whether every tap from this factory processes. Flipping it ramps; it never clicks.
  var isEnabled: Bool {
    get { shared.pointee.isEnabled.load(ordering: .acquiring) }
    set { shared.pointee.isEnabled.store(newValue, ordering: .releasing) }
  }

  var framesRendered: Int { shared.pointee.framesRendered.load(ordering: .relaxed) }
  var formatBypasses: Int { shared.pointee.formatBypasses.load(ordering: .relaxed) }

  /// A new tap for one item's audio track, in the `PreEffects` position so it sees source-rate
  /// audio at every playback speed. `nil` only if MediaToolbox refuses to create one.
  func makeTap() -> MTAudioProcessingTap? {
    let storage = makeStorage()
    var callbacks = MTAudioProcessingTapCallbacks(
      version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: UnsafeMutableRawPointer(storage),
      init: { _, clientInfo, storageOut in
        storageOut.pointee = clientInfo
      },
      finalize: { tap in
        VoiceBoostTapFactory.releaseStorage(VoiceBoostTapFactory.storage(of: tap))
      },
      prepare: { tap, maxFrames, format in
        VoiceBoostTapFactory.storage(of: tap).pointee.prepare(format: format.pointee, maxFrames: maxFrames)
      },
      unprepare: { tap in
        VoiceBoostTapFactory.storage(of: tap).pointee.unprepare()
      },
      process: { tap, frameCount, _, buffers, frameCountOut, flagsOut in
        let status = MTAudioProcessingTapGetSourceAudio(tap, frameCount, buffers, flagsOut, nil, frameCountOut)
        guard status == noErr else { return }
        VoiceBoostTapFactory.storage(of: tap).pointee.render(buffers, frameCount: frameCountOut.pointee)
      })
    var tap: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(
      kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
    guard status == noErr, let tap else {
      // Creation failed, so `init` never ran and `finalize` never will: the storage is still ours.
      Self.releaseStorage(storage)
      return nil
    }
    return tap
  }

  // MARK: - Storage

  /// A tap's storage, owning one retain of this factory. Internal so tests can drive the render
  /// path without a player; production storage is created only by `makeTap`.
  func makeStorage() -> UnsafeMutablePointer<VoiceBoostTapState> {
    let storage = UnsafeMutablePointer<VoiceBoostTapState>.allocate(capacity: 1)
    storage.initialize(
      to: VoiceBoostTapState(
        owner: Unmanaged.passRetained(self), shared: shared, stages: stages, parameters: parameters))
    return storage
  }

  /// Frees a tap's processor, its storage, and its retain of the factory.
  static func releaseStorage(_ storage: UnsafeMutablePointer<VoiceBoostTapState>) {
    storage.pointee.unprepare()
    let owner = storage.pointee.owner
    storage.deinitialize(count: 1)
    storage.deallocate()
    owner.release()
  }

  private static func storage(of tap: MTAudioProcessingTap) -> UnsafeMutablePointer<VoiceBoostTapState> {
    MTAudioProcessingTapGetStorage(tap).assumingMemoryBound(to: VoiceBoostTapState.self)
  }
}

/// One tap's state. `prepare` and `unprepare` may allocate; `render` runs on the render thread and
/// must not allocate, lock, log, touch a class reference or hop to an actor. Everything it reaches
/// is a raw pointer or a value.
nonisolated struct VoiceBoostTapState: ~Copyable {
  /// Retained by `makeStorage`, released by `releaseStorage`. Never read on the render thread.
  let owner: Unmanaged<VoiceBoostTapFactory>
  private let shared: UnsafeMutablePointer<VoiceBoostSharedState>
  private let stages: VoiceBoostStages
  private let parameters: VoiceBoostParameters
  /// `nil` before `prepare`, after `unprepare`, and when the format is bypassed.
  private var processor: UnsafeMutablePointer<VoiceBoostDSP>?
  /// One buffer pointer per channel, refilled from the buffer list on every render.
  private var channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>>?

  init(
    owner: Unmanaged<VoiceBoostTapFactory>, shared: UnsafeMutablePointer<VoiceBoostSharedState>,
    stages: VoiceBoostStages, parameters: VoiceBoostParameters
  ) {
    self.owner = owner
    self.shared = shared
    self.stages = stages
    self.parameters = parameters
  }

  var isProcessing: Bool { processor != nil }

  /// Float32, native-endian, non-interleaved linear PCM: the only format the chain processes. The
  /// system chooses the format, and its header says the client must cope with whatever it gets.
  static func isSupported(_ format: AudioStreamBasicDescription) -> Bool {
    let flags = format.mFormatFlags
    return format.mFormatID == kAudioFormatLinearPCM
      && flags & kAudioFormatFlagIsFloat != 0
      && flags & kAudioFormatFlagIsNonInterleaved != 0
      && flags & kAudioFormatFlagIsBigEndian == 0
      && format.mBitsPerChannel == 32
      && format.mChannelsPerFrame > 0
      && format.mSampleRate > 0
  }

  /// Builds a fresh processor for `format`, or leaves the tap in pass-through when the format is
  /// not one the chain handles. Starts from cleared state every time, however often it is called.
  mutating func prepare(format: AudioStreamBasicDescription, maxFrames: Int) {
    unprepare()
    let channelCount = Int(format.mChannelsPerFrame)
    guard Self.isSupported(format),
      let dsp = VoiceBoostDSP(
        sampleRate: format.mSampleRate, channelCount: channelCount, maxFrames: max(maxFrames, 1),
        stages: stages, parameters: parameters)
    else {
      shared.pointee.formatBypasses.add(1, ordering: .relaxed)
      #if DEBUG
        DeviceTraceLog.emit(Self.traceMessage("bypass", format: format))
      #endif
      return
    }
    let processor = UnsafeMutablePointer<VoiceBoostDSP>.allocate(capacity: 1)
    processor.initialize(to: dsp)
    self.processor = processor
    // Left uninitialized: `render` initializes every slot before the processor reads one.
    channels = .allocate(capacity: channelCount)
    #if DEBUG
      DeviceTraceLog.emit(Self.traceMessage("prepare", format: format))
    #endif
  }

  /// Frees what `prepare` built. Safe to call more than once.
  mutating func unprepare() {
    if let processor {
      processor.deinitialize(count: 1)
      processor.deallocate()
      self.processor = nil
    }
    if let channels {
      channels.deallocate()
      self.channels = nil
    }
  }

  /// Runs the chain over the source audio already fetched into `buffers`. Render thread.
  mutating func render(_ buffers: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
    guard frameCount > 0 else { return }
    shared.pointee.framesRendered.add(frameCount, ordering: .relaxed)
    guard let processor, let channels else { return }
    let list = UnsafeMutableAudioBufferListPointer(buffers)
    let channelCount = processor.pointee.channelCount
    guard list.count == channelCount else {
      shared.pointee.formatBypasses.add(1, ordering: .relaxed)
      return
    }
    for index in 0..<channelCount {
      guard let data = list[index].mData,
        Int(list[index].mDataByteSize) >= frameCount * MemoryLayout<Float>.size
      else {
        shared.pointee.formatBypasses.add(1, ordering: .relaxed)
        return
      }
      (channels + index).initialize(to: data.assumingMemoryBound(to: Float.self))
    }
    processor.pointee.isEnabled = shared.pointee.isEnabled.load(ordering: .relaxed)
    processor.pointee.process(UnsafePointer(channels), frameCount: frameCount)
  }

  #if DEBUG
    private static func traceMessage(_ event: String, format: AudioStreamBasicDescription) -> String {
      "WHIRRENG voiceboost \(event) rate=\(Int(format.mSampleRate)) channels=\(format.mChannelsPerFrame) "
        + "bits=\(format.mBitsPerChannel) flags=\(format.mFormatFlags)"
    }
  #endif
}
