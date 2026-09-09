// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import Foundation
import GoogleCast
import Testing
@testable import Cassette

/// The receiver→player mapping, which is where casting is most likely to break the queue
/// and least likely to be caught by hand: reproducing a mid-load idle or a TV-remote pause
/// on real hardware is largely a matter of timing luck.
@Suite("CastManager.event")
struct CastStatusEventTests {
    private func event(
        _ state: GCKMediaPlayerState,
        idleReason: GCKMediaPlayerIdleReason = .none,
        awaitingLoad: Bool = false,
        playingRemotely: Bool = false
    ) -> CastStatusEvent {
        CastManager.event(
            for: state,
            idleReason: idleReason,
            isAwaitingLoad: awaitingLoad,
            isPlayingRemotely: playingRemotely
        )
    }

    // MARK: - Starting to play

    /// Buffering and loading count as playing: the receiver passes through them on its way
    /// to audio, and waiting for `.playing` leaves the UI showing paused over live sound.
    @Test func treatsBufferingAndLoadingAsPlaying() {
        #expect(event(.playing) == .startedPlaying)
        #expect(event(.buffering) == .startedPlaying)
        #expect(event(.loading) == .startedPlaying)
    }

    /// The receiver repeats its status every few seconds. Re-reporting a state the player
    /// already holds would restart the progress timer on every beat.
    @Test func ignoresRepeatsOfAStateAlreadyKnown() {
        #expect(event(.playing, playingRemotely: true) == .ignore)
        #expect(event(.buffering, playingRemotely: true) == .ignore)
        #expect(event(.paused, playingRemotely: false) == .ignore)
    }

    // MARK: - Pausing

    /// Someone pressing pause on the TV remote has to reach the player, or the phone keeps
    /// showing playing and the progress bar runs on over silence.
    @Test func reportsAPauseMadeOnTheReceiver() {
        #expect(event(.paused, playingRemotely: true) == .paused)
    }

    // MARK: - Finishing

    @Test func advancesTheQueueWhenTheTrackGenuinelyEnds() {
        #expect(event(.idle, idleReason: .finished, playingRemotely: true) == .finished)
    }

    /// The important one. A freshly loaded track reports idle before it buffers, so without
    /// the guard the player would treat the start of every track as the end of it and skip
    /// through the whole queue.
    @Test func doesNotAdvanceOnTheIdleThatPrecedesAFreshLoad() {
        #expect(event(.idle, idleReason: .finished, awaitingLoad: true) == .ignore)
        #expect(event(.idle, idleReason: .none, awaitingLoad: true) == .ignore)
    }

    /// Idle for any other reason is not the end of a track. Interrupted means something
    /// replaced the media and cancelled means a stop, neither of which should silently
    /// pull the next track.
    @Test func onlyFinishedAdvancesTheQueue() {
        #expect(event(.idle, idleReason: .interrupted, playingRemotely: true) == .ignore)
        #expect(event(.idle, idleReason: .cancelled, playingRemotely: true) == .ignore)
        #expect(event(.idle, idleReason: .none, playingRemotely: true) == .ignore)
    }

    // MARK: - Failing

    /// The receiver fetches the audio itself, so a server it cannot reach fails there and
    /// nowhere else. Treating that as "nothing happened" is what makes a cast session look
    /// connected while the play button does nothing at all.
    @Test func reportsAnItemTheReceiverCouldNotPlay() {
        #expect(event(.idle, idleReason: .error, playingRemotely: true) == .failed)
        #expect(event(.idle, idleReason: .error) == .failed)
    }

    /// A load that fails still fails while the load is outstanding — that is when a bad
    /// stream URL shows up, before the receiver has ever reported playing.
    @Test func reportsAFailureDuringAnOutstandingLoad() {
        #expect(event(.idle, idleReason: .error, awaitingLoad: true) == .failed)
    }

    // MARK: - Everything else

    @Test func ignoresStatesThatSayNothingAboutPlayback() {
        #expect(event(.unknown) == .ignore)
    }

    /// The guard only governs idle. A load that reaches audio must still report it,
    /// otherwise the first track of a cast session would show as paused while playing.
    @Test func stillReportsPlaybackWhileALoadIsOutstanding() {
        #expect(event(.playing, awaitingLoad: true) == .startedPlaying)
        #expect(event(.buffering, awaitingLoad: true) == .startedPlaying)
    }
}

@Suite("CastMediaItem.isCastable")
struct CastMediaItemCastableTests {
    /// Subsonic credentials travel in the query string, which the receiver replays as-is.
    @Test func anOrdinaryServerCanBeCast() {
        #expect(CastMediaItem.isCastable(customHeaders: [:]))
    }

    /// The receiver does the fetching and the SDK cannot attach headers to it, so a
    /// header-authenticated proxy is unreachable from the speaker.
    @Test func aServerNeedingRequestHeadersCannotBeCast() {
        #expect(!CastMediaItem.isCastable(customHeaders: ["CF-Access-Client-Id": "abc"]))
        #expect(!CastMediaItem.isCastable(customHeaders: ["X-Auth": "t", "X-Other": "u"]))
    }
}

@Suite("CastMediaItem.isLikelyUnreachableByReceiver")
struct CastReceiverReachabilityTests {
    /// The case that cost an afternoon: a Tailscale name resolves on the phone through
    /// MagicDNS and nowhere else, so the speaker fails to fetch and says nothing.
    @Test func namesThatOnlyResolveOnTheSendersNetwork() {
        #expect(CastMediaItem.isLikelyUnreachableByReceiver(host: "navidrome.example.ts.net"))
        #expect(CastMediaItem.isLikelyUnreachableByReceiver(host: "MUSIC.EXAMPLE.TS.NET"))
        #expect(CastMediaItem.isLikelyUnreachableByReceiver(host: "nas.local"))
        #expect(CastMediaItem.isLikelyUnreachableByReceiver(host: "localhost"))
        #expect(CastMediaItem.isLikelyUnreachableByReceiver(host: "127.0.0.1"))
    }

    /// A LAN address is fine — the speaker is on that LAN too — and so is anything public.
    @Test func addressesAReceiverCanReach() {
        #expect(!CastMediaItem.isLikelyUnreachableByReceiver(host: "192.168.1.20"))
        #expect(!CastMediaItem.isLikelyUnreachableByReceiver(host: "music.example.com"))
        #expect(!CastMediaItem.isLikelyUnreachableByReceiver(host: "10.0.0.5"))
    }

    /// Only a hint for the error message, never a block: the same name published through
    /// Tailscale Funnel is public and casts fine, and the app must not refuse it.
    @Test func theHintNeverBlocksACast() {
        #expect(CastMediaItem.isCastable(customHeaders: [:]))
    }
}
#endif
