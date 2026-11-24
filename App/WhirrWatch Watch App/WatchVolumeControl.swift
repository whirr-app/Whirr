import AVFoundation
import Combine
import SwiftUI
import WatchKit

/// The volume glyph on Now Playing's artwork: hidden while the volume is idle, shown while it moves.
///
/// Hidden by opacity rather than removed, because the control must stay in the hierarchy to keep
/// the Digital Crown. Only the Watch's own output volume can be observed; the iPhone's is not sent
/// to the Watch, and the crown's turns go to the control rather than to SwiftUI, so while the phone
/// owns playback the glyph stays hidden and the crown still sets the phone's volume.
struct WatchVolumeGlyph: View {
  let origin: WatchVolumeControl.Origin
  let focused: Bool
  let side: CGFloat

  @State private var changes = 0
  @State private var shown = false

  var body: some View {
    WatchVolumeControl(origin: origin, focused: focused)
      .id(origin)
      .frame(width: side, height: side)
      .opacity(shown ? 1 : 0)
      .animation(.easeOut(duration: 0.3), value: shown)
      .onReceive(AVAudioSession.sharedInstance().publisher(for: \.outputVolume, options: [.new])) {
        _ in
        if origin == .watch { changes += 1 }
      }
      .task(id: changes) {
        guard changes > 0 else { return }
        shown = true
        try? await Task.sleep(for: .seconds(1.5))
        if !Task.isCancelled { shown = false }
      }
  }
}

/// The system volume glyph, which takes the Digital Crown while it has focus. Only a system
/// control can move output volume; `.companion` moves the iPhone's while the phone owns playback.
///
/// The origin is fixed when WatchKit creates the control, so callers key the view by its origin.
/// Focus is reasserted whenever `focused` changes because a presented sheet takes the crown for
/// its list, and dismissing it does not hand the crown back on its own.
struct WatchVolumeControl: WKInterfaceObjectRepresentable {
  enum Origin: Hashable { case watch, phone }

  let origin: Origin
  let focused: Bool

  func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
    let control = WKInterfaceVolumeControl(origin: origin == .watch ? .local : .companion)
    control.setTintColor(.white)
    return control
  }

  func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
    if focused { control.focus() } else { control.resignFocus() }
  }
}
