// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import Foundation
import GoogleCast

/// One track packaged for the Cast Default Media Receiver.
///
/// The receiver fetches the audio itself, so it needs a URL that authenticates on
/// its own. Subsonic stream URLs carry their credentials as query parameters, which
/// is exactly that. Servers behind a reverse proxy that needs custom request headers
/// are the exception — see `PlayerService.castItem(for:)`.
///
/// This stays a plain value type: the SDK's own `GCKMediaInformation` is not Sendable,
/// so it is built by `makeMediaInformation()` at the point of use rather than stored
/// and carried across the player actor.
nonisolated struct CastMediaItem: Sendable {
    let songID: String
    let title: String
    let artist: String?
    let album: String?
    let streamURL: URL
    let artworkURL: URL?
    let duration: TimeInterval
    let contentType: String

    init(song: DisplayableSong, streamURL: URL, artworkURL: URL?) {
        self.songID = song.id
        self.title = song.title
        self.artist = song.artist
        self.album = song.albumName
        self.streamURL = streamURL
        self.artworkURL = artworkURL
        self.duration = song.duration
        self.contentType = Self.contentType(forFormat: song.audioFormat)
    }

    /// Builds the payload handed to `GCKRemoteMediaClient.loadMedia`.
    func makeMediaInformation() -> GCKMediaInformation {
        let metadata = GCKMediaMetadata(metadataType: .musicTrack)
        metadata.setString(title, forKey: kGCKMetadataKeyTitle)
        if let artist {
            metadata.setString(artist, forKey: kGCKMetadataKeyArtist)
        }
        if let album {
            metadata.setString(album, forKey: kGCKMetadataKeyAlbumTitle)
        }
        if let artworkURL {
            // The receiver shows this full-screen behind the track info.
            metadata.addImage(GCKImage(url: artworkURL, width: 600, height: 600))
        }

        let builder = GCKMediaInformationBuilder(contentURL: streamURL)
        builder.streamType = .buffered
        builder.contentType = contentType
        builder.metadata = metadata
        // A zero duration would tell the receiver the track is empty.
        if duration > 0 {
            builder.streamDuration = duration
        }
        return builder.build()
    }

    /// Whether a server reached with these request headers can be cast to at all.
    ///
    /// Casting hands the receiver a URL and lets it do the fetching, and the Cast SDK
    /// gives no way to attach headers to that fetch. A server behind a proxy that
    /// authenticates on headers is therefore unreachable from the speaker, however well
    /// it works on the phone. Subsonic's own credentials ride in the query string, so
    /// an ordinary server casts fine.
    static func isCastable(customHeaders: [String: String]) -> Bool {
        customHeaders.isEmpty
    }

    /// MIME type for the receiver, derived from the Subsonic file suffix.
    ///
    /// The Default Media Receiver plays MP3, AAC, FLAC, WAV and Ogg/Vorbis, and it
    /// dispatches on this string. Unknown suffixes fall back to `audio/mpeg`, which
    /// is right whenever the server transcodes, the common case for anything exotic.
    static func contentType(forFormat format: String?) -> String {
        switch format?.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "aac", "mp4": return "audio/mp4"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "ogg", "oga", "opus": return "audio/ogg"
        default: return "audio/mpeg"
        }
    }
}
#endif
