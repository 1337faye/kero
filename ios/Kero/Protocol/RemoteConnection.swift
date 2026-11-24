import Foundation

// A remote connection to kerod (internal/remote): a WebSocket to the host's
// listener at /kero/mux, carrying binary messages as one byte stream; a
// MuxHello line and the MuxWelcome line that answers it; then yamux, each
// stream of which is a connection to kerod that starts with its own Hello.

/// Errors a connection tells apart, for the UI to say what to do.
enum RemoteError: Error, LocalizedError {
    case refused(String)
    case version(host: String)
    case protocolVersion(daemon: Int)
    case notKero(String)
    case handshakeTimeout
    case daemon(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .refused(let s): "The host refused the connection: \(s)"
        case .version(let host): "Kero \(host) on the host connects otherwise: update it, or this app."
        case .protocolVersion(let v): "kerod on the host speaks protocol \(v), this app \(KeroProtocol.version): update the older one."
        case .notKero(let s): "The host answered what is not Kero: \(s)"
        case .handshakeTimeout: "The host did not answer in time."
        case .daemon(let s): s
        case .closed: "The connection closed."
        }
    }
}

/// The byte stream under a remote connection: a WebSocket whose binary
/// messages are pieces of one stream, as websocket.NetConn makes them.
final class WebSocketTransport: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let queue: DispatchQueue
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private var outbox = Data()
    private var sending = false
    private var closed = false

    var onOpen: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    init(url: URL, clientName: String, queue: DispatchQueue) {
        self.queue = queue
        super.init()
        let ops = OperationQueue()
        ops.underlyingQueue = queue
        ops.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        // No cookies or caches of anyone's: kerod needs none.
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: ops)
        var req = URLRequest(url: url)
        req.setValue(clientName, forHTTPHeaderField: KeroProtocol.clientHeader)
        task = session.webSocketTask(with: req)
        // kerod's state is sent whole: up to proto.MaxLine.
        task.maximumMessageSize = KeroProtocol.maxLine + 1024
    }

    func start() {
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .success(.data(let d)):
                self.onData?(d)
                self.receive()
            case .success(.string(let s)):
                self.onData?(Data(s.utf8))
                self.receive()
            case .success:
                self.receive()
            case .failure(let err):
                self.finish(self.explain(err))
            }
        }
    }

    /// Writes bytes, in order: what is written while a message is under way
    /// goes out together in the next.
    func write(_ data: Data) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed else { return }
        outbox.append(data)
        pump()
    }

    private func pump() {
        guard !sending, !outbox.isEmpty, !closed else { return }
        sending = true
        let msg = outbox
        outbox = Data()
        task.send(.data(msg)) { [weak self] err in
            guard let self else { return }
            self.queue.async {
                self.sending = false
                if let err { self.finish(self.explain(err)); return }
                self.pump()
            }
        }
    }

    func close() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !closed else { return }
        closed = true
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        onData = nil
        onOpen = nil
        onClose = nil
    }

    private func finish(_ err: Error?) {
        guard !closed else { return }
        closed = true
        task.cancel()
        session.invalidateAndCancel()
        let h = onClose
        onClose = nil
        onData = nil
        onOpen = nil
        h?(err)
    }

    private func explain(_ err: Error) -> Error {
        if let resp = task.response as? HTTPURLResponse, [401, 403].contains(resp.statusCode) {
            return RemoteError.refused(HTTPURLResponse.localizedString(forStatusCode: resp.statusCode))
        }
        return err
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(closeCode == .normalClosure ? nil : RemoteError.closed)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(explain(error)) } else { finish(nil) }
    }
}

/// One remote connection to a host's kerod, and the streams it carries.
final class RemoteConnection: @unchecked Sendable {
    let address: HostAddress
    let queue: DispatchQueue
    private let transport: WebSocketTransport
    private var mux: YamuxSession?
    private var lines = LineSplitter(maxLine: 64 << 10)
    private var junk = Data()
    private var junkLines = 0
    private var handshake: CheckedContinuation<MuxWelcome, Error>?
    private var ended = false
    private(set) var welcome: MuxWelcome?

    /// The connection ended, after it was up: nil when this side closed it.
    var onClose: ((Error?) -> Void)?

    private init(address: HostAddress, clientName: String) {
        self.address = address
        queue = DispatchQueue(label: "kero.remote.\(address.host)", qos: .userInitiated)
        transport = WebSocketTransport(url: address.muxURL, clientName: clientName, queue: queue)
    }

    /// Dials a host and does the mux handshake, within 20 seconds.
    static func connect(to address: HostAddress, clientName: String, appVersion: String) async throws -> RemoteConnection {
        try await address.verifyTailnet()
        let c = RemoteConnection(address: address, clientName: clientName)
        let w = try await c.start(clientName: clientName, appVersion: appVersion)
        c.welcome = w
        return c
    }

    private func start(clientName: String, appVersion: String) async throws -> MuxWelcome {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<MuxWelcome, Error>) in
            queue.async {
                self.handshake = cont
                self.transport.onData = { [weak self] d in self?.received(d) }
                self.transport.onClose = { [weak self] err in self?.transportClosed(err) }
                self.transport.start()
                // No compression: both sides then write yamux as it is. kerod
                // compresses only when the client asks (remote.Server.Serve).
                let hello = MuxHello(app: appVersion, compress: nil, client: clientName)
                var line = (try? JSONEncoder().encode(hello)) ?? Data()
                line.append(0x0a)
                self.transport.write(line)
                self.queue.asyncAfter(deadline: .now() + 20) { [weak self] in
                    guard let self, let h = self.handshake else { return }
                    self.handshake = nil
                    self.transport.close()
                    h.resume(throwing: RemoteError.handshakeTimeout)
                }
            }
        }
    }

    private func received(_ data: Data) {
        if let mux {
            mux.receive(data)
            return
        }
        // Before the welcome: lines, the first of which carrying {"mux":
        // is it (remote.readWelcome skips what a login printed).
        do {
            for line in try lines.append(data) {
                if let r = line.range(of: Data(#"{"mux":"#.utf8)),
                   let w = try? JSONDecoder().decode(MuxWelcome.self, from: line.subdata(in: r.lowerBound..<line.endIndex)) {
                    let rest = lines.takeRest()
                    welcomed(w, rest: rest)
                    return
                }
                junkLines += 1
                if junk.count < 200 { junk.append(line) }
                if junkLines >= 100 {
                    failHandshake(RemoteError.notKero(String(decoding: junk.prefix(200), as: UTF8.self)))
                    return
                }
            }
        } catch {
            failHandshake(error)
        }
    }

    private func welcomed(_ w: MuxWelcome, rest: Data) {
        guard let h = handshake else { return }
        handshake = nil
        if !w.error.isEmpty {
            transport.close()
            h.resume(throwing: RemoteError.daemon(w.error))
            return
        }
        if w.mux != KeroProtocol.muxVersion {
            transport.close()
            h.resume(throwing: RemoteError.version(host: w.host.kero))
            return
        }
        if !w.compress.isEmpty {
            transport.close()
            h.resume(throwing: RemoteError.notKero("compression \(w.compress) this app did not ask for"))
            return
        }
        let m = YamuxSession(queue: queue, write: { [weak self] d in self?.transport.write(d) },
                             onClose: { [weak self] err in self?.muxClosed(err) })
        mux = m
        m.start()
        if !rest.isEmpty { m.receive(rest) }
        h.resume(returning: w)
    }

    private func failHandshake(_ err: Error) {
        guard let h = handshake else { return }
        handshake = nil
        transport.close()
        h.resume(throwing: err)
    }

    private func transportClosed(_ err: Error?) {
        if handshake != nil {
            failHandshake(err ?? RemoteError.closed)
            return
        }
        mux?.close(err ?? RemoteError.closed)
    }

    private func muxClosed(_ err: Error?) {
        guard !ended else { return }
        ended = true
        transport.close()
        let h = onClose
        onClose = nil
        h?(err)
    }

    /// Opens a stream to kerod and writes its Hello. Call on the queue.
    func openStream(_ hello: Hello) throws -> YamuxStream {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let mux, !ended else { throw RemoteError.closed }
        let s = try mux.openStream()
        var line = try JSONEncoder().encode(hello)
        line.append(0x0a)
        s.write(line)
        return s
    }

    /// Measures the round trip to the host.
    func ping() async -> TimeInterval? {
        await withCheckedContinuation { cont in
            queue.async {
                guard let mux = self.mux else { cont.resume(returning: nil); return }
                mux.ping { cont.resume(returning: $0) }
            }
        }
    }

    /// Ends the connection and every stream of it.
    func close() {
        queue.async {
            if let mux = self.mux { mux.close(nil) } else { self.failHandshake(RemoteError.closed); self.transport.close() }
        }
    }
}

// MARK: - Control connection

/// proto.Request.
private struct ControlRequest<Q: Encodable>: Encodable {
    var id: Int64
    var method: String
    var params: Q?
}

/// A control connection (client.Client): requests and their responses, and
/// once subscribed, events, as JSON lines.
final class ControlClient: @unchecked Sendable {
    private let conn: RemoteConnection
    private var stream: YamuxStream?
    private var lines = LineSplitter(maxLine: KeroProtocol.maxLine)
    private var welcome: CheckedContinuation<Welcome, Error>?
    private var welcomed = false
    private var nextID: Int64 = 0
    private var pending: [Int64: CheckedContinuation<Data, Error>] = [:]
    private var closed = false

    /// Events (proto.Message with Event set), on the connection's queue.
    var onEvent: ((String, Data) -> Void)?
    /// The connection ended.
    var onClose: ((Error?) -> Void)?

    init(connection: RemoteConnection) { conn = connection }

    /// Opens the stream and reads kerod's Welcome.
    func start(clientName: String) async throws -> Welcome {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Welcome, Error>) in
            conn.queue.async {
                do {
                    let s = try self.conn.openStream(Hello(kind: "control", client: clientName))
                    self.stream = s
                    self.welcome = cont
                    s.onData = { [weak self] d in self?.received(d) }
                    s.onClose = { [weak self] err in self?.ended(err ?? RemoteError.closed) }
                    self.conn.queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                        guard let self, let w = self.welcome else { return }
                        self.welcome = nil
                        w.resume(throwing: RemoteError.handshakeTimeout)
                        self.close()
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func received(_ data: Data) {
        let got: [Data]
        do { got = try lines.append(data) } catch { ended(error); return }
        for line in got where !line.isEmpty {
            if !welcomed {
                welcomed = true
                guard let w = try? JSONDecoder().decode(Welcome.self, from: line) else {
                    fail(welcome: RemoteError.notKero(String(decoding: line.prefix(200), as: UTF8.self)))
                    return
                }
                if w.version != KeroProtocol.version {
                    fail(welcome: RemoteError.protocolVersion(daemon: w.version))
                } else if !w.error.isEmpty {
                    fail(welcome: RemoteError.daemon(w.error))
                } else {
                    welcome?.resume(returning: w)
                    welcome = nil
                }
                continue
            }
            handle(line)
        }
    }

    private func fail(welcome err: Error) {
        welcome?.resume(throwing: err)
        welcome = nil
        close()
    }

    private struct Envelope: Decodable {
        var id: Int64?
        var error: String?
        var event: String?
    }

    private func handle(_ line: Data) {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: line) else { return }
        if let event = env.event, !event.isEmpty {
            onEvent?(event, line)
            return
        }
        guard let id = env.id, let cont = pending.removeValue(forKey: id) else { return }
        if let e = env.error, !e.isEmpty {
            cont.resume(throwing: RemoteError.daemon(e))
        } else {
            cont.resume(returning: line)
        }
    }

    /// Calls a method, returning the response's line, whose "result" holds
    /// the result.
    @discardableResult
    func call<P: Encodable & Sendable>(_ method: String, _ params: P?) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            conn.queue.async {
                guard let s = self.stream, !self.closed else { cont.resume(throwing: RemoteError.closed); return }
                self.nextID += 1
                let id = self.nextID
                do {
                    var line = try JSONEncoder().encode(ControlRequest(id: id, method: method, params: params))
                    line.append(0x0a)
                    self.pending[id] = cont
                    s.write(line)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func call(_ method: String) async throws {
        struct None: Encodable, Sendable {}
        try await call(method, Optional<None>.none)
    }

    func close() {
        conn.queue.async { self.ended(nil) }
    }

    private func ended(_ err: Error?) {
        guard !closed else { return }
        closed = true
        stream?.reset()
        stream = nil
        welcome?.resume(throwing: err ?? RemoteError.closed)
        welcome = nil
        for (_, c) in pending { c.resume(throwing: err ?? RemoteError.closed) }
        pending.removeAll()
        let h = onClose
        onClose = nil
        onEvent = nil
        h?(err)
    }
}

// MARK: - Attach connection

/// An attach connection: one pane's terminal as binary frames
/// (internal/proto/frame.go): a kind byte, the payload's length as a
/// big-endian uint32, the payload.
final class AttachClient: @unchecked Sendable {
    enum Frame {
        static let output: UInt8 = 0x6f   // 'o'
        static let input: UInt8 = 0x69    // 'i'
        static let resize: UInt8 = 0x72   // 'r'
        static let closed: UInt8 = 0x63   // 'c'
        static let resized: UInt8 = 0x7a  // 'z'
        static let clear: UInt8 = 0x6b    // 'k'
        static let theme: UInt8 = 0x74    // 't'
        static let claim: UInt8 = 0x6d    // 'm'
        static let maxFrame = 16 << 20
    }

    enum Event {
        case welcome(cols: Int, rows: Int)
        case output(Data)
        case resized(cols: Int, rows: Int)
        case closed
        case failed(Error)
    }

    private let conn: RemoteConnection
    private var stream: YamuxStream?
    private var buffer = Data()
    private var welcomed = false
    private var done = false

    /// Events, delivered on the main queue in order.
    var onEvent: (@MainActor (Event) -> Void)?

    init(connection: RemoteConnection) { conn = connection }

    func start(pane: String, cols: Int, rows: Int, clientName: String) {
        conn.queue.async {
            do {
                let hello = Hello(kind: "attach", session: pane, cols: cols > 0 ? cols : nil, rows: rows > 0 ? rows : nil, client: clientName)
                let s = try self.conn.openStream(hello)
                self.stream = s
                s.onData = { [weak self] d in self?.received(d) }
                s.onClose = { [weak self] err in self?.finish(err.map { Event.failed($0) } ?? .closed) }
            } catch {
                self.finish(.failed(error))
            }
        }
    }

    private func emit(_ e: Event) {
        let h = onEvent
        DispatchQueue.main.async { MainActor.assumeIsolated { h?(e) } }
    }

    private func received(_ data: Data) {
        buffer.append(data)
        if !welcomed {
            guard let nl = buffer.firstIndex(of: 0x0a) else {
                if buffer.count > 64 << 10 { finish(.failed(RemoteError.notKero("no welcome"))) }
                return
            }
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            welcomed = true
            guard let w = try? JSONDecoder().decode(Welcome.self, from: line) else {
                finish(.failed(RemoteError.notKero(String(decoding: line.prefix(200), as: UTF8.self)))); return
            }
            if w.version != KeroProtocol.version { finish(.failed(RemoteError.protocolVersion(daemon: w.version))); return }
            if !w.error.isEmpty { finish(.failed(RemoteError.daemon(w.error))); return }
            emit(.welcome(cols: w.cols, rows: w.rows))
        }
        // Consecutive output frames go to the terminal as one piece.
        var output = Data()
        while buffer.count >= 5 {
            let b = buffer.startIndex
            let kind = buffer[b]
            let n = Int(YamuxSession.u32(buffer, b + 1))
            guard n <= Frame.maxFrame else { finish(.failed(RemoteError.notKero("frame too large"))); return }
            guard buffer.count >= 5 + n else { break }
            let payload = buffer.subdata(in: (b + 5)..<(b + 5 + n))
            buffer.removeSubrange(b..<(b + 5 + n))
            switch kind {
            case Frame.output:
                output.append(payload)
            case Frame.resized where payload.count == 4:
                if !output.isEmpty { emit(.output(output)); output = Data() }
                let p = [UInt8](payload)
                emit(.resized(cols: Int(p[0]) << 8 | Int(p[1]), rows: Int(p[2]) << 8 | Int(p[3])))
            case Frame.closed:
                if !output.isEmpty { emit(.output(output)); output = Data() }
                finish(.closed)
                return
            default:
                break
            }
        }
        if !output.isEmpty { emit(.output(output)) }
        if buffer.isEmpty { buffer = Data() }
    }

    private func send(_ kind: UInt8, _ payload: Data) {
        conn.queue.async {
            guard let s = self.stream, !self.done else { return }
            var f = Data(capacity: 5 + payload.count)
            f.append(kind)
            YamuxSession.appendU32(&f, UInt32(payload.count))
            f.append(payload)
            s.write(f)
        }
    }

    func input(_ bytes: Data) {
        // proto.AppendFrames: input past a frame's bound goes in frames of
        // its own.
        var rest = bytes[...]
        while !rest.isEmpty {
            let chunk = rest.prefix(1 << 20)
            rest = rest.dropFirst(chunk.count)
            send(Frame.input, Data(chunk))
        }
    }

    /// FrameResize: cols, rows and a cell's size in pixels, uint16s.
    func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        func u16(_ v: Int, _ lo: Int) -> [UInt8] { let x = UInt16(max(lo, min(v, 0xffff))); return [UInt8(x >> 8), UInt8(x & 0xff)] }
        send(Frame.resize, Data(u16(cols, 1) + u16(rows, 1) + u16(cellWidth, 0) + u16(cellHeight, 0)))
    }

    /// FrameClaim: the user is at this terminal; the pane takes its size.
    func claim() { send(Frame.claim, Data()) }

    /// FrameClear with ClearScreen ('s').
    func clearScreen() { send(Frame.clear, Data([0x73])) }

    /// FrameTheme: foreground, background, cursor, then the 16 colors, RGBA.
    func theme(_ rgba: [[UInt8]]) {
        guard rgba.count == 19 else { return }
        send(Frame.theme, Data(rgba.flatMap { $0.count == 4 ? $0 : [0, 0, 0, 0] }))
    }

    func close() {
        conn.queue.async {
            guard !self.done else { return }
            self.done = true
            self.stream?.reset()
            self.stream = nil
            self.onEvent = nil
        }
    }

    private func finish(_ e: Event) {
        guard !done else { return }
        done = true
        stream?.reset()
        stream = nil
        emit(e)
    }
}
