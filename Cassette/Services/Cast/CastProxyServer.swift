// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

#if os(iOS)
import Foundation
import Network
import OSLog

/// Serves the current track to the Chromecast from the phone.
///
/// A receiver fetches the audio itself, so it can only play what it can reach. That rules
/// out a server on a VPN, one behind a proxy that authenticates on request headers, one
/// with a certificate only the phone trusts, and any file already downloaded to the
/// device. In each case the phone can reach the audio and the speaker cannot.
///
/// So the phone hands the speaker a `http://<its own LAN address>/media/<token>` URL and
/// relays. It is the same trick VLC and BubbleUPnP use, and it needs nothing of the
/// network beyond the phone and the speaker being able to see each other.
///
/// Two things to know. The relay only lives as long as the app does — a suspended app
/// serves nothing — and the token is unguessable because anything on the LAN can ask.
actor CastProxyServer {
    /// One track published for the receiver to collect.
    struct Item: Sendable {
        /// Where the phone gets the audio: a remote stream, or a file on the device.
        let source: URL
        /// Headers the upstream needs. The whole point of the relay for some servers.
        let headers: [String: String]
        let contentType: String

        var isLocalFile: Bool { source.isFileURL }
    }

    private var items: [String: Item] = [:]
    private var order: [String] = []
    private static let maxPublished = 4
    private var listener: NWListener?
    private var listeningPort: UInt16?
    private let queue = DispatchQueue(label: "app.cassette.cast.proxy")

    /// Starts listening on an ephemeral port. Safe to call when already running.
    func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
            Task { await self?.serve(connection) }
        }
        listener.start(queue: queue)
        self.listener = listener

        // The port is assigned asynchronously; the first publish waits for it.
        Logger.castProxy.info("Proxy listener starting")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        listeningPort = nil
        items.removeAll()
        order.removeAll()
        Logger.castProxy.info("Proxy stopped")
    }

    /// Publishes one item and returns the URL to hand the receiver, or nil when the phone
    /// has no address a receiver could connect to.
    func publish(_ item: Item) async -> URL? {
        try? start()
        guard let port = await resolvedPort() else {
            Logger.castProxy.error("Proxy has no port — cannot publish")
            return nil
        }
        guard let host = Self.lanAddress() else {
            Logger.castProxy.error("Phone has no LAN address — is Wi-Fi off?")
            return nil
        }
        // Anything on the network can ask for this path, so make it unguessable rather
        // than sequential: the URL is the only thing standing in front of the audio.
        let token = Self.makeToken()
        items[token] = item
        order.append(token)
        // A track and its artwork are in flight at once, and a receiver may re-request
        // either. Holding more than the last few only widens the window on the LAN.
        while order.count > Self.maxPublished {
            items.removeValue(forKey: order.removeFirst())
        }
        return URL(string: "http://\(host):\(port)/media/\(token)")
    }

    /// Waits for the listener to report its port. It is assigned after `start` returns.
    private func resolvedPort() async -> UInt16? {
        if let listeningPort { return listeningPort }
        for _ in 0..<50 {
            if let port = listener?.port?.rawValue, port != 0 {
                listeningPort = port
                return port
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    // MARK: - Serving

    private func serve(_ connection: NWConnection) async {
        defer { connection.cancel() }
        guard let head = try? await Self.readRequestHead(connection),
              let request = CastProxyHTTP.parseRequest(head) else { return }
        guard let token = CastProxyHTTP.token(fromPath: request.path), let item = items[token] else {
            try? await Self.send(Self.errorHead(404), on: connection)
            Logger.castProxy.error("Proxy 404 for an unknown token")
            return
        }
        do {
            if item.isLocalFile {
                try await serveFile(item, request: request, on: connection)
            } else {
                try await serveUpstream(item, request: request, on: connection)
            }
        } catch {
            Logger.castProxy.error("Proxy relay failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Serves a downloaded or cached file. The phone already has the bytes, so this is the
    /// one path with no second hop at all.
    private func serveFile(
        _ item: Item,
        request: CastProxyHTTP.Request,
        on connection: NWConnection
    ) async throws {
        let handle = try FileHandle(forReadingFrom: item.source)
        defer { try? handle.close() }
        let total = Int(try handle.seekToEnd())

        var range = 0...max(0, total - 1)
        var contentRange: String?
        if let asked = request.range {
            guard let resolved = asked.resolved(totalBytes: total) else {
                try await Self.send(Self.errorHead(416), on: connection)
                return
            }
            range = resolved
            contentRange = CastProxyHTTP.contentRange(for: resolved, totalBytes: total)
        }

        let head = CastProxyHTTP.responseHead(
            contentType: item.contentType,
            contentLength: range.count,
            contentRange: contentRange
        )
        try await Self.send(Data(head.utf8), on: connection)
        guard request.wantsBody else { return }

        try handle.seek(toOffset: UInt64(range.lowerBound))
        var remaining = range.count
        while remaining > 0 {
            let chunk = try handle.read(upToCount: min(Self.chunkBytes, remaining)) ?? Data()
            if chunk.isEmpty { break }
            try await Self.send(chunk, on: connection)
            remaining -= chunk.count
        }
    }

    /// Relays a remote stream. The receiver's range goes upstream unchanged and the
    /// upstream's answer comes back unchanged, so seeking behaves as it would directly.
    private func serveUpstream(
        _ item: Item,
        request: CastProxyHTTP.Request,
        on connection: NWConnection
    ) async throws {
        var upstream = URLRequest(url: item.source)
        upstream.httpMethod = "GET"
        for (field, value) in item.headers { upstream.setValue(value, forHTTPHeaderField: field) }
        if let range = request.range { upstream.setValue(Self.headerValue(for: range), forHTTPHeaderField: "Range") }

        // AsyncBytes rather than a delegate: iterating it applies backpressure for free,
        // and even batched into chunks it moves far more than a FLAC stream needs.
        let (bytes, response) = try await URLSession.shared.bytes(for: upstream)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        guard status < 400 else {
            try await Self.send(Self.errorHead(502), on: connection)
            Logger.castProxy.error("Upstream returned \(status) for the cast relay")
            return
        }

        let head = CastProxyHTTP.responseHead(
            contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? item.contentType,
            contentLength: (http?.expectedContentLength).flatMap { $0 > 0 ? Int($0) : nil },
            contentRange: http?.value(forHTTPHeaderField: "Content-Range"),
            status: status == 206 ? 206 : 200
        )
        try await Self.send(Data(head.utf8), on: connection)
        guard request.wantsBody else { return }

        var buffer = Data(capacity: Self.chunkBytes)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= Self.chunkBytes {
                try await Self.send(buffer, on: connection)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try await Self.send(buffer, on: connection) }
    }

    // MARK: - Sockets

    private static let chunkBytes = 64 * 1024

    private static func errorHead(_ status: Int) -> Data {
        Data(CastProxyHTTP.responseHead(
            contentType: "text/plain",
            contentLength: 0,
            status: status
        ).utf8)
    }

    private static func headerValue(for range: CastProxyHTTP.ByteRange) -> String {
        switch range {
        case .from(let start): return "bytes=\(start)-"
        case .closed(let start, let end): return "bytes=\(start)-\(end)"
        case .suffix(let count): return "bytes=-\(count)"
        }
    }

    /// Reads until the end of the header block. Bounded, because an endless stream of
    /// headers from something on the LAN should not be able to grow the heap.
    private static func readRequestHead(_ connection: NWConnection) async throws -> String {
        var accumulated = Data()
        while accumulated.count < 16 * 1024 {
            let chunk = try await receive(on: connection)
            guard !chunk.isEmpty else { break }
            accumulated.append(chunk)
            if let text = String(data: accumulated, encoding: .utf8), text.contains("\r\n\r\n") {
                return text
            }
        }
        return String(data: accumulated, encoding: .utf8) ?? ""
    }

    private static func receive(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    // MARK: - Addressing

    private static func makeToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// This phone's address on the local network, as a receiver would dial it.
    static func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var found: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard pointer.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                pointer.pointee.ifa_addr,
                socklen_t(pointer.pointee.ifa_addr.pointee.sa_len),
                &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            found.append((String(cString: pointer.pointee.ifa_name), String(cString: buffer)))
        }
        return preferredAddress(from: found)
    }

    /// Picks the interface a receiver on the same network would be able to reach.
    ///
    /// `en0` is Wi-Fi and is what we want. A phone on a VPN also has a tunnel interface
    /// carrying an address that only the VPN can route, which is precisely the situation
    /// this proxy exists to work around — handing the speaker one would rebuild the bug.
    nonisolated static func preferredAddress(from interfaces: [(name: String, address: String)]) -> String? {
        let usable = interfaces.filter { candidate in
            !candidate.address.hasPrefix("169.254.") && !candidate.address.hasPrefix("127.")
                && !candidate.name.hasPrefix("utun") && !candidate.name.hasPrefix("ipsec")
                && !candidate.name.hasPrefix("ppp")
        }
        return usable.first { $0.name == "en0" }?.address
            ?? usable.first { $0.name.hasPrefix("en") }?.address
            ?? usable.first?.address
    }
}
#endif
