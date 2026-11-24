import AppKit
import LabTunnelControl
import SwiftUI

struct MenuContent: View {
    let manager: TunnelManager
    let popoverModel: PopoverModel
    /// Reports when the editor or an active search owns the Esc key.
    var onEditingChange: (Bool) -> Void = { _ in }
    /// nil = showing the list; non-nil = showing the editor for that tunnel.
    @State private var editing: Tunnel?
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var setupStatus = AgentSetup.status(appBundle: Bundle.main.bundleURL)
    @State private var searchQuery = ""
    @State private var showSearchBar = false
    @FocusState private var isSearchFocused: Bool

    private var activeCount: Int {
        manager.tunnels.filter { manager.state(of: $0).isActive }.count
    }

    private var reconnectingCount: Int {
        manager.tunnels.filter { manager.state(of: $0) == .reconnecting }.count
    }

    private var shouldShowSearch: Bool {
        manager.tunnels.count >= 6 || showSearchBar
    }

    private var isSearching: Bool {
        !searchQuery.isEmpty || (showSearchBar && manager.tunnels.count < 6)
    }

    private var filteredSections: [TunnelSection] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return manager.sections }
        return manager.sections.compactMap { section in
            let matched = section.tunnels.filter { matchesSearch($0, query: query) }
            return matched.isEmpty ? nil : TunnelSection(name: section.name, tunnels: matched)
        }
    }

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
        .frame(width: 350)
        .onAppear(perform: refreshSystemStatus)
        .onChange(of: popoverModel.openCount) { _, _ in refreshSystemStatus() }
        .onChange(of: editing != nil || isSearching) { _, active in onEditingChange(active) }
    }

    private var list: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if shouldShowSearch {
                searchBar
                Divider()
            }
            if manager.tunnels.isEmpty {
                Text("No tunnels yet.\nAdd a host and port to get started.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else if filteredSections.isEmpty {
                VStack(spacing: 6) {
                    Text("No matching tunnels.")
                        .foregroundStyle(.secondary)
                    Button("Clear Search") {
                        searchQuery = ""
                        showSearchBar = false
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filteredSections) { section in
                            if !section.name.isEmpty {
                                GroupHeader(manager: manager, section: section)
                            }
                            ForEach(section.tunnels) { tunnel in
                                TunnelRow(
                                    manager: manager,
                                    tunnel: tunnel,
                                    onEdit: { editing = tunnel },
                                    onDuplicate: {
                                        editing = Tunnel(
                                            id: UUID(),
                                            name: "",
                                            host: tunnel.host,
                                            remotePort: 0,
                                            localPort: 0,
                                            scheme: tunnel.scheme,
                                            group: tunnel.group,
                                            connectOnLaunch: tunnel.connectOnLaunch,
                                            useFreePortIfBusy: tunnel.useFreePortIfBusy,
                                            remoteHost: tunnel.remoteHost
                                        )
                                    }
                                )
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
        .background {
            Button("") {
                showSearchBar = true
                isSearchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)

            if isSearching {
                Button("") {
                    searchQuery = ""
                    showSearchBar = false
                    isSearchFocused = false
                }
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("Filter tunnels…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .focused($isSearchFocused)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("LabTunnel").font(.headline)
            if reconnectingCount > 0 {
                Text("\(reconnectingCount) reconnecting")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12), in: Capsule())
            }
            Spacer()
            if activeCount >= 2 {
                Button("Disconnect all") {
                    manager.disconnectAll()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else if manager.tunnels.count >= 2 && activeCount == 0 {
                Button("Connect all") {
                    connectAll()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
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
            .keyboardShortcut("n")
            Spacer()
            Menu {
                Toggle("Launch at Login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { enabled in
                        do {
                            try LoginItem.setEnabled(enabled)
                            if enabled && LoginItem.status == .requiresApproval {
                                showLoginItemGuidance(nil)
                            }
                        } catch {
                            NSLog("LabTunnel: login item: \(error)")
                            showLoginItemGuidance(error)
                        }
                        launchAtLogin = LoginItem.isEnabled
                    }
                ))
                if !manager.tunnels.isEmpty {
                    Divider()
                    Button("Connect All") { connectAll() }
                        .disabled(activeCount == manager.tunnels.count)
                    Button("Disconnect All") { manager.disconnectAll() }
                        .disabled(activeCount == 0)
                }
                Divider()
                Button {
                    setUpAgentTools()
                    refreshSystemStatus()
                } label: {
                    if setupStatus.isComplete {
                        Label("CLI & Agent Skill", systemImage: "checkmark")
                    } else if setupStatus.cliInstalled || setupStatus.skillInstalled {
                        Text("Update CLI & Agent Skill…")
                    } else {
                        Text("Set Up CLI & Agent Skill…")
                    }
                }
                Button("Open Config Folder") {
                    NSWorkspace.shared.open(ControlPaths.defaultDirectoryURL)
                }
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

    private func refreshSystemStatus() {
        launchAtLogin = LoginItem.isEnabled
        setupStatus = AgentSetup.status(appBundle: Bundle.main.bundleURL)
    }

    private func connectAll() {
        for tunnel in manager.tunnels where !manager.state(of: tunnel).isActive {
            manager.connect(tunnel)
        }
    }

    private func matchesSearch(_ tunnel: Tunnel, query: String) -> Bool {
        if tunnel.name.localizedCaseInsensitiveContains(query) { return true }
        if tunnel.host.localizedCaseInsensitiveContains(query) { return true }
        if tunnel.remoteHost.localizedCaseInsensitiveContains(query) { return true }
        if tunnel.group.localizedCaseInsensitiveContains(query) { return true }
        if String(tunnel.localPort).localizedCaseInsensitiveContains(query) { return true }
        if String(tunnel.remotePort).localizedCaseInsensitiveContains(query) { return true }
        let activePort = manager.localPort(of: tunnel)
        return activePort != tunnel.localPort && String(activePort).localizedCaseInsensitiveContains(query)
    }
}

@MainActor
private func showLoginItemGuidance(_ error: Error?) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Launch at Login"
    alert.informativeText = LoginItem.guidance(for: error)
    alert.runModal()
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
    let onDuplicate: () -> Void

    @State private var copied = false
    @State private var copiedTask: Task<Void, Never>?

    var body: some View {
        let state = manager.state(of: tunnel)
        let remote = manager.remoteStatus(of: tunnel)
        let port = manager.localPort(of: tunnel)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color(for: state, remote: remote))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tunnel.name).fontWeight(.medium)
                    HStack(spacing: 6) {
                        Text(verbatim: tunnel.route(localPort: port))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if state.isActive && port != tunnel.localPort {
                            Text(verbatim: "preferred \(tunnel.localPort)")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                        }
                    }
                    if state == .connected, let traffic = manager.traffic[tunnel.id] {
                        Text(TrafficFormat.summary(traffic))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if copied {
                    Text("Copied")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.green)
                }
                if state == .connected {
                    if let url = tunnel.url(localPort: port) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderless)
                        .help("Open in Browser")
                    } else {
                        Button {
                            copy("127.0.0.1:\(port)")
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy Address")
                    }
                }
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
                    if case .failed(let message) = state {
                        Button("Copy Error") { copy(message) }
                    }
                    Divider()
                    Button("Duplicate…", action: onDuplicate)
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
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(message)
                .padding(.leading, 16)
        case (.reconnecting, _):
            Text("Connection lost. Reconnecting…")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.leading, 16)
        case (.connected, .notListening):
            Text(verbatim: "Connected, but nothing is listening on remote port \(tunnel.remotePort).")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
                .padding(.leading, 16)
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
        copied = true
        copiedTask?.cancel()
        copiedTask = Task {
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}

private struct TunnelEditor: View {
    let tunnel: Tunnel
    let isNew: Bool
    let onSave: (Tunnel) -> Void
    let onCancel: () -> Void
    let isNameTaken: (String) -> Bool

    private let knownHosts: [String]
    private let knownGroups: [String]

    @State private var sshHosts: [String] = []
    @State private var name: String
    @State private var group: String
    @State private var host: String
    @State private var remoteHost: String
    @State private var remotePort: String
    @State private var localPort: String
    @State private var scheme: Scheme
    @State private var useFreePortIfBusy: Bool
    @State private var connectOnLaunch: Bool
    @State private var advancedExpanded: Bool
    @State private var error: String?

    init(tunnel: Tunnel, isNew: Bool, knownHosts: [String], knownGroups: [String],
         isNameTaken: @escaping (String) -> Bool,
         onSave: @escaping (Tunnel) -> Void, onCancel: @escaping () -> Void) {
        self.tunnel = tunnel
        self.isNew = isNew
        self.onSave = onSave
        self.onCancel = onCancel
        self.isNameTaken = isNameTaken
        self.knownHosts = knownHosts
        self.knownGroups = knownGroups
        let hasCustomRemoteHost = tunnel.remoteHost != "127.0.0.1"
        _name = State(initialValue: tunnel.name)
        _group = State(initialValue: tunnel.group)
        _host = State(initialValue: tunnel.host)
        _remoteHost = State(initialValue: hasCustomRemoteHost ? tunnel.remoteHost : "")
        _remotePort = State(initialValue: isNew ? "" : String(tunnel.remotePort))
        _localPort = State(initialValue: isNew ? "" : String(tunnel.localPort))
        _scheme = State(initialValue: tunnel.scheme)
        _useFreePortIfBusy = State(initialValue: tunnel.useFreePortIfBusy)
        _connectOnLaunch = State(initialValue: tunnel.connectOnLaunch)
        _advancedExpanded = State(initialValue: hasCustomRemoteHost)
    }

    /// Hosts already used by entries plus aliases loaded asynchronously from ~/.ssh/config.
    private var allHosts: [String] {
        Array(Set(knownHosts + sshHosts))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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

            DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                field("Remote bind") {
                    TextField("127.0.0.1", text: $remoteHost)
                }
                .padding(.top, 4)
            }

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
        .task {
            sshHosts = await Task.detached { SSHConfig.loadHostsCached() }.value
        }
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
        let trimmedRemoteHost = remoteHost.trimmingCharacters(in: .whitespaces)
        let effectiveRemoteHost = trimmedRemoteHost.isEmpty ? "127.0.0.1" : trimmedRemoteHost
        if let problem = Tunnel.validate(
            name: name,
            host: host,
            remoteHost: effectiveRemoteHost,
            remotePort: remote,
            localPort: local
        ) {
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
        updated.remoteHost = effectiveRemoteHost
        updated.remotePort = remote!
        updated.localPort = local!
        updated.scheme = scheme
        updated.useFreePortIfBusy = useFreePortIfBusy
        updated.connectOnLaunch = connectOnLaunch
        onSave(updated)
    }
}
