import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var terminals = model.terminals
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        HostsSettingsView()
                    } label: {
                        LabeledContent {
                            Text("\(model.store.hosts.count)")
                        } label: {
                            Label("Hosts", systemImage: "server.rack")
                        }
                    }
                } footer: {
                    Text("Kero on iPhone connects to kerod's own listener on each machine, over Tailscale.")
                }

                Section("Terminal") {
                    Stepper(value: $terminals.fontSize, in: 8...24, step: 1) {
                        LabeledContent("Font Size", value: "\(Int(terminals.fontSize)) pt")
                    }
                    LabeledContent("Font", value: "JetBrains Mono")
                }

                Section("About") {
                    LabeledContent("Version", value: HostConnection.appVersion)
                    LabeledContent("Protocol", value: "\(KeroProtocol.version) (mux \(KeroProtocol.muxVersion))")
                    Link(destination: URL(string: "https://github.com/egoist/kero")!) {
                        Label("Kero on GitHub", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Label("Done", systemImage: "checkmark") }
                }
            }
        }
    }
}

/// Settings › Hosts: the machines whose sessions the sidebar shows.
struct HostsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: HostConfig?
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(model.store.hosts) { cfg in
                    Button { editing = cfg } label: { HostSettingsRow(config: cfg) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { model.store.remove(cfg.id) } label: { Label("Remove", systemImage: "trash") }
                        }
                        .contextMenu {
                            Button { editing = cfg } label: { Label("Edit…", systemImage: "pencil") }
                            Button { model.host(cfg.id)?.reconnect() } label: { Label("Reconnect", systemImage: "arrow.triangle.2.circlepath") }
                            Button(role: .destructive) { model.store.remove(cfg.id) } label: { Label("Remove", systemImage: "trash") }
                        }
                }
                .onMove { model.store.move(from: $0, to: $1) }
            } footer: {
                Text("On a machine with the Kero app, turn on Settings › Hosts › Let other machines connect, and add the address it shows. On a server, set `listen = tailnet://:7373` in its configuration, or serve it over HTTPS with Tailscale Serve.")
            }
        }
        .overlay {
            if model.store.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No Hosts", systemImage: "server.rack")
                } description: {
                    Text("Add a machine that runs kerod, such as http://devbox:7373.")
                } actions: {
                    Button("Add Host…") { adding = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Hosts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("Add Host", systemImage: "plus") }
            }
            ToolbarItem(placement: .secondaryAction) { EditButton() }
        }
        .sheet(isPresented: $adding) {
            HostEditorView(original: nil)
        }
        .sheet(item: $editing) { cfg in
            HostEditorView(original: cfg)
        }
    }
}

private struct HostSettingsRow: View {
    var config: HostConfig
    @Environment(AppModel.self) private var model

    var body: some View {
        let h = model.host(config.id)
        HStack(spacing: 12) {
            Circle().fill(Palette.hostColors[config.colorName] ?? .gray).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name).font(.body.weight(.medium))
                Text(config.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                if let h { Text(status(h)).font(.caption).foregroundStyle(statusColor(h)).lineLimit(2) }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    /// hosts_settings.go's hostStatus.
    private func status(_ h: HostConnection) -> String {
        switch h.link {
        case .idle: return "Not connected"
        case .connecting: return h.loaded ? "Reconnecting…" : "Connecting…"
        case .failed(let s), .version(let s): return s
        case .connected:
            let i = h.info
            var s = "Kero \(i.kero.isEmpty ? "?" : i.kero) · \(i.os)/\(i.arch)"
            if !i.hostname.isEmpty { s += " · \(i.user.isEmpty ? "" : i.user + "@")\(i.hostname)" }
            let n = h.state.sessions.count
            if n > 0 { s += " · \(n) session\(n == 1 ? "" : "s")" }
            return s
        }
    }

    private func statusColor(_ h: HostConnection) -> Color {
        switch h.link {
        case .failed, .version: Palette.danger
        case .connected: Palette.textMuted
        default: Palette.textFaint
        }
    }
}

/// Adds a host, or edits one: its name, address and color, with a test
/// that connects and says how it went (kero hosts check).
struct HostEditorView: View {
    let original: HostConfig?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    @State private var color = ""
    @State private var error: String?
    @State private var test: TestState = .none
    @State private var confirmingRemove = false

    enum TestState: Equatable { case none, running, ok(String), failed(String) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Address", text: $address, prompt: Text("http://devbox:7373"))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    TextField("Name", text: $name, prompt: Text(defaultName))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("http:// for kerod's listener on a Tailscale address, https:// for one behind Tailscale Serve.")
                }

                Section("Color") {
                    ColorChoice(selection: $color, name: name.isEmpty ? defaultName : name)
                }

                Section {
                    Button {
                        runTest()
                    } label: {
                        HStack {
                            Label("Test Connection", systemImage: "network")
                            Spacer()
                            if test == .running { ProgressView() }
                        }
                    }
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || test == .running)
                    switch test {
                    case .ok(let s): Label(s, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
                    case .failed(let s): Label(s, systemImage: "xmark.octagon.fill").foregroundStyle(Palette.danger).font(.callout)
                    default: EmptyView()
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(Palette.danger) }
                }

                if let original {
                    Section {
                        Button("Remove Host", role: .destructive) { confirmingRemove = true }
                            .confirmationDialog("Remove \(original.name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                                Button("Remove", role: .destructive) {
                                    model.store.remove(original.id)
                                    dismiss()
                                }
                            } message: {
                                Text("Its sessions keep running on the host.")
                            }
                    }
                }
            }
            .navigationTitle(original == nil ? "Add Host" : "Edit Host")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { save() } label: { Label(original == nil ? "Add" : "Save", systemImage: "checkmark") }
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if let original {
                    name = original.name; address = original.address; color = original.color
                }
            }
        }
    }

    private var defaultName: String { (try? HostAddress.parse(address).label) ?? "devbox" }

    private var draft: HostConfig {
        HostConfig(id: original?.id ?? UUID(), name: name, address: address, color: color)
    }

    private func save() {
        do {
            if original != nil { try model.store.update(draft) } else { try model.store.add(draft) }
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func runTest() {
        error = nil
        test = .running
        let addressText = address
        Task {
            do {
                let addr = try HostAddress.parse(addressText)
                let start = Date()
                let conn = try await RemoteConnection.connect(to: addr, clientName: HostConnection.clientName, appVersion: HostConnection.appVersion)
                let ctl = ControlClient(connection: conn)
                let w = try await ctl.start(clientName: HostConnection.clientName)
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let i = conn.welcome?.host ?? HostInfo()
                ctl.close()
                conn.close()
                var s = "Connected in \(ms) ms: Kero \(w.app.isEmpty ? i.kero : w.app) on \(i.hostname.isEmpty ? addr.host : i.hostname)"
                if !i.os.isEmpty { s += " (\(i.os)/\(i.arch))" }
                if !i.peer.isEmpty { s += " as \(i.peer)" }
                test = .ok(s)
            } catch {
                test = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

private struct ColorChoice: View {
    @Binding var selection: String
    var name: String

    var body: some View {
        let auto = Palette.hostColorName(name: name, chosen: "")
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                swatch(tag: "", color: Palette.hostColors[auto] ?? .gray, label: "Automatic")
                ForEach(Palette.hostColorNames, id: \.self) { n in
                    swatch(tag: n, color: Palette.hostColors[n] ?? .gray, label: n.capitalized)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func swatch(tag: String, color: Color, label: String) -> some View {
        Button { selection = tag } label: {
            ZStack {
                Circle().fill(color).frame(width: 28, height: 28)
                if tag.isEmpty { Image(systemName: "a.circle").font(.caption.weight(.bold)).foregroundStyle(.white) }
                if selection == tag {
                    Circle().strokeBorder(Palette.text, lineWidth: 2).frame(width: 36, height: 36)
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selection == tag ? .isSelected : [])
    }
}
