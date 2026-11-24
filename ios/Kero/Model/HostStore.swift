import Foundation
import Observation

/// A saved host (settings.Host): a name, how to reach it, and its color.
struct HostConfig: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var name: String
    var address: String
    /// One of Palette.hostColorNames, or "" for the one the name picks.
    var color: String = ""

    var colorName: String { Palette.hostColorName(name: name, chosen: color) }

    /// The line of Kero's configuration file this host is, as the desktop
    /// app writes it: `host = devbox=http://devbox:7373 color=teal`.
    var configLine: String {
        var s = "host = \(name)=\(address)"
        if !color.isEmpty { s += " color=\(color)" }
        return s
    }

    /// remote.ValidName: letters, digits, dots, dashes, underscores, from a
    /// letter or digit; "local" stands for the desktop's own machine.
    static func validName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, name.lowercased() != "local" else { return false }
        for (i, c) in name.enumerated() {
            guard c.isASCII else { return false }
            let ok = c.isLetter || c.isNumber || (i > 0 && ".-_".contains(c))
            if !ok { return false }
        }
        return true
    }
}

/// The hosts the user added, in the order of Settings › Hosts, kept in the
/// app's defaults.
@MainActor
@Observable
final class HostStore {
    private(set) var hosts: [HostConfig] = []
    private let key = "kero.hosts.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let saved = try? JSONDecoder().decode([HostConfig].self, from: data) {
            hosts = saved
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(hosts) { defaults.set(data, forKey: key) }
    }

    enum StoreError: Error, LocalizedError {
        case badName(String), nameTaken(String)
        var errorDescription: String? {
            switch self {
            case .badName(let n): "“\(n)”: a name is letters, digits, dots, dashes and underscores, from a letter or digit."
            case .nameTaken(let n): "There is a host named \(n) already."
            }
        }
    }

    /// Checks a host before it is added or saved, normalizing its address.
    func validate(_ h: HostConfig, replacing id: UUID? = nil) throws -> HostConfig {
        var h = h
        h.address = try HostAddress.parse(h.address).description
        h.name = h.name.trimmingCharacters(in: .whitespaces)
        if h.name.isEmpty { h.name = (try? HostAddress.parse(h.address).label) ?? "devbox" }
        guard HostConfig.validName(h.name) else { throw StoreError.badName(h.name) }
        if hosts.contains(where: { $0.name.lowercased() == h.name.lowercased() && $0.id != id }) {
            throw StoreError.nameTaken(h.name)
        }
        return h
    }

    func add(_ h: HostConfig) throws {
        hosts.append(try validate(h))
        save()
    }

    func update(_ h: HostConfig) throws {
        let v = try validate(h, replacing: h.id)
        guard let i = hosts.firstIndex(where: { $0.id == h.id }) else { return }
        hosts[i] = v
        save()
    }

    func remove(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        save()
    }

    func move(from: IndexSet, to: Int) {
        hosts.move(fromOffsets: from, toOffset: to)
        save()
    }
}
