// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import Foundation
import GoogleCast
import Observation
import OSLog

/// Receiver-side playback events, delivered to PlayerService.
/// The Cast SDK owns transport while a session is live, so the player reacts to
/// these instead of driving the AudioStreaming engine.
protocol CastPlaybackDelegate: AnyObject, Sendable {
    /// A receiver session became active — hand local playback over.
    func castSessionDidStart() async
    /// The session ended. `position` is where the receiver stopped, so playback resumes there locally.
    func castSessionDidEnd(at position: TimeInterval, wasPlaying: Bool) async
    /// The receiver finished the loaded item — advance the queue.
    func castMediaDidFinish() async
    /// Play/pause changed on the receiver side, e.g. from a TV remote.
    func castPlaybackStateDidChange(isPlaying: Bool) async
}

/// Owns the Google Cast session and the receiver's media client.
///
/// Cassette keeps its own queue: only the current track is ever loaded on the
/// receiver, and `castMediaDidFinish` walks PlayerService to the next one. That
/// keeps shuffle, repeat, auto-extend, and scrobbling working unchanged.
@MainActor
@Observable
final class CastManager: NSObject {
    /// True while a receiver session is connected.
    private(set) var isCasting = false
    /// Friendly name of the connected receiver, for the "Casting on …" label.
    private(set) var deviceName: String?
    /// True while the receiver is playing (as opposed to paused or idle).
    private(set) var isPlayingRemotely = false

    @ObservationIgnored weak var delegate: (any CastPlaybackDelegate)?
    @ObservationIgnored private var sessionManager: GCKSessionManager?
    /// Suppresses the finish callback between `loadMedia` and the receiver's first
    /// playing status — a fresh load reports `.idle` before it buffers.
    @ObservationIgnored private var isAwaitingLoad = false

    private var remoteMediaClient: GCKRemoteMediaClient? {
        sessionManager?.currentCastSession?.remoteMediaClient
    }

    /// Where the receiver is in the current item. Read by the player's progress timer.
    var streamPosition: TimeInterval {
        remoteMediaClient?.approximateStreamPosition() ?? 0
    }

    /// Starts discovery and begins listening for sessions. Call once at launch.
    func configure() {
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        // Default is YES, which defers discovery until the cast button is tapped. That blocks the
        // SDK's automatic session resume on cold launch, which needs discovery running to re-find
        // the receiver, and makes GCKUICastButton hide itself based on Wi-Fi state.
        options.startDiscoveryAfterFirstTapOnCastButton = false
        options.suspendSessionsWhenBackgrounded = false
        GCKCastContext.setSharedInstanceWith(options)

        let manager = GCKCastContext.sharedInstance().sessionManager
        sessionManager = manager
        manager.add(self)
        Logger.cast.info("Cast configured — discovery running")
    }

    // MARK: - Transport

    /// Loads one track on the receiver. Cassette re-calls this for every track change.
    func load(_ item: CastMediaItem, at position: TimeInterval, autoplay: Bool) {
        guard let client = remoteMediaClient else {
            Logger.cast.warning("load ignored — no remote media client")
            return
        }
        isAwaitingLoad = true
        let options = GCKMediaLoadOptions()
        options.autoplay = autoplay
        options.playPosition = position
        client.loadMedia(item.makeMediaInformation(), with: options)
        isPlayingRemotely = autoplay
        Logger.cast.info("Loading '\(item.title, privacy: .public)' on receiver at \(position, format: .fixed(precision: 1))s")
    }

    func play() {
        remoteMediaClient?.play()
        isPlayingRemotely = true
    }

    func pause() {
        remoteMediaClient?.pause()
        isPlayingRemotely = false
    }

    func seek(to position: TimeInterval) {
        let options = GCKMediaSeekOptions()
        options.interval = position
        remoteMediaClient?.seek(with: options)
    }

    /// Stops the item on the receiver but keeps the session, so the user stays connected.
    func stopMedia() {
        remoteMediaClient?.stop()
        isPlayingRemotely = false
    }

    func setDeviceVolume(_ volume: Float) {
        sessionManager?.currentCastSession?.setDeviceVolume(max(0, min(1, volume)))
    }

    /// Ends the session and stops the receiver. A plain `endSession` leaves the TV playing.
    func endSession() {
        sessionManager?.endSessionAndStopCasting(true)
    }

    // MARK: - Session bookkeeping

    private func sessionBecameActive(_ session: GCKCastSession) {
        deviceName = session.device.friendlyName
        isCasting = true
        session.remoteMediaClient?.add(self)
        Logger.cast.info("Session active on '\(session.device.friendlyName ?? "unknown", privacy: .public)'")
        Task { [delegate] in await delegate?.castSessionDidStart() }
    }

    private func sessionEnded() {
        let position = streamPosition
        let wasPlaying = isPlayingRemotely
        isCasting = false
        isPlayingRemotely = false
        isAwaitingLoad = false
        deviceName = nil
        Logger.cast.info("Session ended at \(position, format: .fixed(precision: 1))s")
        Task { [delegate] in await delegate?.castSessionDidEnd(at: position, wasPlaying: wasPlaying) }
    }
}

// MARK: - Session listener

// nonisolated conformances: the Cast SDK's ObjC protocols carry no isolation, so each
// callback hops back to the main actor explicitly.
extension CastManager: GCKSessionManagerListener {
    nonisolated func sessionManager(_: GCKSessionManager, didStart session: GCKCastSession) {
        Task { @MainActor in sessionBecameActive(session) }
    }

    nonisolated func sessionManager(_: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        Task { @MainActor in sessionBecameActive(session) }
    }

    nonisolated func sessionManager(_: GCKSessionManager, didEnd _: GCKCastSession, withError _: Error?) {
        Task { @MainActor in sessionEnded() }
    }

    nonisolated func sessionManager(_: GCKSessionManager, didFailToStart _: GCKCastSession, withError error: Error) {
        Task { @MainActor in
            Logger.cast.error("Session failed to start: \(error.localizedDescription, privacy: .public)")
            sessionEnded()
        }
    }
}

// MARK: - Remote media listener

extension CastManager: GCKRemoteMediaClientListener {
    nonisolated func remoteMediaClient(_: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        guard let mediaStatus else { return }
        let playerState = mediaStatus.playerState
        let idleReason = mediaStatus.idleReason
        Task { @MainActor in
            switch playerState {
            case .playing, .buffering, .loading:
                isAwaitingLoad = false
                if !isPlayingRemotely {
                    isPlayingRemotely = true
                    await delegate?.castPlaybackStateDidChange(isPlaying: true)
                }
            case .paused:
                isAwaitingLoad = false
                if isPlayingRemotely {
                    isPlayingRemotely = false
                    await delegate?.castPlaybackStateDidChange(isPlaying: false)
                }
            case .idle:
                // A fresh load reports idle before it buffers — only a genuine finish advances the queue.
                guard !isAwaitingLoad, idleReason == .finished else { return }
                isPlayingRemotely = false
                await delegate?.castMediaDidFinish()
            default:
                break
            }
        }
    }
}
#endif
