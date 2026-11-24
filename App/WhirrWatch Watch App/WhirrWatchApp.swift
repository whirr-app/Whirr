// Xcode's app-intents metadata extraction requires an explicit framework dependency.
import AppIntents
import SwiftUI
import WatchKit

@main
struct WhirrWatch_Watch_AppApp: App {
  @WKApplicationDelegateAdaptor(WatchBackgroundDelegate.self) private var delegate

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(delegate.store)
        .environment(delegate.artwork)
        .environment(delegate.library)
        .environment(delegate.library.audio)
        .onAppear {
          delegate.consumeCurrentContext()
        }
    }
  }
}
