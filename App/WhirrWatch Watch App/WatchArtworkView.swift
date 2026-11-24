import SwiftUI
import UIKit
import WatchProtocol

struct WatchArtworkView: View {
  @Environment(WatchArtworkStore.self) private var artwork
  let selection: WatchSelection
  var size: CGFloat = 44
  var accountStamp: WatchAccountStamp? = nil
  var phoneCatalogueStamp: WatchAccountStamp? = nil
  var backdrop = false
  @State private var image: UIImage?
  @State private var loadedIdentity: Identity?

  private struct Identity: Hashable {
    let key: WatchArtworkStore.Key?
    let generation: Int
    let revision: Int
  }
  private var identity: Identity {
    let key = artwork.key(
      selection: selection, size: backdrop || size > 60 ? .player : .row,
      accountStamp: accountStamp, phoneCatalogueStamp: phoneCatalogueStamp)
    return Identity(key: key, generation: artwork.generation, revision: artwork.revision(for: key))
  }
  private var isPodcast: Bool {
    switch selection {
    case .nativeFeed: true
    case .audiobookshelf(_, let episode): episode != nil
    }
  }
  var body: some View {
    Group {
      if backdrop {
        artworkContent
          .overlay(.black.opacity(0.64))
          .clipped()
      } else {
        artworkContent
          .frame(width: size, height: size)
          .clipShape(RoundedRectangle(cornerRadius: size > 60 ? 12 : 7))
      }
    }
    .accessibilityHidden(true)
    .task(id: identity) {
      let request = identity
      guard let key = request.key else {
        image = nil
        loadedIdentity = nil
        return
      }
      let next = await artwork.image(for: key, backdrop: backdrop)
      guard !Task.isCancelled, request == identity else { return }
      image = next
      loadedIdentity = request
    }
  }

  private var artworkContent: some View {
    ZStack {
      (isPodcast ? WatchVisualStyle.podcasts : WatchVisualStyle.primaryFill).opacity(backdrop ? 0.4 : 0.8)
      if loadedIdentity == identity, let image {
        if backdrop {
          Image(uiImage: image).resizable().interpolation(.high).scaledToFill()
        } else {
          // Fit preserves lettering on non-square book covers; the colour fills any letterboxing.
          Image(uiImage: image).resizable().scaledToFit()
        }
      } else if !backdrop {
        Image(systemName: isPodcast ? "mic.fill" : "book.closed.fill")
          .font(.system(size: size * 0.4)).foregroundStyle(.white.opacity(0.9))
      }
    }
  }
}
