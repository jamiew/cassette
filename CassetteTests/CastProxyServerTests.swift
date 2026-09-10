// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import Foundation
import Testing
@testable import Cassette

/// Runs the proxy for real over a socket and collects from it the way a receiver would.
///
/// The parsing is covered by `CastProxyHTTPTests`; this is here because the parts that
/// break in practice are the ones between the parser and the wire — a body sent after a
/// HEAD, a range served from the wrong offset, a response head missing its blank line.
/// None of that needs a Chromecast, only a socket.
@Suite("CastProxyServer", .enabled(if: CastProxyServer.lanAddress() != nil))
struct CastProxyServerTests {
    /// 64 KB and a bit, so the body crosses the server's chunk boundary.
    private func makeFile() throws -> (url: URL, bytes: Data) {
        let bytes = Data((0..<70_000).map { UInt8($0 % 251) })
        let url = URL.temporaryDirectory.appending(path: "cast-proxy-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        return (url, bytes)
    }

    /// The published URL carries the phone's LAN address, which is the point of it, but a
    /// test should not depend on the machine having one that routes. The listener answers
    /// on every interface, so collect over loopback.
    private func loopback(_ url: URL) -> URLRequest {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.host = "127.0.0.1"
        return URLRequest(url: components.url!)
    }

    private func publish(_ file: URL, on server: CastProxyServer) async throws -> URLRequest {
        let published = await server.publish(
            CastProxyServer.Item(source: file, headers: [:], contentType: "audio/mpeg")
        )
        return loopback(try #require(published))
    }

    @Test func servesTheWholeFile() async throws {
        let server = CastProxyServer()
        defer { Task { await server.stop() } }
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file.url) }

        let (data, response) = try await URLSession.shared.data(for: publish(file.url, on: server))
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(data == file.bytes)
        #expect(http.value(forHTTPHeaderField: "Content-Type") == "audio/mpeg")
        #expect(http.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
    }

    /// Seeking on the receiver becomes a range request. Served from the wrong offset it
    /// plays the right length of the wrong audio, which sounds like a corrupt file.
    @Test func servesARangeFromTheRightOffset() async throws {
        let server = CastProxyServer()
        defer { Task { await server.stop() } }
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file.url) }

        var request = try await publish(file.url, on: server)
        request.setValue("bytes=1000-1999", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 206)
        #expect(data.count == 1000)
        #expect(data == file.bytes[1000...1999])
        #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes 1000-1999/70000")
    }

    /// An open-ended range is what a receiver actually sends to resume mid-track.
    @Test func servesAnOpenEndedRangeToTheEnd() async throws {
        let server = CastProxyServer()
        defer { Task { await server.stop() } }
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file.url) }

        var request = try await publish(file.url, on: server)
        request.setValue("bytes=69000-", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)

        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect(data == file.bytes[69000...])
    }

    /// The receiver sizes the file with a HEAD before it fetches anything.
    @Test func answersHeadWithHeadersAndNoBody() async throws {
        let server = CastProxyServer()
        defer { Task { await server.stop() } }
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file.url) }

        var request = try await publish(file.url, on: server)
        request.httpMethod = "HEAD"
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 200)
        #expect(data.isEmpty)
        #expect(http.value(forHTTPHeaderField: "Content-Length") == "70000")
    }

    /// Tokens are unguessable because anything on the network can ask. A wrong one must
    /// get nothing, not the track that happens to be published.
    @Test func refusesAnUnknownToken() async throws {
        let server = CastProxyServer()
        defer { Task { await server.stop() } }
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file.url) }

        let published = try await publish(file.url, on: server)
        var components = URLComponents(url: published.url!, resolvingAgainstBaseURL: false)!
        components.path = "/media/0000000000000000000000000000000000"
        let (_, response) = try await URLSession.shared.data(from: components.url!)

        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }

    // MARK: - Relaying a remote source

    /// Points the proxy at itself: one item is a file on disk, the second relays the first
    /// over HTTP. That exercises the upstream path — the one a Subsonic server takes —
    /// without needing a server, a network, or a Chromecast.
    private func chained(
        _ file: URL,
        on server: CastProxyServer,
        declaring contentType: String = "audio/mpeg"
    ) async throws -> URLRequest {
        let origin = try #require(await server.publish(
            CastProxyServer.Item(source: file, headers: [:], contentType: "audio/mpeg")
        ))
        // Point the relay at loopback rather than the published LAN address: whether this
        // machine can reach its own en0 is a fact about the machine, and a test that
        // depends on it fails on a build runner for reasons that are not a defect.
        let upstream = try #require(loopback(origin).url)
        let relayed = try #require(await server.publish(
            CastProxyServer.Item(source: upstream, headers: [:], contentType: contentType)
        ))
        return loopback(relayed)
    }

    @Test func relaysARemoteSourceWholeAndIntact() async throws {
        let server = CastProxyServer()
        defer { Task { await server.stop() } }
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file.url) }

        let (data, response) = try await URLSession.shared.data(for: chained(file.url, on: server))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data == file.bytes)
    }

    /// Seeking has to survive the extra hop: the receiver's range goes upstream and the
    /// upstream's partial answer comes back, rather than the relay restarting the track.
    @Test func forwardsARangeThroughToTheUpstream() async throws {
        let server = CastProxyServer()
        defer { Task { await server.stop() } }
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file.url) }

        var request = try await chained(file.url, on: server)
        request.setValue("bytes=2000-2999", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 206)
        #expect(data == file.bytes[2000...2999])
        #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes 2000-2999/70000")
    }

    /// A Subsonic server that transcodes returns bytes the file suffix no longer describes,
    /// so what the upstream says it sent beats anything Cassette guessed.
    @Test func prefersTheUpstreamContentTypeOverTheGuess() async throws {
        let server = CastProxyServer()
        defer { Task { await server.stop() } }
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file.url) }

        let request = try await chained(file.url, on: server, declaring: "application/octet-stream")
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "audio/mpeg")
    }

    /// Every publish mints a fresh token, so a URL cannot be inferred from an earlier one.
    @Test func mintsADistinctTokenEachTime() async throws {
        let server = CastProxyServer()
        defer { Task { await server.stop() } }
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file.url) }

        let first = try await publish(file.url, on: server)
        let second = try await publish(file.url, on: server)
        #expect(first.url?.path != second.url?.path)
        #expect(first.url?.path.count == "/media/".count + 32)
    }
}
#endif
