import PlayerCore

/// Where the time Whirr saved the listener came from, against playing the original at 1×.
public enum TimeSavedSource: String, Sendable, CaseIterable {
  /// Skipped ad ranges, at their full joined length.
  case ads
  /// Source seconds Trim Silences cut.
  case silence
  /// Listening above 1×; listening below it saves nothing.
  case speed
}

/// What the listener has saved, by source, in seconds. Each figure is at least zero.
public struct TimeSavedTotals: Sendable, Equatable {
  public var ads: Double
  public var silence: Double
  public var speed: Double

  public static let zero = TimeSavedTotals(ads: 0, silence: 0, speed: 0)

  public init(ads: Double, silence: Double, speed: Double) {
    self.ads = ads
    self.silence = silence
    self.speed = speed
  }

  public var total: Double { ads + silence + speed }

  public subscript(source: TimeSavedSource) -> Double {
    get {
      switch source {
      case .ads: ads
      case .silence: silence
      case .speed: speed
      }
    }
    set {
      switch source {
      case .ads: ads = newValue
      case .silence: silence = newValue
      case .speed: speed = newValue
      }
    }
  }

  public static func + (lhs: TimeSavedTotals, rhs: TimeSavedTotals) -> TimeSavedTotals {
    TimeSavedTotals(
      ads: lhs.ads + rhs.ads, silence: lhs.silence + rhs.silence, speed: lhs.speed + rhs.speed)
  }
}

/// The per-device running totals of time saved. The App store keeps them in memory and writes them
/// only when `flush` is called, because every defaults write costs an iCloud settings pass.
@MainActor
public protocol TimeSavedRecording: AnyObject, Sendable {
  /// Adds `seconds` to a source's total. Undo passes a negative length.
  func add(_ seconds: Double, to source: TimeSavedSource)
  /// Writes the totals out. Called when playback pauses or ends and when the item unloads.
  func flush()
}

extension PlaybackModel {

  /// Records an ingested event's speed and silence savings, and writes the totals out when
  /// playback stops moving.
  internal func noteTimeSaved(in event: PlaybackProgressEvent) {
    guard let timeSaved else { return }
    if event.speedSavedDelta > 0 { timeSaved.add(event.speedSavedDelta, to: .speed) }
    if event.trimmedSourceDelta > 0 { timeSaved.add(event.trimmedSourceDelta, to: .silence) }
    switch event.phase {
    case .paused, .ended, .idle, .failed: timeSaved.flush()
    default: break
    }
  }

  /// The listening a skip avoided: the whole joined range, cut short at the item's end for a range
  /// that ends it. The duration is an estimate, so that clamp can be slightly off either way.
  internal func adSeconds(of range: PlayerSkipRange) -> Double {
    var end = range.end
    if range.endsItem, let item = player.state.item, item.id == loadedItemID {
      end = min(end, item.timeline.totalDuration)
    }
    let length = end - range.start
    return length.isFinite ? max(0, length) : 0
  }
}
