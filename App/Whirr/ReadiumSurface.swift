import ReaderCore
import SwiftUI

struct ReadiumSurface: View {
  let renderer: any EPUBRendering

  var body: some View {
    Group {
      if let readium = renderer as? ReadiumEPUBRenderer {
        ReadiumEPUBRendererView(renderer: readium)
      } else {
        ZStack {
          Color.clear
          Text("EPUB rendering surface")
            .accessibilityLabel("Simulated EPUB page")
        }
      }
    }
    .ignoresSafeArea(edges: .all)
    .accessibilityElement(children: .contain)
  }
}
