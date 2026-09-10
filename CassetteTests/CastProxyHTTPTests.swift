// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import Foundation
import Testing
@testable import Cassette

/// The proxy speaks just enough HTTP for one receiver to collect one track. Getting a
/// range wrong there costs a seek that silently restarts the song, which is exactly the
/// kind of thing that is miserable to notice on real hardware.
@Suite("CastProxyHTTP")
struct CastProxyHTTPTests {

    // MARK: - Requests

    @Test func readsMethodAndPath() {
        let request = CastProxyHTTP.parseRequest("GET /media/abc123 HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(request?.method == "GET")
        #expect(request?.path == "/media/abc123")
        #expect(request?.range == nil)
        #expect(request?.wantsBody == true)
    }

    /// A receiver sends HEAD first to size the file. It needs the same headers and no body;
    /// answering with a body confuses the media element into playing nothing.
    @Test func headAsksForNoBody() {
        let request = CastProxyHTTP.parseRequest("HEAD /media/abc HTTP/1.1\r\n\r\n")
        #expect(request?.method == "HEAD")
        #expect(request?.wantsBody == false)
    }

    @Test func refusesMethodsThisServerDoesNotAnswer() {
        #expect(CastProxyHTTP.parseRequest("POST /media/abc HTTP/1.1\r\n\r\n") == nil)
        #expect(CastProxyHTTP.parseRequest("nonsense") == nil)
        #expect(CastProxyHTTP.parseRequest("") == nil)
    }

    /// Header names are case-insensitive and receivers are not consistent about it.
    @Test func findsTheRangeHeaderWhateverItsCasing() {
        let lower = CastProxyHTTP.parseRequest("GET /media/a HTTP/1.1\r\nrange: bytes=100-\r\n\r\n")
        let upper = CastProxyHTTP.parseRequest("GET /media/a HTTP/1.1\r\nRANGE: bytes=100-\r\n\r\n")
        #expect(lower?.range == .from(100))
        #expect(upper?.range == .from(100))
    }

    // MARK: - Ranges

    @Test func parsesTheThreeRangeForms() {
        #expect(CastProxyHTTP.parseRange("bytes=500-") == .from(500))
        #expect(CastProxyHTTP.parseRange("bytes=0-499") == .closed(0, 499))
        #expect(CastProxyHTTP.parseRange("bytes=-500") == .suffix(500))
        #expect(CastProxyHTTP.parseRange(" bytes=0-1 ") == .closed(0, 1))
    }

    @Test func rejectsRangesItWillNotAnswer() {
        #expect(CastProxyHTTP.parseRange("items=0-1") == nil)
        #expect(CastProxyHTTP.parseRange("bytes=0-1,5-6") == nil)
        #expect(CastProxyHTTP.parseRange("bytes=abc-") == nil)
        #expect(CastProxyHTTP.parseRange("bytes=") == nil)
    }

    /// HTTP ranges are inclusive at both ends. Treating them as half-open drops the last
    /// byte of every request, which most decoders tolerate and some do not.
    @Test func resolvesRangesInclusively() {
        #expect(CastProxyHTTP.ByteRange.closed(0, 9).resolved(totalBytes: 100) == 0...9)
        #expect(CastProxyHTTP.ByteRange.from(90).resolved(totalBytes: 100) == 90...99)
        #expect(CastProxyHTTP.ByteRange.suffix(10).resolved(totalBytes: 100) == 90...99)
    }

    /// A range running off the end is clamped, not refused — receivers routinely ask for
    /// more than is there. A range starting past the end has no answer at all.
    @Test func clampsPastTheEndButRefusesToStartPastIt() {
        #expect(CastProxyHTTP.ByteRange.closed(90, 500).resolved(totalBytes: 100) == 90...99)
        #expect(CastProxyHTTP.ByteRange.from(100).resolved(totalBytes: 100) == nil)
        #expect(CastProxyHTTP.ByteRange.from(0).resolved(totalBytes: 0) == nil)
    }

    // MARK: - Tokens

    @Test func readsTheTokenOutOfThePath() {
        #expect(CastProxyHTTP.token(fromPath: "/media/abc123") == "abc123")
        #expect(CastProxyHTTP.token(fromPath: "/media/abc123?x=1") == "abc123")
    }

    @Test func refusesPathsThatAreNotAPublishedItem() {
        #expect(CastProxyHTTP.token(fromPath: "/") == nil)
        #expect(CastProxyHTTP.token(fromPath: "/media/") == nil)
        #expect(CastProxyHTTP.token(fromPath: "/media/a/b") == nil)
        #expect(CastProxyHTTP.token(fromPath: "/other/abc") == nil)
    }

    // MARK: - Responses

    /// A receiver that asked for a range and got a bare 200 assumes seeking is unsupported
    /// and re-fetches from zero every time the user scrubs.
    @Test func aRangedAnswerIsPartialContent() {
        let head = CastProxyHTTP.responseHead(
            contentType: "audio/mpeg",
            contentLength: 10,
            contentRange: "bytes 0-9/100"
        )
        #expect(head.hasPrefix("HTTP/1.1 206 Partial Content\r\n"))
        #expect(head.contains("Content-Range: bytes 0-9/100\r\n"))
    }

    @Test func anUnrangedAnswerIsOK() {
        let head = CastProxyHTTP.responseHead(contentType: "audio/flac", contentLength: 100)
        #expect(head.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(head.contains("Content-Length: 100\r\n"))
    }

    /// Without Accept-Ranges the receiver disables its own scrub bar.
    @Test func alwaysAdvertisesRangeSupport() {
        let head = CastProxyHTTP.responseHead(contentType: "audio/mpeg", contentLength: nil)
        #expect(head.contains("Accept-Ranges: bytes\r\n"))
        #expect(!head.contains("Content-Length:"))
        #expect(head.hasSuffix("\r\n\r\n"))
    }

    @Test func contentRangeCountsFromZero() {
        #expect(CastProxyHTTP.contentRange(for: 0...9, totalBytes: 100) == "bytes 0-9/100")
        #expect(CastProxyHTTP.contentRange(for: 90...99, totalBytes: 100) == "bytes 90-99/100")
    }
}

@Suite("CastProxyServer.preferredAddress")
struct CastProxyAddressTests {
    @Test func prefersWiFi() {
        let picked = CastProxyServer.preferredAddress(from: [
            (name: "lo0", address: "127.0.0.1"),
            (name: "en0", address: "192.168.1.20"),
        ])
        #expect(picked == "192.168.1.20")
    }

    /// The whole point of the relay is that the receiver cannot reach the phone's VPN.
    /// Handing it a tunnel address would rebuild the bug it exists to work around.
    @Test func neverHandsOutATunnelAddress() {
        let picked = CastProxyServer.preferredAddress(from: [
            (name: "utun3", address: "100.101.102.103"),
            (name: "en0", address: "192.168.1.20"),
        ])
        #expect(picked == "192.168.1.20")
        #expect(CastProxyServer.preferredAddress(from: [(name: "utun3", address: "100.64.0.1")]) == nil)
    }

    /// A self-assigned address means the phone never got a lease, so nothing can reach it.
    @Test func ignoresLinkLocalAndLoopback() {
        #expect(CastProxyServer.preferredAddress(from: [(name: "en0", address: "169.254.1.1")]) == nil)
        #expect(CastProxyServer.preferredAddress(from: [(name: "lo0", address: "127.0.0.1")]) == nil)
        #expect(CastProxyServer.preferredAddress(from: []) == nil)
    }
}
#endif
