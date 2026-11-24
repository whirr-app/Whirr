import ABSApi
import AVFoundation
import MediaPlayer
import PlayerCore
import SyncEngine

@testable import Whirr

/// Test double for `NowPlayingInfoSink`. An in-memory stand-in for
/// `MPNowPlayingInfoCenter.default()` that counts writes, so tests can assert publishing happens
/// only at semantic boundaries, not on every progress tick.
@MainActor
final class FakeNowPlayingInfoSink: NowPlayingInfoSink {
  var nowPlayingInfo: [String: Any]? {
    didSet { writeCount += 1 }
  }
  private(set) var writeCount = 0
}
