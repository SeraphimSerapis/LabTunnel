import AppKit
import LabTunnelControl
import SwiftUI

struct MenuContent: View {
    let manager: TunnelManager
    /// Reports when the editor opens or closes, so the host knows who owns the Esc key.
    var onEditingChange: (Bool) -> Void = { _ in }
    /// nil = showing the list; non-nil = showing the editor for that tunnel.
    @State private var editing: Tunnel?
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Group {
            if let tunnel = editing {
                TunnelEditor(
                    tunnel: tunnel,
                    isNew: !manager.tunnels.contains { $0.id == tunnel.id },
                    knownHosts: manager.knownHosts,
                    knownGroups: manager.knownGroups,
                    isNameTaken: { [manager, id = tunnel.id] in manager.isNameTaken($0, except: id) },
                    onSave: { manager.save($0); editing = nil },
                    onCancel: { editing = nil }
                )
            } else {
                list
            }
        }
        .frame(width: 320)
        .onChange(of: editing != nil) { _, isEditing in onEditingChange(isEditing) }
    }

    private var list: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if manager.tunnels.isEmpty {
                Text("No tunnels yet.\nAdd a host and port to get started.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(manager.sections) { section in
                            if !section.name.isEmpty {
                                GroupHeader(manager: manager, section: section)
                            }
                            ForEach(section.tunnels) { tunnel in
                                TunnelRow(manager: manager, tunnel: tunnel, onEdit: { editing = tunnel })
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 400)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack {
            Text("LabTunnel").font(.headline)
            Spacer()
            Text(manager.connectedCount == 0 ? "None connected" : "\(manager.connectedCount) connected")
                .font(.caption)
                .foregroundStyle(manager.connectedCount == 0 ? Color.secondary : Color.green)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            Button {
                editing = Tunnel(name: "", host: "", remotePort: 0, localPort: 0)
            } label: {
                Label("Add Tunnel", systemImage: "plus")
            }
            Spacer()
            Menu {
                Toggle("Launch at Login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { enabled in
                        do { try LoginItem.setEnabled(enabled) } catch { NSLog("LabTunnel: login item: \(error)") }
                        launchAtLogin = LoginItem.isEnabled
                    }
                ))
                Button("Set Up CLI & Agent Skill…", action: setUpAgentTools)
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Links the `labtunnel` command into ~/.local/bin and installs the agent skill.
@MainActor
private func setUpAgentTools() {
    let alert = NSAlert()
    do {
        let installed = try AgentSetup.install(appBundle: Bundle.main.bundleURL)
        alert.messageText = "CLI and agent skill installed"
        alert.informativeText = """
            Command: \((installed.cliLink.path as NSString).abbreviatingWithTildeInPath)
            Skill: \((installed.skillFile.path as NSString).abbreviatingWithTildeInPath)

            Agents that read ~/.agents/skills pick the skill up in their next session.
            """
    } catch {
        alert.alertStyle = .warning
        alert.messageText = "Setup failed"
        alert.informativeText = "\(error)"
    }
    alert.runModal()
}

private struct GroupHeader: View {
    let manager: TunnelManager
    let section: TunnelSection

    var body: some View {
        let allOn = section.tunnels.allSatisfy { manager.state(of: $0).isActive }
        HStack {
            Text(section.name.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(allOn ? "Disconnect all" : "Connect all") {
                manager.setGroup(section.name, connected: !allOn)
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

private struct TunnelRow: View {
    let manager: TunnelManager
    let tunnel: Tunnel
    let onEdit: () -> Void

    var body: some View {
        let state = manager.state(of: tunnel)
        let remote = manager.remoteStatus(of: tunnel)
        let port = manager.localPort(of: tunnel)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Circle()
                    .fill(color(for: state, remote: remote))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tunnel.name).fontWeight(.medium)
                    Text(verbatim: tunnel.route(localPort: port))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if state == .connected, let traffic = manager.traffic[tunnel.id] {
                        Text(TrafficFormat.summary(traffic))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    if let url = tunnel.url(localPort: port) {
                        Button("Open in Browser") { NSWorkspace.shared.open(url) }
                            .disabled(state != .connected)
                        Button("Copy URL") { copy(url.absoluteString) }
                    } else {
                        Button("Copy Address") { copy("127.0.0.1:\(port)") }
                    }
                    Button("Re-check Remote") { manager.recheckRemote(tunnel) }
                        .disabled(state != .connected)
                    Divider()
                    Button("Edit…", action: onEdit)
                    Button("Delete", role: .destructive) { manager.delete(tunnel) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Toggle("", isOn: Binding(
                    get: { state.isActive },
                    set: { _ in manager.toggle(tunnel) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }
            note(for: state, remote: remote)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func note(for state: TunnelState, remote: RemoteStatus) -> some View {
        switch (state, remote) {
        case (.failed(let message), _):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2).padding(.leading, 18)
        case (.reconnecting, _):
            Text("Connection lost. Reconnecting…").font(.caption).foregroundStyle(.orange).padding(.leading, 18)
        case (.connected, .notListening):
            Text(verbatim: "Connected, but nothing is listening on remote port \(tunnel.remotePort).")
                .font(.caption).foregroundStyle(.orange).lineLimit(2).padding(.leading, 18)
        default:
            EmptyView()
        }
    }

    private func color(for state: TunnelState, remote: RemoteStatus) -> Color {
        switch state {
        case .idle: Color.secondary.opacity(0.4)
        case .connecting, .reconnecting: .orange
        case .connected: remote == .notListening ? .yellow : .green
        case .failed: .red
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

private struct TunnelEditor: View {
    let tunnel: Tunnel
    let isNew: Bool
    let onSave: (Tunnel) -> Void
    let onCancel: () -> Void
    let isNameTaken: (String) -> Bool

    /// Hosts already used by entries plus aliases from ~/.ssh/config.
    private let allHosts: [String]
    private let knownGroups: [String]

    @State private var name: String
    @State private var group: String
    @State private var host: String
    @State private var remotePort: String
    @State private var localPort: String
    @State private var scheme: Scheme
    @State private var useFreePortIfBusy: Bool
    @State private var connectOnLaunch: Bool
    @State private var error: String?

    init(tunnel: Tunnel, isNew: Bool, knownHosts: [String], knownGroups: [String],
         isNameTaken: @escaping (String) -> Bool,
         onSave: @escaping (Tunnel) -> Void, onCancel: @escaping () -> Void) {
        self.tunnel = tunnel
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        self.isNameTaken = isNameTaken
        self.knownGroups = knownGroups
        allHosts = Array(Set(knownHosts + SSHConfig.loadHosts()))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        _name = State(initialValue: tunnel.name)
        _group = State(initialValue: tunnel.group)
        _host = State(initialValue: tunnel.host)
        _remotePort = State(initialValue: isNew ? "" : String(tunnel.remotePort))
        _localPort = State(initialValue: isNew ? "" : String(tunnel.localPort))
        _scheme = State(initialValue: tunnel.scheme)
        _useFreePortIfBusy = State(initialValue: tunnel.useFreePortIfBusy)
        _connectOnLaunch = State(initialValue: tunnel.connectOnLaunch)
    }

    /// Hosts containing what's typed so far, excluding an exact match.
    private var suggestions: [String] {
        let typed = host.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return [] }
        return Array(allHosts.filter {
            $0.localizedCaseInsensitiveContains(typed) && $0.caseInsensitiveCompare(typed) != .orderedSame
        }.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "New Tunnel" : "Edit Tunnel").font(.headline)

            HStack(spacing: 10) {
                field("Name") { TextField("Grafana", text: $name) }
                field("Group") {
                    HStack(spacing: 4) {
                        TextField("Optional", text: $group)
                        picker(of: knownGroups) { group = $0 }
                    }
                }
            }
            field("Host") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        TextField("homelab or user@192.168.1.10", text: $host)
                        picker(of: allHosts) { host = $0 }
                    }
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button { host = suggestion } label: {
                            Text(suggestion).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .padding(.leading, 6)
                    }
                }
            }
            HStack(spacing: 10) {
                field("Remote port") { TextField("3000", text: $remotePort) }
                field("Local port") { TextField(remotePort.isEmpty ? "same" : remotePort, text: $localPort) }
            }
            field("Type") {
                Picker("", selection: $scheme) {
                    ForEach(Scheme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Toggle("Use a free port if the local port is busy", isOn: $useFreePortIfBusy)
            Toggle("Connect when LabTunnel starts", isOn: $connectOnLaunch)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .toggleStyle(.checkbox)
        .padding(12)
    }

    @ViewBuilder
    private func picker(of options: [String], choose: @escaping (String) -> Void) -> some View {
        if !options.isEmpty {
            Menu {
                ForEach(options, id: \.self) { option in
                    Button(option) { choose(option) }
                }
            } label: {
                Image(systemName: "chevron.down.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func save() {
        let remote = Int(remotePort.trimmingCharacters(in: .whitespaces))
        // An empty local port means "same as remote", which keeps OAuth-style redirects working.
        let local = localPort.trimmingCharacters(in: .whitespaces).isEmpty
            ? remote : Int(localPort.trimmingCharacters(in: .whitespaces))
        if let problem = Tunnel.validate(name: name, host: host, remotePort: remote, localPort: local) {
            error = problem
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if isNameTaken(trimmedName) {
            error = "A tunnel named '\(trimmedName)' already exists."
            return
        }
        var updated = tunnel
        updated.name = trimmedName
        updated.group = group.trimmingCharacters(in: .whitespaces)
        updated.host = host.trimmingCharacters(in: .whitespaces)
        updated.remotePort = remote!
        updated.localPort = local!
        updated.scheme = scheme
        updated.useFreePortIfBusy = useFreePortIfBusy
        updated.connectOnLaunch = connectOnLaunch
        onSave(updated)
    }
}
