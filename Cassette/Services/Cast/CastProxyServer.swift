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
/// relays. It needs nothing of the network beyond the phone and the speaker being able to
/// see each other.
///
/// This is the established answer rather than a novel one. VLC does the same thing to cast
/// anything a Chromecast cannot fetch for itself — "VLC has to be a http server like
/// youtube.com, and provide the video in a Chromecast compatible format"
/// (https://mfkl.github.io/chromecast/2018/10/21/High-performance-cross-platform-streaming-with-libvlc-and-Chromecast-on-.NET.html).
/// BubbleUPnP Server does it for media servers a renderer cannot otherwise reach
/// (https://bubblesoftapps.com/bubbleupnpserver2/docs/features_and_requirements.html).
/// Cassette's version is simpler than either: it never transcodes, because a Subsonic
/// server already serves formats the Default Media Receiver plays.
///
/// Two things to know. The relay only lives as long as the app does, which is why a
/// relayed cast holds the `audio` background mode open through `CastRelayKeepAlive`. And
/// the token is unguessable, because anything on the LAN can ask for it.
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
        // Without this a listener that cannot bind fails in silence and every publish
        // afterwards times out waiting for a port that is never coming.
        listener.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                Logger.castProxy.error("Proxy listener failed: \(error.localizedDescription, privacy: .public)")
            case .ready:
                Logger.castProxy.info("Proxy listening")
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
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
        do {
            try start()
        } catch {
            Logger.castProxy.error("Proxy could not start: \(error.localizedDescription, privacy: .public)")
            return nil
        }
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

    /// Looks one item up. The only part of serving a request that touches actor state.
    private func item(for token: String) -> Item? { items[token] }

    /// Answers one request.
    ///
    /// `nonisolated` on purpose, and it matters more than it looks: relaying a track means
    /// awaiting once per chunk, and an actor-isolated version re-enters the actor on every
    /// one of those. Serving off the actor also lets a receiver's parallel range requests
    /// actually run in parallel.
    nonisolated private func serve(_ connection: NWConnection) async {
        defer { Task { await Self.close(connection) } }
        guard let head = try? await Self.readRequestHead(connection),
              let request = CastProxyHTTP.parseRequest(head) else { return }
        guard let token = CastProxyHTTP.token(fromPath: request.path),
              let item = await item(for: token) else {
            try? await Self.send(Self.errorHead(404), on: connection)
            Logger.castProxy.error("Proxy 404 for an unknown token")
            return
        }
        do {
            if item.isLocalFile {
                try await Self.serveFile(item, request: request, on: connection)
            } else {
                try await Self.serveUpstream(item, request: request, on: connection)
            }
        } catch {
            Logger.castProxy.error("Proxy relay failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Serves a downloaded or cached file. The phone already has the bytes, so this is the
    /// one path with no second hop at all.
    nonisolated private static func serveFile(
        _ item: Item,
        request: CastProxyHTTP.Request,
        on connection: NWConnection
    ) async throws {
        let handle = try FileHandle(forReadingFrom: item.source)
        defer { try? handle.close() }
        let total = Int(try handle.seekToEnd())
        guard total > 0 else {
            try await send(errorHead(404), on: connection)
            return
        }

        var range = 0...(total - 1)
        var contentRange: String?
        if let asked = request.range {
            guard let resolved = asked.resolved(totalBytes: total) else {
                try await send(errorHead(416), on: connection)
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
        try await send(Data(head.utf8), on: connection)
        guard request.wantsBody else { return }

        try handle.seek(toOffset: UInt64(range.lowerBound))
        var remaining = range.count
        while remaining > 0 {
            let chunk = try handle.read(upToCount: min(chunkBytes, remaining)) ?? Data()
            if chunk.isEmpty { break }
            try await send(chunk, on: connection)
            remaining -= chunk.count
        }
    }

    /// Relays a remote stream. The receiver's method and range go upstream unchanged and
    /// the upstream's answer comes back unchanged, so seeking behaves as it would directly.
    nonisolated private static func serveUpstream(
        _ item: Item,
        request: CastProxyHTTP.Request,
        on connection: NWConnection
    ) async throws {
        var upstream = URLRequest(url: item.source)
        // Forwarding HEAD rather than answering it from a GET: a receiver sizes the file
        // before it fetches, and turning that into a full download wastes the whole track.
        upstream.httpMethod = request.method
        for (field, value) in item.headers { upstream.setValue(value, forHTTPHeaderField: field) }
        if let range = request.range {
            upstream.setValue(headerValue(for: range), forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: upstream)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        guard status < 400 else {
            try await send(errorHead(502), on: connection)
            Logger.castProxy.error("Upstream returned \(status) for the cast relay")
            return
        }

        // The upstream's own content type beats anything guessed from a file suffix: a
        // Subsonic server that transcodes returns bytes the suffix no longer describes.
        let head = CastProxyHTTP.responseHead(
            contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? item.contentType,
            contentLength: (http?.expectedContentLength).flatMap { $0 > 0 ? Int($0) : nil },
            contentRange: http?.value(forHTTPHeaderField: "Content-Range"),
            status: status == 206 ? 206 : 200
        )
        try await send(Data(head.utf8), on: connection)
        guard request.wantsBody else { return }

        // AsyncBytes rather than a delegate: awaiting it applies backpressure for free, so
        // the relay reads upstream no faster than the receiver drains it. Batched into
        // chunks it moves far more than even a high-resolution FLAC stream needs.
        var buffer = Data(capacity: chunkBytes)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= chunkBytes {
                try await send(buffer, on: connection)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty { try await send(buffer, on: connection) }
    }

    // MARK: - Sockets

    nonisolated private static let chunkBytes = 64 * 1024
    /// A receiver that connects and then says nothing must not hold a task forever.
    nonisolated private static let headTimeout = Duration.seconds(10)

    nonisolated private static func errorHead(_ status: Int) -> Data {
        Data(CastProxyHTTP.responseHead(
            contentType: "text/plain",
            contentLength: 0,
            status: status
        ).utf8)
    }

    nonisolated private static func headerValue(for range: CastProxyHTTP.ByteRange) -> String {
        switch range {
        case .from(let start): return "bytes=\(start)-"
        case .closed(let start, let end): return "bytes=\(start)-\(end)"
        case .suffix(let count): return "bytes=-\(count)"
        }
    }

    /// Reads until the end of the header block, bounded in both size and time: this socket
    /// is open to everything on the network.
    nonisolated private static func readRequestHead(_ connection: NWConnection) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
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
            group.addTask {
                try await Task.sleep(for: headTimeout)
                throw CancellationError()
            }
            defer { group.cancelAll() }
            return try await group.next() ?? ""
        }
    }

    nonisolated private static func receive(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    nonisolated private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Closes the write side before tearing the connection down, so the last chunk of a
    /// track is not dropped on the floor along with the socket.
    nonisolated private static func close(_ connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in continuation.resume() }
            )
        }
        connection.cancel()
    }

    // MARK: - Addressing

    nonisolated private static func makeToken() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// This phone's address on the local network, as a receiver would dial it.
    nonisolated static func lanAddress() -> String? {
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
