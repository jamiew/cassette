// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import Foundation
import GoogleCast
import Testing
@testable import Cassette

@Suite("CastMediaItem.contentType")
struct CastMediaItemContentTypeTests {
    @Test func mapsTheFormatsTheReceiverPlaysNatively() {
        #expect(CastMediaItem.contentType(forFormat: "mp3") == "audio/mpeg")
        #expect(CastMediaItem.contentType(forFormat: "flac") == "audio/flac")
        #expect(CastMediaItem.contentType(forFormat: "m4a") == "audio/mp4")
        #expect(CastMediaItem.contentType(forFormat: "wav") == "audio/wav")
        #expect(CastMediaItem.contentType(forFormat: "ogg") == "audio/ogg")
    }

    /// Subsonic reports the suffix upper-cased, so matching has to be case-insensitive.
    @Test func matchesRegardlessOfCase() {
        #expect(CastMediaItem.contentType(forFormat: "FLAC") == "audio/flac")
    }

    /// An unknown or missing suffix means the server is almost certainly transcoding,
    /// and Subsonic transcodes to MP3 by default.
    @Test func fallsBackToMpegForUnknownFormats() {
        #expect(CastMediaItem.contentType(forFormat: nil) == "audio/mpeg")
        #expect(CastMediaItem.contentType(forFormat: "aiff") == "audio/mpeg")
    }
}

@Suite("CastMediaItem")
struct CastMediaItemTests {
    private func song(format: String?, coverArtId: String? = "cover-1") -> DisplayableSong {
        DisplayableSong(
            id: "song-1", title: "Blue Monday", artist: "New Order", albumId: "album-1",
            albumName: "Power, Corruption & Lies", artistId: "artist-1", genre: nil,
            duration: 442, trackNumber: 1, isDownloaded: false, coverArtId: coverArtId,
            audioFormat: format, replayGainTrackGain: nil, replayGainTrackPeak: nil,
            replayGainAlbumGain: nil, replayGainAlbumPeak: nil,
            replayGainBaseGain: nil, replayGainFallbackGain: nil
        )
    }

    private let streamURL = URL(string: "https://music.example.com/rest/stream.view?id=song-1&u=me&t=abc&s=xyz")!

    @Test func carriesTheStreamURLAndDurationToTheReceiver() {
        let info = CastMediaItem(song: song(format: "FLAC"), streamURL: streamURL, artworkURL: nil)
            .makeMediaInformation()
        #expect(info.contentURL == streamURL)
        #expect(info.contentType == "audio/flac")
        #expect(info.streamDuration == 442)
        // Songs are seekable; only radio is a live stream, and radio is never cast.
        #expect(info.streamType == .buffered)
    }

    @Test func populatesTheMetadataTheReceiverDisplays() throws {
        let info = CastMediaItem(song: song(format: "mp3"), streamURL: streamURL, artworkURL: nil)
            .makeMediaInformation()
        let metadata = try #require(info.metadata)
        #expect(metadata.string(forKey: kGCKMetadataKeyTitle) == "Blue Monday")
        #expect(metadata.string(forKey: kGCKMetadataKeyArtist) == "New Order")
        #expect(metadata.string(forKey: kGCKMetadataKeyAlbumTitle) == "Power, Corruption & Lies")
        #expect(metadata.images().isEmpty)
    }

    @Test func attachesArtworkWhenTheServerHasSome() throws {
        let artwork = URL(string: "https://music.example.com/rest/getCoverArt.view?id=cover-1")!
        let info = CastMediaItem(song: song(format: "mp3"), streamURL: streamURL, artworkURL: artwork)
            .makeMediaInformation()
        let images = try #require(info.metadata?.images() as? [GCKImage])
        #expect(images.count == 1)
        #expect(images.first?.url == artwork)
    }

    /// A zero duration would tell the receiver the track is empty, so it is left unset.
    @Test func omitsDurationWhenTheServerDidNotReportOne() {
        let unknown = DisplayableSong(
            id: "song-2", title: "Untitled", artist: nil, albumId: nil, albumName: nil,
            artistId: nil, genre: nil, duration: 0, trackNumber: nil, isDownloaded: false,
            coverArtId: nil, audioFormat: "mp3", replayGainTrackGain: nil,
            replayGainTrackPeak: nil, replayGainAlbumGain: nil, replayGainAlbumPeak: nil,
            replayGainBaseGain: nil, replayGainFallbackGain: nil
        )
        let info = CastMediaItem(song: unknown, streamURL: streamURL, artworkURL: nil)
            .makeMediaInformation()
        #expect(info.streamDuration == 0)
    }
}
#endif
