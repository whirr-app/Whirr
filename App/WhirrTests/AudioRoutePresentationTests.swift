import AVFoundation
import Testing

@testable import Whirr

/// The route control says where audio is going. Every case here is one iOS can actually produce.
/// The port types come from `AVAudioSessionTypes.h`, and the names are the ones the system returns.
/// A wired headset's device name really is "Headphones".
@Suite("Audio route presentation")
struct AudioRoutePresentationTests {

  private func display(_ outputs: [(AVAudioSession.Port, String)])
    -> AudioRoutePresentation.Display
  {
    AudioRoutePresentation.display(
      for: outputs.map { AudioRoutePresentation.Output(portType: $0.0, name: $0.1) })
  }

  /// This replaces a defect where the built-in speaker was drawn as a named destination. The row
  /// read "Speaker" under an AirPlay mark, a setting the listener never chose, stated as though
  /// they had.
  @Test("audio on this device names no destination")
  func localRouteNamesNoDestination() {
    let speaker = display([(.builtInSpeaker, "Speaker")])
    #expect(speaker.symbol == "airplayaudio")
    #expect(speaker.label == nil)
    #expect(speaker.spokenRoute == "This device")

    let receiver = display([(.builtInReceiver, "Receiver")])
    #expect(receiver.label == nil)
    #expect(receiver.symbol == "airplayaudio")

    // No active session yet. Same answer, not a blank control.
    let none = display([])
    #expect(none.symbol == "airplayaudio")
    #expect(none.label == nil)
    #expect(none.spokenRoute == "This device")
  }

  @Test("an Apple accessory is drawn as itself")
  func appleAccessoriesAreDrawnAsThemselves() {
    #expect(display([(.bluetoothA2DP, "Rhys's AirPods Pro 3")]).symbol == "airpods.pro")
    #expect(display([(.bluetoothA2DP, "Rhys's AirPods Max")]).symbol == "airpods.max")
    #expect(display([(.bluetoothA2DP, "Rhys's AirPods")]).symbol == "airpods")
    #expect(display([(.bluetoothA2DP, "Beats Studio Pro")]).symbol == "beats.headphones")
    #expect(display([(.bluetoothA2DP, "Beats Studio Buds")]).symbol == "beats.earphones")
  }

  /// Order matters, not just membership. "AirPods Pro 3" contains "airpods", so a mapping that
  /// tested the family first would draw every Pro as a plain pair.
  @Test("a more specific accessory name wins")
  func specificAccessoryNamesWin() {
    #expect(AudioRoutePresentation.appleAccessorySymbol(named: "AirPods Pro") == "airpods.pro")
    #expect(AudioRoutePresentation.appleAccessorySymbol(named: "AirPods Max") == "airpods.max")
    #expect(AudioRoutePresentation.appleAccessorySymbol(named: "Kitchen Speaker") == nil)
  }

  /// The named device is the label. The same accessory keeps its glyph over a cable: AirPods Max
  /// plugged in arrive as `.headphones`, not as a Bluetooth port.
  @Test("a named device is reported by name whatever it is connected by")
  func namedDeviceIsReportedByName() {
    let wireless = display([(.bluetoothA2DP, "Rhys's AirPods Max")])
    #expect(wireless.label == "Rhys's AirPods Max")
    #expect(wireless.spokenRoute == "Rhys's AirPods Max")

    let wired = display([(.headphones, "Rhys's AirPods Max")])
    #expect(wired.symbol == wireless.symbol)
    #expect(wired.label == "Rhys's AirPods Max")
  }

  /// iOS names a wired headset after its own port type. Drawing "Headphones" under the headphones
  /// glyph repeats the same word, so the line stays blank. VoiceOver has no glyph, so it still gets
  /// the name.
  @Test("a port named after its own type is not a device name")
  func portTypeNameIsNotADeviceName() {
    let headphones = display([(.headphones, "Headphones")])
    #expect(headphones.symbol == "headphones")
    #expect(headphones.label == nil)
    #expect(headphones.spokenRoute == "Headphones")
  }

  @Test("an unrecognised Bluetooth device is still a headset")
  func unrecognisedBluetoothIsAHeadset() {
    let renamed = display([(.bluetoothA2DP, "Buds")])
    #expect(renamed.symbol == "headphones")
    #expect(renamed.label == "Buds")
  }

  @Test("AirPlay destinations are drawn by what they are")
  func airPlayDestinationsAreDrawnByKind() {
    #expect(display([(.airPlay, "Living Room TV")]).symbol == "appletv.fill")
    #expect(display([(.airPlay, "Apple TV")]).symbol == "appletv.fill")
    #expect(display([(.airPlay, "Kitchen HomePod")]).symbol == "homepod.fill")
    #expect(display([(.airPlay, "Living Room")]).symbol == "hifispeaker.fill")
  }

  /// "TV" is matched as a word, not as two letters. Otherwise a speaker called "Portvale" becomes
  /// an Apple TV.
  @Test("a device name only matches TV as a whole word")
  func tvMatchesAsAWholeWord() {
    #expect(AudioRoutePresentation.airPlaySymbol(named: "Portvale") == "hifispeaker.fill")
    #expect(AudioRoutePresentation.airPlaySymbol(named: "TV") == "appletv.fill")
  }

  @Test("a grouped AirPlay route reports every room")
  func groupedAirPlayReportsEveryRoom() {
    let grouped = display([(.airPlay, "Living Room"), (.airPlay, "Kitchen")])
    #expect(grouped.symbol == "hifispeaker.2.fill")
    #expect(grouped.label == "Living Room + Kitchen")
    #expect(grouped.spokenRoute == "Living Room + Kitchen")
  }

  @Test("empty and duplicate output names are dropped")
  func emptyAndDuplicateNamesAreDropped() {
    #expect(display([(.airPlay, "Living Room"), (.airPlay, "Living Room")]).label == "Living Room")
    #expect(display([(.airPlay, "Living Room"), (.airPlay, "   ")]).label == "Living Room")
    // Every name dropped: nothing to draw, and the glyph is still the route's own.
    let unnamed = display([(.airPlay, "  ")])
    #expect(unnamed.label == nil)
    #expect(unnamed.symbol == "hifispeaker.fill")
  }

  @Test("wired and vehicle routes carry their own marks")
  func wiredAndVehicleRoutesCarryTheirOwnMarks() {
    #expect(display([(.carAudio, "Golf")]).symbol == "car.fill")
    #expect(display([(.HDMI, "HDMI")]).symbol == "display")
    #expect(display([(.usbAudio, "Scarlett 2i2")]).symbol == "cable.connector")
    #expect(display([(.AVB, "Rig")]).symbol == "cable.connector")
    // An unknown port type falls back to "tap to choose", not to a guess.
    #expect(display([(.builtInMic, "iPhone Microphone")]).symbol == "airplayaudio")
  }
}
