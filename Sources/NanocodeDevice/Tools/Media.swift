#if os(iOS)
import Foundation
import MediaPlayer
import Nanocode

extension DeviceKit {
  static let musicActions = ["search", "albums", "artists", "playlists", "podcasts", "audiobooks", "play", "queue_next", "queue_last", "pause", "resume",
                             "stop", "next", "previous", "restart", "seek", "shuffle", "repeat", "now_playing"]

  static let music = HostTool(
    name: "music",
    description: "The media library on this \(DeviceTools.here) (music, podcasts and audiobooks synced or added from Apple Music) and the Music app's player. search: songs whose title, artist or album matches. albums, artists, playlists, podcasts, audiobooks list collections (filtered by query). play: songs that match a query, or a playlist, album or artist by name, or items by id (shuffle optional). queue_next and queue_last add to the queue. pause, resume, stop, next, previous, restart, seek (seconds), shuffle (off, songs, albums), repeat (none, one, all), now_playing (with position and state). The system volume can't be set by apps.",
    parameters: schema(musicActions, paged([
      "query": prop("string"),
      "playlist": prop("string", "For play: a playlist's name."),
      "album": prop("string", "For play: an album's title."),
      "artist": prop("string", "For play: an artist's name."),
      "ids": list(prop("string"), "For play and queue: item ids from search."),
      "shuffle": prop("boolean", "For play: shuffle what plays."),
      "mode": prop("string", "For shuffle: off, songs or albums. For repeat: none, one or all."),
      "seconds": prop("number", "For seek: the position in seconds."),
    ]))
  ) { call in try await library(call.input) }

  static func library(_ input: JSON) async throws -> ToolResult {
    try await DeviceTools.gate("music")
    let query = text(input, "query") ?? ""
    switch input["action"]?.string {
    case "search": return .json(try page(songs(query).map(describe), input, 25, most: 10_000))
    case "albums": return .json(try page(collections(.albums(), MPMediaItemPropertyAlbumTitle, query).map { collection($0, MPMediaItemPropertyAlbumTitle) }, input, 50, most: 10_000))
    case "artists": return .json(try page(collections(.artists(), MPMediaItemPropertyArtist, query).map { collection($0, MPMediaItemPropertyArtist) }, input, 50, most: 10_000))
    case "podcasts": return .json(try page(collections(.podcasts(), MPMediaItemPropertyPodcastTitle, query).map { collection($0, MPMediaItemPropertyPodcastTitle) }, input, 50, most: 10_000))
    case "audiobooks": return .json(try page(collections(.audiobooks(), MPMediaItemPropertyAlbumTitle, query).map { collection($0, MPMediaItemPropertyAlbumTitle) }, input, 50, most: 10_000))
    case "playlists":
      let found = (MPMediaQuery.playlists().collections ?? []).filter { list in
        query.isEmpty || (list.value(forProperty: MPMediaPlaylistPropertyName) as? String ?? "").localizedCaseInsensitiveContains(query)
      }
      return .json(try page(found.map { list in
        ["id": .string(String(list.persistentID)), "name": .string(list.value(forProperty: MPMediaPlaylistPropertyName) as? String ?? ""),
         "items": .number(Double(list.count))]
      }, input, 50, most: 10_000))
    case "play":
      let items = try selection(input)
      let shuffle = input["shuffle"]?.bool ?? false
      return .json(await play(items, shuffle: shuffle))
    case "queue_next", "queue_last":
      let items = try selection(input)
      let count = items.count
      let first = input["action"]?.string == "queue_next"
      let collection = MPMediaItemCollection(items: items)
      await MainActor.run { [collection] in
        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(itemCollection: collection)
        if first { MPMusicPlayerController.systemMusicPlayer.prepend(descriptor) } else { MPMusicPlayerController.systemMusicPlayer.append(descriptor) }
      }
      return .text("Queued \(count) \(count == 1 ? "item" : "items").")
    case "pause", "resume", "stop", "next", "previous", "restart", "seek", "shuffle", "repeat":
      return .json(try await control(input))
    case "now_playing":
      return .json(await MainActor.run { playing() })
    default:
      throw unknown("music", musicActions)
    }
  }

  static func selection(_ input: JSON) throws -> [MPMediaItem] {
    let ids = texts(input, "ids").compactMap(UInt64.init)
    if !ids.isEmpty {
      let found = ids.compactMap { id -> MPMediaItem? in
        let one = MPMediaQuery()
        one.addFilterPredicate(MPMediaPropertyPredicate(value: NSNumber(value: id), forProperty: MPMediaItemPropertyPersistentID))
        return one.items?.first
      }
      guard !found.isEmpty else { throw NanocodeError("no item has those ids") }
      return found
    }
    if let name = text(input, "playlist") {
      let query = MPMediaQuery.playlists()
      query.addFilterPredicate(MPMediaPropertyPredicate(value: name, forProperty: MPMediaPlaylistPropertyName, comparisonType: .contains))
      guard let list = query.collections?.first else { throw NanocodeError("no playlist is called \(name)") }
      return list.items
    }
    for (key, property) in [("album", MPMediaItemPropertyAlbumTitle), ("artist", MPMediaItemPropertyArtist)] {
      guard let name = text(input, key) else { continue }
      let query = MPMediaQuery.songs()
      query.addFilterPredicate(MPMediaPropertyPredicate(value: name, forProperty: property, comparisonType: .contains))
      let items = query.items ?? []
      guard !items.isEmpty else { throw NanocodeError("no \(key) matches \(name)") }
      return items
    }
    let found = songs(text(input, "query") ?? "")
    guard !found.isEmpty else { throw NanocodeError("nothing in the library matches that") }
    return found
  }

  static func songs(_ text: String) -> [MPMediaItem] {
    var seen = Set<MPMediaEntityPersistentID>()
    return [MPMediaItemPropertyTitle, MPMediaItemPropertyArtist, MPMediaItemPropertyAlbumTitle].flatMap { property in
      let query = MPMediaQuery.songs()
      if !text.isEmpty { query.addFilterPredicate(MPMediaPropertyPredicate(value: text, forProperty: property, comparisonType: .contains)) }
      return query.items ?? []
    }.filter { seen.insert($0.persistentID).inserted }
  }

  static func collections(_ query: MPMediaQuery, _ property: String, _ text: String) -> [MPMediaItemCollection] {
    if !text.isEmpty { query.addFilterPredicate(MPMediaPropertyPredicate(value: text, forProperty: property, comparisonType: .contains)) }
    return query.collections ?? []
  }

  static func collection(_ group: MPMediaItemCollection, _ property: String) -> JSON {
    let item = group.representativeItem
    return ["title": .string(item?.value(forProperty: property) as? String ?? ""), "artist": .string(item?.albumArtist ?? item?.artist ?? ""),
            "items": .number(Double(group.count)), "ids": .array(group.items.prefix(500).map { .string(String($0.persistentID)) })]
  }

  static func describe(_ item: MPMediaItem) -> JSON {
    var object: [String: JSON] = [
      "id": .string(String(item.persistentID)), "title": .string(item.title ?? ""), "artist": .string(item.artist ?? ""),
      "album": .string(item.albumTitle ?? ""), "seconds": .number(item.playbackDuration.rounded()), "plays": .number(Double(item.playCount)),
    ]
    if let genre = item.genre { object["genre"] = .string(genre) }
    if let date = item.releaseDate { object["released"] = DeviceTools.stamp(date) }
    if item.rating > 0 { object["rating"] = .number(Double(item.rating)) }
    if item.isCloudItem { object["cloud"] = .bool(true) }
    return .object(object)
  }

  @MainActor static func play(_ items: [MPMediaItem], shuffle: Bool) -> JSON {
    let player = MPMusicPlayerController.systemMusicPlayer
    player.setQueue(with: MPMediaItemCollection(items: items))
    player.shuffleMode = shuffle ? .songs : .off
    player.play()
    return playing()
  }

  @MainActor static func playing() -> JSON {
    let player = MPMusicPlayerController.systemMusicPlayer
    let state = switch player.playbackState {
    case .playing: "playing"
    case .paused: "paused"
    case .stopped: "stopped"
    case .interrupted: "interrupted"
    case .seekingForward, .seekingBackward: "seeking"
    @unknown default: "unknown"
    }
    var object: [String: JSON] = ["state": .string(state), "position_seconds": .number(player.currentPlaybackTime.isFinite ? player.currentPlaybackTime.rounded() : 0)]
    if let item = player.nowPlayingItem { object["item"] = describe(item) }
    object["shuffle"] = .string(player.shuffleMode == .songs ? "songs" : player.shuffleMode == .albums ? "albums" : "off")
    object["repeat"] = .string(player.repeatMode == .one ? "one" : player.repeatMode == .all ? "all" : "none")
    object["queue_index"] = .number(Double(player.indexOfNowPlayingItem))
    return .object(object)
  }

  static func control(_ input: JSON) async throws -> JSON {
    let action = input["action"]?.string ?? ""
    let mode = input["mode"]?.string
    let seconds = input["seconds"]?.number
    return try await MainActor.run {
      let player = MPMusicPlayerController.systemMusicPlayer
      switch action {
      case "pause": player.pause()
      case "resume": player.play()
      case "stop": player.stop()
      case "next": player.skipToNextItem()
      case "previous": player.skipToPreviousItem()
      case "restart": player.skipToBeginning()
      case "seek":
        guard let seconds, seconds >= 0 else { throw NanocodeError("seek takes seconds") }
        player.currentPlaybackTime = seconds
      case "shuffle":
        switch mode {
        case "off": player.shuffleMode = .off
        case "songs": player.shuffleMode = .songs
        case "albums": player.shuffleMode = .albums
        default: throw NanocodeError("shuffle mode is off, songs or albums")
        }
      default:
        switch mode {
        case "none": player.repeatMode = .none
        case "one": player.repeatMode = .one
        case "all": player.repeatMode = .all
        default: throw NanocodeError("repeat mode is none, one or all")
        }
      }
      return playing()
    }
  }
}
#endif
