import AVFoundation

/// What the player's route control draws for wherever audio is actually going.
///
/// Only `portType` and `portName` are public: the type picks the glyph family, the name refines it
/// best-effort (a renamed accessory falls back to the family glyph).
nonisolated enum AudioRoutePresentation {
  /// One output port of the current route, reduced to the two facts the control draws from.
  /// Taken as a value so the mapping below is testable without an audio session.
  struct Output: Equatable {
    let portType: AVAudioSession.Port
    let name: String
  }

  struct Display: Sendable, Equatable {
    let symbol: String
    /// The line drawn beneath the glyph, nil when there is nothing to report: the device's own
    /// speaker is no chosen destination, and a generic port name ("Headphones") under a glyph that
    /// says the same is redundant.
    let label: String?
    /// Always spoken, including the two cases `label` leaves blank.
    let spokenRoute: String
  }

  /// The AirPlay glyph, drawn when audio is on this device: the control then means "send this
  /// somewhere", which the mark depicts. Also the fallback for an unknown port type, since an
  /// honest "tap to choose" beats a guessed device.
  static let localSymbol = "airplayaudio"

  static let localSpokenRoute = "This device"

  static func display(for outputs: [Output]) -> Display {
    Display(
      symbol: symbol(for: outputs),
      label: label(for: outputs),
      spokenRoute: spokenRoute(for: outputs))
  }

  @MainActor
  static func currentDisplay(audioSession: AVAudioSession = .sharedInstance()) -> Display {
    display(
      for: audioSession.currentRoute.outputs.map {
        Output(portType: $0.portType, name: $0.portName)
      })
  }

  // MARK: - Symbol

  static func symbol(for outputs: [Output]) -> String {
    guard let primary = outputs.first else { return localSymbol }
    // A grouped AirPlay route is several speakers playing as one. Any single speaker's glyph would
    // under-report it, and the label already spells out which rooms.
    if primary.portType == .airPlay, distinctNames(in: outputs).count > 1 {
      return "hifispeaker.2.fill"
    }
    return symbol(for: primary)
  }

  static func symbol(for output: Output) -> String {
    switch output.portType {
    case .builtInSpeaker, .builtInReceiver:
      return localSymbol
    // Wired and Bluetooth headsets share a branch: AirPods Max plugged in over a cable arrive as
    // `.headphones`, and the same accessory should not change glyph with its connection.
    case .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
      return appleAccessorySymbol(named: output.name) ?? "headphones"
    case .airPlay:
      return airPlaySymbol(named: output.name)
    case .carAudio:
      return "car.fill"
    case .HDMI, .displayPort:
      return "display"
    // Digital wired outputs. A USB or Thunderbolt accessory can be anything from an interface to a
    // headset, so the name gets first refusal and the connector is the fallback.
    case .usbAudio, .lineOut, .thunderbolt, .fireWire, .PCI, .AVB, .virtual:
      return appleAccessorySymbol(named: output.name) ?? "cable.connector"
    default:
      return localSymbol
    }
  }

  /// Apple accessory families that have their own SF Symbol, matched against the device name.
  ///
  /// Name matching is the only route (no public model API), ordered most specific first ("AirPods
  /// Pro 3" must reach `airpods.pro`). nil leaves the caller's family glyph; a renamed pair reads
  /// as generic headphones.
  static func appleAccessorySymbol(named name: String) -> String? {
    let name = name.lowercased()
    if name.contains("airpods max") { return "airpods.max" }
    if name.contains("airpods pro") { return "airpods.pro" }
    // The generation-less glyph: the name does not distinguish 2nd from 4th, and a wrong
    // generation is more conspicuous than a plain pair of AirPods.
    if name.contains("airpods") { return "airpods" }
    if name.contains("beats") || name.contains("powerbeats") {
      let inEar = ["buds", "powerbeats", "fit pro"].contains { name.contains($0) }
      return inEar ? "beats.earphones" : "beats.headphones"
    }
    if name.contains("homepod") { return "homepod.fill" }
    return nil
  }

  /// An AirPlay destination is a room, not a port: the name is all there is. A HomePod renamed
  /// "Kitchen" is indistinguishable from any other speaker, so the generic speaker is the floor.
  static func airPlaySymbol(named name: String) -> String {
    let name = name.lowercased()
    if name.contains("homepod") { return "homepod.fill" }
    if name.contains("apple tv") { return "appletv.fill" }
    // Whole words, so "Living Room TV" matches and a name merely containing the letters does not.
    let words = name.split { $0.isLetter == false && $0.isNumber == false }
    if words.contains("tv") { return "appletv.fill" }
    return "hifispeaker.fill"
  }

  // MARK: - Text

  static func label(for outputs: [Output]) -> String? {
    guard isLocal(outputs) == false else { return nil }
    let names = distinctNames(in: outputs)
    return names.isEmpty ? nil : names.joined(separator: " + ")
  }

  static func spokenRoute(for outputs: [Output]) -> String {
    if let label = label(for: outputs) { return label }
    // Everything `label` suppresses is still spoken. A port named only by its own type
    // ("Headphones") is a good spoken answer even though it is redundant on screen.
    guard let primary = outputs.first, isLocal(primary.portType) == false else {
      return localSpokenRoute
    }
    let name = primary.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? localSpokenRoute : name
  }

  // MARK: - Route shape

  static func isLocal(_ outputs: [Output]) -> Bool {
    guard let primary = outputs.first else { return true }
    return isLocal(primary.portType)
  }

  static func isLocal(_ portType: AVAudioSession.Port) -> Bool {
    portType == .builtInSpeaker || portType == .builtInReceiver
  }

  /// Named devices in route order. `currentRoute.outputs` normally holds one port, but a grouped
  /// AirPlay route holds several. Empty and repeated names are dropped, as is a name that is only
  /// the port type's own identifier (`AVAudioSessionPortHeadphones` is the string "Headphones",
  /// which iOS returns verbatim as the "device name" of a wired headset).
  static func distinctNames(in outputs: [Output]) -> [String] {
    var seen: Set<String> = []
    return outputs.compactMap { output in
      let name = output.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard name.isEmpty == false,
        name.compare(output.portType.rawValue, options: .caseInsensitive) != .orderedSame,
        seen.insert(name).inserted
      else { return nil }
      return name
    }
  }
}
