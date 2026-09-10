// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import Foundation

/// The HTTP the cast proxy has to speak, kept apart from the sockets so it can be tested.
///
/// This is not a general web server. It answers exactly one shape of request — the
/// Default Media Receiver asking for a media file, usually with a byte range — and
/// everything here exists to get that one exchange right.
///
/// Ranges are the part that has to be exact. A Cast receiver seeks by sending
/// `Range: bytes=<start>-<end>` and expects `206` with a matching `Content-Range`; served
/// a plain `200` it assumes seeking is unsupported and refetches from zero. The rules are
/// RFC 7233 (https://datatracker.ietf.org/doc/html/rfc7233), summarised readably at
/// https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Range_requests. Note that
/// ranges are inclusive at both ends, which is the detail most easily got wrong.
///
/// No CORS headers here on purpose. Google requires them for adaptive streams and for
/// subtitle tracks (https://developers.google.com/cast/docs/media); plain progressive
/// audio, which is all Cassette relays, needs none.
nonisolated enum CastProxyHTTP {
    /// A byte range as the client asked for it, before the file size is known.
    enum ByteRange: Equatable, Sendable {
        /// `bytes=500-` — from an offset to the end. What a receiver sends to seek.
        case from(Int)
        /// `bytes=0-499` — a closed range, inclusive of both ends, as HTTP defines it.
        case closed(Int, Int)
        /// `bytes=-500` — the last N bytes. Rare, but cheap to honour.
        case suffix(Int)

        /// Resolves against a known total size, or nil when the range falls outside it.
        func resolved(totalBytes: Int) -> ClosedRange<Int>? {
            guard totalBytes > 0 else { return nil }
            let last = totalBytes - 1
            switch self {
            case .from(let start):
                guard start <= last else { return nil }
                return start...last
            case .closed(let start, let end):
                guard start <= last, start <= end else { return nil }
                return start...min(end, last)
            case .suffix(let count):
                guard count > 0 else { return nil }
                return max(0, totalBytes - count)...last
            }
        }
    }

    /// The parts of a request line and header block this server acts on.
    struct Request: Equatable, Sendable {
        let method: String
        let path: String
        let range: ByteRange?

        /// A HEAD is the receiver checking the file exists and how big it is. It must get
        /// the same headers as a GET and no body at all.
        var wantsBody: Bool { method == "GET" }
    }

    /// Parses a request head. Returns nil for anything that is not a well-formed request
    /// line, which for this server means hanging up rather than guessing.
    static func parseRequest(_ head: String) -> Request? {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        guard method == "GET" || method == "HEAD" else { return nil }

        let rangeHeader = lines.dropFirst().first { $0.lowercased().hasPrefix("range:") }
        return Request(
            method: method,
            path: String(parts[1]),
            range: rangeHeader.flatMap { parseRange(String($0.dropFirst("range:".count))) }
        )
    }

    /// Parses a `Range` header value. Only single ranges: a receiver never asks for more,
    /// and answering a multi-range request needs multipart bodies for no benefit here.
    static func parseRange(_ value: String) -> ByteRange? {
        let spec = value.trimmingCharacters(in: .whitespaces)
        guard spec.lowercased().hasPrefix("bytes=") else { return nil }
        let body = spec.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !body.contains(","), let dash = body.firstIndex(of: "-") else { return nil }

        let first = String(body[body.startIndex..<dash])
        let second = String(body[body.index(after: dash)...])
        if first.isEmpty {
            guard let count = Int(second) else { return nil }
            return .suffix(count)
        }
        guard let start = Int(first), start >= 0 else { return nil }
        if second.isEmpty { return .from(start) }
        guard let end = Int(second), end >= 0 else { return nil }
        return .closed(start, end)
    }

    /// The token identifying one published item, taken from a `/media/<token>` path.
    static func token(fromPath path: String) -> String? {
        let trimmed = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == "media", !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    /// Builds a response head. `contentRange` decides the status: its presence means a
    /// partial answer, and a receiver that asked for a range and got a bare 200 will
    /// re-request from the start on every seek.
    static func responseHead(
        contentType: String,
        contentLength: Int?,
        contentRange: String? = nil,
        status: Int? = nil
    ) -> String {
        let code = status ?? (contentRange == nil ? 200 : 206)
        var lines = ["HTTP/1.1 \(code) \(reason(for: code))"]
        lines.append("Content-Type: \(contentType)")
        // Without this the receiver assumes it cannot seek and disables the scrub bar.
        lines.append("Accept-Ranges: bytes")
        if let contentLength { lines.append("Content-Length: \(contentLength)") }
        if let contentRange { lines.append("Content-Range: \(contentRange)") }
        lines.append("Connection: close")
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    /// A `Content-Range` value for a resolved range of a file of known size.
    static func contentRange(for range: ClosedRange<Int>, totalBytes: Int) -> String {
        "bytes \(range.lowerBound)-\(range.upperBound)/\(totalBytes)"
    }

    private static func reason(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        case 502: return "Bad Gateway"
        default: return "Error"
        }
    }
}
#endif
