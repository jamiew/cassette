// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import AVFoundation
import Testing
@testable import Cassette

/// The keep-alive is the only thing standing between a relayed cast and iOS suspending the
/// app mid-track, so it has to survive being started twice, stopped twice, and stopped
/// having never run. Whether the OS actually grants the background time is not something a
/// test can answer; that this thing runs and stops cleanly is.
@Suite("CastRelayKeepAlive", .serialized)
struct CastRelayKeepAliveTests {
    private func withAudioSession(_ body: () throws -> Void) rethrows {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback)
        try? session.setActive(true)
        defer { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
        try body()
    }

    @Test func runsUntilStopped() {
        withAudioSession {
            let keepAlive = CastRelayKeepAlive()
            #expect(!keepAlive.isRunning)
            keepAlive.start()
            #expect(keepAlive.isRunning)
            keepAlive.stop()
            #expect(!keepAlive.isRunning)
        }
    }

    /// Every relayed track calls start again. Attaching the player node twice would trap.
    @Test func startingTwiceIsHarmless() {
        withAudioSession {
            let keepAlive = CastRelayKeepAlive()
            keepAlive.start()
            keepAlive.start()
            #expect(keepAlive.isRunning)
            keepAlive.stop()
            #expect(!keepAlive.isRunning)
        }
    }

    /// A cast session can end without ever having relayed anything.
    @Test func stoppingWithoutStartingIsHarmless() {
        let keepAlive = CastRelayKeepAlive()
        keepAlive.stop()
        #expect(!keepAlive.isRunning)
    }

    @Test func canRunAgainAfterStopping() {
        withAudioSession {
            let keepAlive = CastRelayKeepAlive()
            keepAlive.start()
            keepAlive.stop()
            keepAlive.start()
            #expect(keepAlive.isRunning)
            keepAlive.stop()
        }
    }
}
#endif
