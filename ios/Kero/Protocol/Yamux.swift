import Foundation

// A client of the yamux multiplexer (github.com/hashicorp/yamux v0.1.2) that
// a remote Kero connection carries its streams over (internal/remote/mux.go):
// each stream is one connection to kerod, a control or an attach connection,
// as the local socket gives them.
//
// Frames are a 12-byte header, big-endian: version (0), type, flags, stream
// id, length; a data frame's payload follows. The client opens odd stream
// ids. Every stream starts with a 256 KiB window each way, which kerod never
// grows (MaxStreamWindowSize), and a receiver hands credit back with window
// updates as it reads. kerod pings every 5 s and gives up on a link that
// answers none in 20 s; so does this side.
//
// Everything here runs on one serial queue, the connection's.

enum YamuxError: Error, LocalizedError {
    case protocolError(String)
    case timeout
    case goAway(UInt32)
    case closed
    case reset

    var errorDescription: String? {
        switch self {
        case .protocolError(let s): "The host broke the connection's protocol: \(s)"
        case .timeout: "The host stopped answering"
        case .goAway(let code): code == 0 ? "The host closed the connection" : "The host closed the connection (\(code))"
        case .closed: "The connection closed"
        case .reset: "The host reset the stream"
        }
    }
}

final class YamuxSession: @unchecked Sendable {
    enum FrameType: UInt8 { case data = 0, windowUpdate = 1, ping = 2, goAway = 3 }
    struct Flags: OptionSet {
        let rawValue: UInt16
        static let syn = Flags(rawValue: 1)
        static let ack = Flags(rawValue: 2)
        static let fin = Flags(rawValue: 4)
        static let rst = Flags(rawValue: 8)
    }

    static let headerSize = 12
    static let initialWindow: UInt32 = 256 * 1024
    /// The largest data frame this side writes: small, so that pings and
    /// other streams' frames never wait long behind one.
    static let maxChunk = 32 * 1024
    static let pingEvery: TimeInterval = 5
    static let pingTimeout: TimeInterval = 20

    let queue: DispatchQueue
    private let write: (Data) -> Void
    private let onClose: (Error?) -> Void

    private var buffer = Data()
    private var streams: [UInt32: YamuxStream] = [:]
    private var nextID: UInt32 = 1
    private(set) var isClosed = false
    private var pingTimer: DispatchSourceTimer?
    private var pingID: UInt32 = 0
    private var pingSent: [UInt32: Date] = [:]
    private var pingWaiters: [UInt32: (TimeInterval?) -> Void] = [:]
    /// When anything last came from the host: a link that brings bytes is alive.
    private var lastRead = Date()

    init(queue: DispatchQueue, write: @escaping (Data) -> Void, onClose: @escaping (Error?) -> Void) {
        self.queue = queue
        self.write = write
        self.onClose = onClose
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.pingEvery, repeating: Self.pingEvery)
        t.setEventHandler { [weak self] in self?.heartbeat() }
        t.resume()
        pingTimer = t
    }

    // MARK: Opening

    func openStream() throws -> YamuxStream {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { throw YamuxError.closed }
        let id = nextID
        nextID &+= 2
        let s = YamuxStream(id: id, session: self)
        streams[id] = s
        // A window update with SYN opens the stream, granting what the
        // window starts with already: delta 0.
        sendFrame(.windowUpdate, flags: .syn, stream: id, length: 0)
        return s
    }

    // MARK: Reading

    func receive(_ data: Data) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        lastRead = Date()
        buffer.append(data)
        while !isClosed {
            guard buffer.count >= Self.headerSize else { break }
            let base = buffer.startIndex
            let version = buffer[base]
            guard version == 0 else { return fail(YamuxError.protocolError("version \(version)")) }
            guard let type = FrameType(rawValue: buffer[base + 1]) else {
                return fail(YamuxError.protocolError("frame type \(buffer[base + 1])"))
            }
            let flags = Flags(rawValue: UInt16(buffer[base + 2]) << 8 | UInt16(buffer[base + 3]))
            let streamID = Self.u32(buffer, base + 4)
            let length = Self.u32(buffer, base + 8)
            if type == .data {
                guard buffer.count >= Self.headerSize + Int(length) else { break }
                let payload = buffer.subdata(in: (base + Self.headerSize)..<(base + Self.headerSize + Int(length)))
                buffer.removeFirst(Self.headerSize + Int(length))
                handleStreamFrame(type: type, flags: flags, id: streamID, length: length, payload: payload)
            } else {
                buffer.removeFirst(Self.headerSize)
                switch type {
                case .windowUpdate:
                    handleStreamFrame(type: type, flags: flags, id: streamID, length: length, payload: nil)
                case .ping:
                    handlePing(flags: flags, opaque: length)
                case .goAway:
                    return fail(YamuxError.goAway(length))
                case .data:
                    break
                }
            }
        }
        // Keep the buffer's storage from creeping: Data.removeFirst slides
        // its start index, which is fine, but a fresh copy now and then keeps
        // indices small.
        if buffer.isEmpty { buffer = Data() }
    }

    private func handleStreamFrame(type: FrameType, flags: Flags, id: UInt32, length: UInt32, payload: Data?) {
        if flags.contains(.syn) && streams[id] == nil {
            // kerod never opens a stream to the client; refuse one.
            sendFrame(.windowUpdate, flags: .rst, stream: id, length: 0)
            return
        }
        guard let s = streams[id] else {
            // A frame of a stream that is gone, as data in flight while it
            // closed: dropped, as yamux does.
            return
        }
        if flags.contains(.ack) { s.established = true }
        if type == .windowUpdate {
            s.grant(length)
        } else if let payload, !payload.isEmpty {
            s.deliver(payload)
        }
        if flags.contains(.rst) {
            s.remoteReset()
            streams[id] = nil
        } else if flags.contains(.fin) {
            s.remoteFinished()
            if s.isFullyClosed { streams[id] = nil }
        }
    }

    private func handlePing(flags: Flags, opaque: UInt32) {
        if flags.contains(.syn) {
            sendFrame(.ping, flags: .ack, stream: 0, length: opaque)
        } else if flags.contains(.ack) {
            let rtt = pingSent.removeValue(forKey: opaque).map { Date().timeIntervalSince($0) }
            pingWaiters.removeValue(forKey: opaque)?(rtt)
        }
    }

    private func heartbeat() {
        guard !isClosed else { return }
        let now = Date()
        if let oldest = pingSent.values.min(), now.timeIntervalSince(oldest) > Self.pingTimeout,
           now.timeIntervalSince(lastRead) > Self.pingTimeout {
            return fail(YamuxError.timeout)
        }
        ping(nil)
    }

    /// Pings the host, calling back with the round trip, or nil once the
    /// connection ends first.
    func ping(_ done: ((TimeInterval?) -> Void)?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { done?(nil); return }
        pingID &+= 1
        pingSent[pingID] = Date()
        if let done { pingWaiters[pingID] = done }
        sendFrame(.ping, flags: .syn, stream: 0, length: pingID)
    }

    // MARK: Writing

    fileprivate func sendFrame(_ type: FrameType, flags: Flags, stream: UInt32, length: UInt32, payload: Data? = nil) {
        guard !isClosed else { return }
        var frame = Data(capacity: Self.headerSize + (payload?.count ?? 0))
        frame.append(0)
        frame.append(type.rawValue)
        frame.append(UInt8(flags.rawValue >> 8))
        frame.append(UInt8(flags.rawValue & 0xff))
        Self.appendU32(&frame, stream)
        Self.appendU32(&frame, length)
        if let payload { frame.append(payload) }
        write(frame)
    }

    fileprivate func forget(_ id: UInt32) { streams[id] = nil }

    // MARK: Closing

    /// Ends the session and every stream of it; err nil for one this side
    /// ended.
    func close(_ err: Error? = nil) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return }
        if err == nil {
            sendFrame(.goAway, flags: [], stream: 0, length: 0)
        }
        isClosed = true
        pingTimer?.cancel()
        pingTimer = nil
        let all = streams.values
        streams.removeAll()
        for s in all { s.sessionEnded(err ?? YamuxError.closed) }
        for (_, w) in pingWaiters { w(nil) }
        pingWaiters.removeAll()
        onClose(err)
    }

    private func fail(_ err: Error) { close(err) }

    // MARK: Bytes

    static func u32(_ d: Data, _ i: Int) -> UInt32 {
        UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }

    static func appendU32(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v >> 24)); d.append(UInt8((v >> 16) & 0xff)); d.append(UInt8((v >> 8) & 0xff)); d.append(UInt8(v & 0xff))
    }
}

/// One stream of a yamux session. Its handlers run on the session's queue.
final class YamuxStream: @unchecked Sendable {
    let id: UInt32
    private weak var session: YamuxSession?

    /// Data as it arrives, in order.
    var onData: ((Data) -> Void)?
    /// The stream ended: nil when the host finished it cleanly.
    var onClose: ((Error?) -> Void)?

    fileprivate(set) var established = false
    private var sendWindow = YamuxSession.initialWindow
    private var pending = Data()
    /// What was read since credit was last handed back.
    private var unacked: UInt32 = 0
    private var localFinished = false
    private var finishPending = false
    private var remoteFinishedFlag = false
    private var ended = false

    fileprivate init(id: UInt32, session: YamuxSession) {
        self.id = id
        self.session = session
    }

    var isFullyClosed: Bool { localFinished && remoteFinishedFlag }

    /// Writes data, as the window lets it: what doesn't fit waits for credit.
    func write(_ data: Data) {
        guard let session, !ended, !localFinished, !finishPending else { return }
        dispatchPrecondition(condition: .onQueue(session.queue))
        pending.append(data)
        flush()
    }

    /// Ends the writing half once what is pending is out (FIN).
    func close() {
        guard let session, !ended, !localFinished else { return }
        dispatchPrecondition(condition: .onQueue(session.queue))
        finishPending = true
        flush()
    }

    /// Ends the stream at once both ways (RST), as a client that is done
    /// with an attach connection does.
    func reset() {
        guard let session, !ended else { return }
        dispatchPrecondition(condition: .onQueue(session.queue))
        session.sendFrame(.windowUpdate, flags: .rst, stream: id, length: 0)
        ended = true
        pending.removeAll()
        session.forget(id)
        let h = onClose
        onClose = nil
        onData = nil
        h?(nil)
    }

    private func flush() {
        guard let session else { return }
        while !pending.isEmpty && sendWindow > 0 {
            let n = min(pending.count, Int(sendWindow), YamuxSession.maxChunk)
            let chunk = pending.prefix(n)
            pending.removeFirst(n)
            if pending.isEmpty { pending = Data() }
            sendWindow -= UInt32(n)
            session.sendFrame(.data, flags: [], stream: id, length: UInt32(n), payload: Data(chunk))
        }
        if finishPending && pending.isEmpty && !localFinished {
            finishPending = false
            localFinished = true
            session.sendFrame(.windowUpdate, flags: .fin, stream: id, length: 0)
            if isFullyClosed { session.forget(id) }
        }
    }

    fileprivate func grant(_ delta: UInt32) {
        sendWindow &+= delta
        flush()
    }

    fileprivate func deliver(_ data: Data) {
        guard !ended else { return }
        onData?(data)
        // Read at once: hand the credit back once half the window is used,
        // as yamux does.
        unacked &+= UInt32(data.count)
        if unacked >= YamuxSession.initialWindow / 2, let session {
            session.sendFrame(.windowUpdate, flags: [], stream: id, length: unacked)
            unacked = 0
        }
    }

    fileprivate func remoteFinished() {
        remoteFinishedFlag = true
        end(nil)
    }

    fileprivate func remoteReset() {
        end(YamuxError.reset)
    }

    fileprivate func sessionEnded(_ err: Error) {
        end(err)
    }

    private func end(_ err: Error?) {
        guard !ended else { return }
        ended = true
        let h = onClose
        onClose = nil
        onData = nil
        h?(err)
    }
}

/// Splits a byte stream into lines.
struct LineSplitter {
    private var buffer = Data()
    let maxLine: Int

    init(maxLine: Int) { self.maxLine = maxLine }

    /// Appends bytes and returns the lines they complete, without their
    /// newlines; throws on a line past maxLine.
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0a) {
            lines.append(buffer.subdata(in: buffer.startIndex..<nl))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        if buffer.count > maxLine { throw YamuxError.protocolError("line too long") }
        if buffer.isEmpty { buffer = Data() }
        return lines
    }

    /// What is left after the last newline, taking it out.
    mutating func takeRest() -> Data {
        defer { buffer = Data() }
        return buffer
    }
}
