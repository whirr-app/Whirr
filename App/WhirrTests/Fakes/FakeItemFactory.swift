import ABSApi
import AVFoundation
import MediaPlayer
import PlayerCore
import SyncEngine

@testable import Whirr

/// Test double for `AudioPlayerItemFactory`. Records every item it is asked to build, in order,
/// so tests can drive the fakes it hands back.
@MainActor
final class FakeItemFactory: AudioPlayerItemFactory {
  private(set) var madeItems: [FakePlayerItemHandle] = []
  /// Parallel to `madeItems`: the headers each item was asked to be fetched with. A real
  /// `AVURLAsset` folds them into its options, so this is the only place a test can see that a
  /// streamed track carried its Bearer header and a local one carried none.
  private(set) var madeHeaders: [[String: String]] = []
  private(set) var madeMIMETypes: [String?] = []
  /// Stamped onto every item this factory builds. The adapter creates and seeks an item within one
  /// `load` call, so a test holding that seek open must set this before the call.
  var deferSeekCompletions = false
  /// Stamped onto every item this factory builds: see `FakePlayerItemHandle.holdsAttach`.
  var holdsAttach = false

  func makeItem(
    resource: PlaybackTrackResource, preparedAsset: AVAsset, trim: PlayerTrimMap
  ) -> AudioPlayerItemHandle {
    record(FakePlayerItemHandle(resource: resource, preparedAsset: preparedAsset, trim: trim))
  }

  func makeItem(resource: PlaybackTrackResource) -> AudioPlayerItemHandle {
    record(FakePlayerItemHandle(resource: resource))
  }

  private func record(_ handle: FakePlayerItemHandle) -> FakePlayerItemHandle {
    let resource = handle.resource
    handle.deferSeekCompletions = deferSeekCompletions
    handle.holdsAttach = holdsAttach
    madeItems.append(handle)
    madeHeaders.append(resource.headers)
    madeMIMETypes.append(resource.mimeType)
    return handle
  }
}
