import SwiftUI
import AppKit
import ServiceManagement

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = NASConfig.load()
    @State private var apiKey = SecretStore.load() ?? ""
    @State private var status: TestStatus = .idle
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    enum TestStatus: Equatable {
        case idle, testing
        case success(String)
        case failure(String)
        case untrusted(String)
    }

    var body: some View {
        Form {
            Section("TrueNAS") {
                TextField("Host", text: $draft.host, prompt: Text("truenas.local or 192.168.1.10"))
                TextField("Username", text: $draft.username, prompt: Text("e.g. widget-monitor"))
                TextField("VM page path", text: $draft.vmPagePath, prompt: Text("/ui/vm"))
                    .help("Web UI page opened by the VM settings (gear) button")
                SecureField("API key", text: $apiKey)
                if !draft.pinnedFingerprint.isEmpty {
                    LabeledContent("Trusted certificate") {
                        HStack {
                            Text(draft.pinnedFingerprint.prefix(23) + "…")
                                .font(.system(.caption, design: .monospaced))
                            Button("Forget") { draft.pinnedFingerprint = "" }
                        }
                    }
                }
            }

            Section("Temperature thresholds (°C)") {
                thresholdRow("HDD", warn: $draft.hddWarn, crit: $draft.hddCrit)
                thresholdRow("SSD / NVMe", warn: $draft.ssdWarn, crit: $draft.ssdCrit)
            }

            Section("General") {
                Stepper("Refresh every \(draft.refreshMinutes) min", value: $draft.refreshMinutes, in: 5...120, step: 5)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section {
                HStack {
                    Button("Save & Test Connection") { Task { await test() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(status == .testing)
                    if status == .testing { ProgressView().controlSize(.small) }
                }
                statusView
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .idle, .testing:
            EmptyView()
        case .success(let msg):
            Label(msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .untrusted(let fp):
            VStack(alignment: .leading, spacing: 6) {
                Label("The NAS presented a certificate macOS doesn't trust (normal for TrueNAS's default self-signed cert). Check that this SHA-256 fingerprint matches your NAS before trusting it:",
                      systemImage: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text(fp).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Trust this certificate") {
                    draft.pinnedFingerprint = fp
                    Task { await test() }
                }
            }
        }
    }

    private func thresholdRow(_ title: String, warn: Binding<Double>, crit: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("warn", value: warn, format: .number).frame(width: 50)
            Text("warn")
            TextField("crit", value: crit, format: .number).frame(width: 50)
            Text("crit")
        }
    }

    private func test() async {
        status = .testing
        draft.host = draft.cleanHost
        model.saveConfig(draft)
        SecretStore.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        guard draft.isComplete, !apiKey.isEmpty else {
            status = .failure("Fill in host, username and API key.")
            return
        }
        do {
            let snap = try await HealthService.fetch(config: draft, apiKey: apiKey)
            var msg = "Connected to \(snap.hostname) \(snap.version) — \(snap.drives.count) drives, overall \(snap.level.label.lowercased())."
            if let vms = snap.vms {
                msg += " \(vms.count) VM\(vms.count == 1 ? "" : "s")"
                switch snap.canControlVMs {
                case .some(true): msg += " (start/stop allowed)."
                case .some(false): msg += " (read-only — see README to enable start/stop)."
                case .none: msg += "."
                }
            }
            status = .success(msg)
            await model.refresh()
        } catch TrueNASClient.ClientError.untrustedCertificate(let fp) {
            status = .untrusted(fp)
        } catch {
            status = .failure(error.localizedDescription)
        }
    }
}
