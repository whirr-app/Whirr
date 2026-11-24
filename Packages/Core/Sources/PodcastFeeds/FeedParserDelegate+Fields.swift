import Foundation

/// The field tables: which element, under which parent, feeds which text field, and how a
/// finished element's text is recorded. First-wins is enforced here through the `seen` flags.
extension FeedParserDelegate {
  enum TextField {
    case channelTitle
    case author
    case synopsis
    case imageURL
    case language
    case guid
    case itemTitle
    case pubDate
    case duration
    case itemSynopsis
    case itemContent
    case seasonNumber
    case episodeNumber
    case atomFeedTitle
    case atomAuthor
    case atomLogo
    case atomIcon
    case atomSynopsis
    case atomGuid
    case atomTitle
    case atomPublished
    case atomUpdated
    case atomItemSynopsis
  }

  func fieldForStart(parent: Frame?, localName: String, namespaceURI: String) -> TextField? {
    guard let parent else { return nil }
    if rootKind == .atom {
      if matches(parent, namespaceURI: Self.atomNamespace, localName: "feed") {
        if namespaceURI == Self.atomNamespace, localName == "title", channelTitleSeen == false {
          return .atomFeedTitle
        }
        if namespaceURI == Self.atomNamespace, localName == "author", atomAuthorSeen == false {
          return nil
        }
        if namespaceURI == Self.atomNamespace, localName == "logo", atomLogoSeen == false {
          return .atomLogo
        }
        if namespaceURI == Self.atomNamespace, localName == "icon", atomIconSeen == false {
          return .atomIcon
        }
        if namespaceURI == Self.atomNamespace, localName == "subtitle", synopsisSeen == false {
          return .atomSynopsis
        }
      }
      if matches(parent, namespaceURI: Self.atomNamespace, localName: "author"),
        frames.count >= 2,
        matches(frames[frames.count - 2], namespaceURI: Self.atomNamespace, localName: "feed"),
        namespaceURI == Self.atomNamespace, localName == "name", atomAuthorSeen == false
      {
        return .atomAuthor
      }
      if currentItem != nil, matches(parent, namespaceURI: Self.atomNamespace, localName: "entry") {
        if namespaceURI == Self.atomNamespace, localName == "id", currentItem?.seenGuid == false {
          return .atomGuid
        }
        if namespaceURI == Self.atomNamespace, localName == "title", currentItem?.seenTitle == false {
          return .atomTitle
        }
        if namespaceURI == Self.atomNamespace, localName == "published", atomPublishedSeen == false {
          return .atomPublished
        }
        if namespaceURI == Self.atomNamespace, localName == "updated", atomUpdatedSeen == false {
          return .atomUpdated
        }
        if namespaceURI == Self.iTunesNamespace, localName == "duration", currentItem?.seenDuration == false {
          return .duration
        }
        if namespaceURI == Self.atomNamespace, localName == "summary", currentItem?.seenSynopsis == false {
          return .atomItemSynopsis
        }
        if namespaceURI == Self.iTunesNamespace, localName == "season", currentItem?.seenSeasonNumber == false {
          return .seasonNumber
        }
        if namespaceURI == Self.iTunesNamespace, localName == "episode", currentItem?.seenEpisodeNumber == false {
          return .episodeNumber
        }
      }
      return nil
    }
    if matches(parent, namespaceURI: "", localName: "channel") {
      if namespaceURI.isEmpty, localName == "title", channelTitleSeen == false {
        return .channelTitle
      }
      if namespaceURI == Self.iTunesNamespace, localName == "author", authorSeen == false {
        return .author
      }
      if namespaceURI == Self.iTunesNamespace, localName == "summary", synopsisSeen == false {
        return .synopsis
      }
      if namespaceURI.isEmpty, localName == "description", synopsisSeen == false {
        return .synopsis
      }
      if namespaceURI.isEmpty, localName == "language", languageSeen == false {
        return .language
      }
    }
    if matches(parent, namespaceURI: "", localName: "image"), frames.count >= 2,
      matches(frames[frames.count - 2], namespaceURI: "", localName: "channel"),
      namespaceURI.isEmpty, localName == "url", imageURLSeen == false
    {
      return .imageURL
    }
    if currentItem != nil, matches(parent, namespaceURI: "", localName: "item") {
      if namespaceURI.isEmpty, localName == "guid", currentItem?.seenGuid == false {
        return .guid
      }
      if namespaceURI.isEmpty, localName == "title", currentItem?.seenTitle == false {
        return .itemTitle
      }
      if namespaceURI.isEmpty, localName == "pubDate", currentItem?.seenPubDate == false {
        return .pubDate
      }
      if namespaceURI == Self.iTunesNamespace, localName == "duration", currentItem?.seenDuration == false {
        return .duration
      }
      if namespaceURI.isEmpty && localName == "description"
        || namespaceURI == Self.iTunesNamespace && localName == "summary", currentItem?.seenSynopsis == false
      {
        return .itemSynopsis
      }
      if namespaceURI == Self.contentNamespace, localName == "encoded", currentItem?.seenContent == false {
        return .itemContent
      }
      if namespaceURI == Self.iTunesNamespace, localName == "season", currentItem?.seenSeasonNumber == false {
        return .seasonNumber
      }
      if namespaceURI == Self.iTunesNamespace, localName == "episode", currentItem?.seenEpisodeNumber == false {
        return .episodeNumber
      }
    }
    return nil
  }

  func recordText(_ value: String?, overflowed: Bool, for field: TextField?) {
    switch field {
    case .channelTitle:
      channelTitleSeen = true
      channelTitle = value
    case .author:
      authorSeen = true
      author = value
    case .synopsis:
      synopsisSeen = true
      synopsis = value
    case .imageURL:
      imageURLSeen = true
      imageURL = validHTTPURL(value)
    case .language:
      languageSeen = true
      language =
        overflowed
        ? nil
        : value.flatMap {
          $0.utf8.count <= ParsedFeed.maximumLanguageBytes ? $0 : nil
        }
    case .guid:
      currentItem?.seenGuid = true
      currentItem?.guid = value
    case .itemTitle:
      currentItem?.seenTitle = true
      currentItem?.title = value
    case .pubDate:
      currentItem?.seenPubDate = true
      currentItem?.pubDate = value
    case .duration:
      currentItem?.seenDuration = true
      currentItem?.durationText = value
    case .itemSynopsis, .atomItemSynopsis:
      currentItem?.seenSynopsis = true
      currentItem?.synopsis = overflowed ? nil : value
    case .itemContent:
      currentItem?.seenContent = true
      currentItem?.content = overflowed ? nil : value
    case .seasonNumber:
      currentItem?.seenSeasonNumber = true
      currentItem?.seasonNumber = value.flatMap { Int($0, radix: 10) }.flatMap { $0 > 0 ? $0 : nil }
    case .episodeNumber:
      currentItem?.seenEpisodeNumber = true
      currentItem?.episodeNumber = value.flatMap { Int($0, radix: 10) }.flatMap { $0 > 0 ? $0 : nil }
    case .atomFeedTitle:
      channelTitleSeen = true
      channelTitle = value
    case .atomAuthor:
      atomAuthorSeen = true
      author = value
    case .atomLogo:
      atomLogoSeen = true
      if let url = validHTTPURL(value) { artworkURL = url }
    case .atomIcon:
      atomIconSeen = true
      let iconURL = validHTTPURL(value)
      if artworkURL == nil { artworkURL = iconURL }
    case .atomSynopsis:
      synopsisSeen = true
      synopsis = value
    case .atomGuid:
      currentItem?.seenGuid = true
      currentItem?.guid = value
    case .atomTitle:
      currentItem?.seenTitle = true
      currentItem?.title = value
    case .atomPublished:
      if value != nil {
        atomPublishedSeen = true
        currentItem?.seenPubDate = true
        currentItem?.pubDate = value
      }
    case .atomUpdated:
      if atomPublishedSeen == false, atomUpdatedSeen == false {
        atomUpdatedSeen = true
        currentItem?.seenPubDate = true
        currentItem?.pubDate = value
      }
    case nil:
      break
    }
  }
}
