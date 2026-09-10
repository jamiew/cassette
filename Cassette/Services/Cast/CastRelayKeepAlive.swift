// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import AVFoundation
import OSLog

/// Renders silence so iOS keeps Cassette running while the phone is the one serving audio.
///
/// A direct cast needs nothing like this: the receiver fetches from the server, and the
/// phone can be suspended, locked or killed without the music stopping. A relayed cast is
/// the opposite — the phone *is* the source, so the moment iOS suspends the app the
/// speaker's connection dies mid-track.
///
/// The `audio` background mode grants runtime while an app is rendering audio, and an
/// audio session that is merely active does not count. So the app renders silence for as
/// long as it is relaying. This is the conventional way to hold the mode, and the use here
/// is the one it exists for: Cassette really is delivering audio the whole time, just to a
/// speaker rather than to the phone's own output.
///
/// Kept as narrow as possible on purpose. It runs only while a cast is being relayed, not
/// during local playback and not during a direct cast, and it owns its own engine so it
/// can never disturb the `AudioStreaming` player that does the real work.
final class CastRelayKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private(set) var isRunning = false

    /// One second of silence, looped. A fixed standard format rather than the hardware's,
    /// so this behaves the same whatever the current route is; the engine converts.
    private static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)

    func start() {
        guard !isRunning, let format = Self.format else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else {
            Logger.cast.error("Relay keep-alive could not allocate its buffer")
            return
        }
        buffer.frameLength = buffer.frameCapacity
        // Freshly allocated buffers are not documented to be zeroed, and a buffer of
        // uninitialised memory played at full volume is the worst bug in this file.
        for channel in 0..<Int(buffer.format.channelCount) {
            buffer.floatChannelData?[channel].update(repeating: 0, count: Int(buffer.frameLength))
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            Logger.cast.error("Relay keep-alive engine failed: \(error.localizedDescription, privacy: .public)")
            engine.detach(player)
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        isRunning = true
        Logger.cast.info("Relay keep-alive started — the app will stay running while it serves")
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        engine.detach(player)
        isRunning = false
        Logger.cast.info("Relay keep-alive stopped")
    }

    deinit {
        if isRunning {
            player.stop()
            engine.stop()
        }
    }
}
#endif
