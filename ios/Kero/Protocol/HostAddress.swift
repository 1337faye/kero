import Foundation

/// How to reach a host (remote.Addr), for the ways an iPhone can: kerod's
/// network listeners, http:// on a tailnet address and https:// behind
/// Tailscale Serve. ssh:// and wsl:// run a bridge program on the client,
/// which iOS has no way to, so they are refused with what to use instead.
struct HostAddress: Hashable, Sendable, CustomStringConvertible {
    enum Scheme: String, Sendable { case http, https }

    var scheme: Scheme
    var host: String
    var port: Int?

    enum ParseError: Error, LocalizedError {
        case empty, spaces(String), ssh(String), unsupported(String), noHost(String), path(String), port(String), password(String), badHost(String)

        var errorDescription: String? {
            switch self {
            case .empty: "Type the host's address."
            case .spaces(let s): "“\(s)”: an address has no spaces."
            case .ssh(let s): "“\(s)” is an SSH address. Kero on iPhone connects to kerod's own listener instead: on the host, turn on Settings › Hosts › Let other machines connect, and add the address it shows, such as http://devbox:7373."
            case .unsupported(let s): "“\(s)”: Kero on iPhone reaches hosts over http:// (Tailscale) or https:// (Tailscale Serve)."
            case .noHost(let s): "“\(s)” names no host."
            case .path(let s): "“\(s)”: an address has no path."
            case .port(let s): "“\(s)”: a port is 1 to 65535."
            case .password(let s): "“\(s)”: Kero takes no password in an address."
            case .badHost(let s): "“\(s)”: a host is a name of letters, digits, dots and dashes, or an IP address."
            }
        }
    }

    /// remote.ParseAddr, for the schemes above.
    static func parse(_ raw: String) throws -> HostAddress {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw ParseError.empty }
        if s.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }) { throw ParseError.spaces(s) }
        guard s.contains("://") else { throw ParseError.ssh(s) }
        guard let u = URLComponents(string: s), let scheme = u.scheme?.lowercased() else { throw ParseError.unsupported(s) }
        switch scheme {
        case "http", "https": break
        case "ssh", "wsl": throw ParseError.ssh(s)
        default: throw ParseError.unsupported(s)
        }
        if u.password != nil { throw ParseError.password(s) }
        guard var host = u.host, !host.isEmpty else { throw ParseError.noHost(s) }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if !u.path.isEmpty && u.path != "/" { throw ParseError.path(s) }
        if let p = u.port, !(1...65535).contains(p) { throw ParseError.port(s) }
        let isIP = IPAddress.parse(host) != nil
        if !isIP && (host.hasPrefix("-") || !host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) })) {
            throw ParseError.badHost(s)
        }
        return HostAddress(scheme: scheme == "https" ? .https : .http, host: host, port: u.port)
    }

    /// The port it connects to: the default listener's for http, 443 for https.
    var effectivePort: Int { port ?? (scheme == .https ? 443 : KeroProtocol.defaultPort) }

    var description: String {
        var h = host.contains(":") ? "[\(host)]" : host
        if let port { h += ":\(port)" }
        return "\(scheme.rawValue)://\(h)"
    }

    /// The WebSocket URL of kerod's mux.
    var muxURL: URL {
        var c = URLComponents()
        c.scheme = scheme == .https ? "wss" : "ws"
        c.host = host
        c.port = effectivePort
        c.path = KeroProtocol.muxPath
        return c.url!
    }

    /// remote.Addr.Label: the host's first label, the name a new host takes.
    var label: String {
        if IPAddress.parse(host) != nil { return host }
        return String(host.split(separator: ".").first ?? Substring(host))
    }

    /// For an http:// address, makes sure the host is a Tailscale peer (or
    /// this device): plain HTTP anywhere else, as to a name a LAN's DNS
    /// answers, would carry what is typed in the clear to whoever answers.
    /// remote.dialTailnet does the same.
    func verifyTailnet() async throws {
        guard scheme == .http else { return }
        let host = self.host
        let ips = try await Task.detached { try IPAddress.resolve(host) }.value
        guard ips.contains(where: \.isTailnetOrLoopback) else {
            throw TailnetError(host: host)
        }
    }

    struct TailnetError: Error, LocalizedError {
        var host: String
        var errorDescription: String? {
            "\(host) is not on your tailnet: Kero connects with plain http:// only to Tailscale addresses; use https:// with Tailscale Serve."
        }
    }
}

/// An IPv4 or IPv6 address, for the tailnet check.
struct IPAddress: Sendable {
    var bytes: [UInt8]

    static func parse(_ s: String) -> IPAddress? {
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 {
            return IPAddress(bytes: withUnsafeBytes(of: v4) { Array($0) })
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 {
            return IPAddress(bytes: withUnsafeBytes(of: v6) { Array($0) })
        }
        return nil
    }

    static func resolve(_ host: String) throws -> [IPAddress] {
        if let ip = parse(host) { return [ip] }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, nil, &hints, &res)
        guard rc == 0, let first = res else {
            throw NSError(domain: "Kero", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: "\(host): \(String(cString: gai_strerror(rc)))"])
        }
        defer { freeaddrinfo(first) }
        var out: [IPAddress] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            if ai.pointee.ai_family == AF_INET, let sa = ai.pointee.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    out.append(IPAddress(bytes: withUnsafeBytes(of: sin.pointee.sin_addr) { Array($0) }))
                }
            } else if ai.pointee.ai_family == AF_INET6, let sa = ai.pointee.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin in
                    out.append(IPAddress(bytes: withUnsafeBytes(of: sin.pointee.sin6_addr) { Array($0) }))
                }
            }
            p = ai.pointee.ai_next
        }
        return out
    }

    /// remote.tailnetAddr: 100.64.0.0/10, fd7a:115c:a1e0::/48, or loopback.
    var isTailnetOrLoopback: Bool {
        var b = bytes
        // An IPv4-mapped IPv6 address is its IPv4 address.
        if b.count == 16 && b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { b = Array(b[12...]) }
        if b.count == 4 {
            return b[0] == 127 || (b[0] == 100 && (b[1] & 0xc0) == 64)
        }
        if b.count == 16 {
            if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }
            return b[0] == 0xfd && b[1] == 0x7a && b[2] == 0x11 && b[3] == 0x5c && b[4] == 0xa1 && b[5] == 0xe0
        }
        return false
    }
}
