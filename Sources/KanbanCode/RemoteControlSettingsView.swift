import AppKit
import CoreImage.CIFilterBuiltins
import KanbanCodeCore
import KanbanCodeRemoteKit
import SwiftUI

/// Settings > Remote Control: the server phones and other agents use to
/// drive this Mac over Tailscale (docs/remote-control.md).
struct RemoteControlSettingsView: View {
    @State private var controller = RemoteControlController.shared
    @State private var enabled = false
    @State private var portText = String(RemoteAPI.defaultPort)
    @State private var loaded = false
    @State private var showAddDevice = false
    private let settingsStore = SettingsStore()

    var body: some View {
        Form {
            Section("Server") {
                Toggle("Allow remote control", isOn: $enabled)
                    .onChange(of: enabled) { save() }
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("", text: $portText)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onSubmit { save() }
                }
                statusRow
                Text("The server listens on this Mac (127.0.0.1) and on its Tailscale addresses only, never on the local network. Every request needs the token of a paired device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if controller.isRunning {
                Section("Addresses") {
                    ForEach(urls, id: \.self) { url in
                        HStack {
                            Text(url)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            copyButton(url)
                        }
                    }
                    if !hasTailscale {
                        Text("Tailscale is not connected, so only this Mac can reach the server. Start Tailscale and the server listens on its address too.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let name = controller.magicDNSName {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("For HTTPS with a valid certificate, run once:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Text(serveCommand)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Spacer()
                                copyButton(serveCommand)
                            }
                            Text("Then use https://\(name):\(controller.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section {
                if controller.devices.isEmpty {
                    Text("No paired devices.")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.devices) { device in
                    HStack {
                        Image(systemName: device.scope == .full ? "iphone" : (device.scope == .agent ? "cpu" : "server.rack"))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(deviceDetail(device))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke", role: .destructive) {
                            controller.revoke(deviceId: device.id)
                        }
                        .controlSize(.small)
                    }
                }
                HStack {
                    Spacer()
                    Button("Add Device…") { showAddDevice = true }
                }
            } header: {
                Text("Devices")
            } footer: {
                Text("To pair from a terminal on this Mac: `kanban remote pair --name <name> --scope agent`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            PeersSettingsSection()
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showAddDevice) {
            AddRemoteDeviceSheet(controller: controller, isPresented: $showAddDevice)
        }
        .task {
            let settings = (try? await settingsStore.read())?.remoteControl ?? RemoteControlSettings()
            enabled = settings.enabled
            portText = String(settings.port)
            loaded = true
            await controller.refreshMagicDNSName()
            // The CLI pairs and revokes devices too; keep the list current.
            while !Task.isCancelled {
                controller.refreshStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(controller.isRunning ? Color.green : (controller.lastError != nil && enabled ? Color.red : Color.secondary))
                .frame(width: 8, height: 8)
            if controller.isRunning {
                Text("Listening on port \(String(controller.port))")
            } else if let error = controller.lastError, enabled {
                Text(error).foregroundStyle(.red)
            } else {
                Text("Off").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private var hasTailscale: Bool {
        controller.addresses.contains { $0 != RemoteNetworkAddresses.loopback }
    }

    private var urls: [String] {
        var out: [String] = []
        if let name = controller.magicDNSName { out.append("http://\(name):\(controller.port)") }
        for address in controller.addresses {
            out.append(address.contains(":") ? "http://[\(address)]:\(controller.port)" : "http://\(address):\(controller.port)")
        }
        return out
    }

    private var serveCommand: String {
        "tailscale serve --bg --https=\(controller.port) http://127.0.0.1:\(controller.port)"
    }

    private func deviceDetail(_ device: RemoteDevice) -> String {
        let scope = switch device.scope {
        case .full: "Full access"
        case .agent: "Agent, no terminals"
        case .peer: "Peer master, no terminals"
        case .terminal: "Terminals only"
        }
        guard let seen = device.lastSeenAt else { return "\(scope) · never seen" }
        let relative = RelativeDateTimeFormatter().localizedString(for: seen, relativeTo: Date())
        return "\(scope) · seen \(relative)"
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }

    private func save() {
        guard loaded else { return }
        let port = Int(portText.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil }
            ?? RemoteAPI.defaultPort
        portText = String(port)
        let value = RemoteControlSettings(enabled: enabled, port: port)
        Task {
            var settings = (try? await settingsStore.read()) ?? Settings()
            settings.remoteControl = value
            try? await settingsStore.write(settings)
            NotificationCenter.default.post(name: .kanbanCodeSettingsChanged, object: nil)
        }
    }
}

/// Pairs a device: asks for a name and scope, then shows the token once
/// with a QR code of the pairing link.
struct AddRemoteDeviceSheet: View {
    let controller: RemoteControlController
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var scope: RemoteScope = .full
    @State private var token: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let token {
                paired(token: token)
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder
    private var form: some View {
        Text("Add Device").font(.headline)
        TextField("Name, e.g. iPhone", text: $name)
            .textFieldStyle(.roundedBorder)
        Picker("Access", selection: $scope) {
            Text("Full: board, prompts and terminals").tag(RemoteScope.full)
            Text("Agent: board, tasks and prompts, no terminals").tag(RemoteScope.agent)
            Text("Peer master: sync, moves and approvals, no terminals").tag(RemoteScope.peer)
        }
        .pickerStyle(.radioGroup)
        if let error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        HStack {
            Spacer()
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button("Add") { add() }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private func paired(token: String) -> some View {
        let link = controller.pairLink(token: token)
        Text("\(name) is paired").font(.headline)
        Text("Scan the code with the Kanban Code app on the phone, or copy the token. It is shown only this once.")
            .font(.caption)
            .foregroundStyle(.secondary)
        HStack {
            Spacer()
            if let image = Self.qrCode(link) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
            }
            Spacer()
        }
        Text(token)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
        if !controller.isRunning {
            Text("Remote control is off: turn it on so the device can connect.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        HStack {
            Button("Copy Token") { copy(token) }
            Button("Copy Link") { copy(link) }
            Spacer()
            Button("Done") { isPresented = false }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func add() {
        do {
            let result = try controller.addDevice(name: name.trimmingCharacters(in: .whitespaces), scope: scope)
            token = result.token
        } catch {
            self.error = "Could not save the device: \(error.localizedDescription)"
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
