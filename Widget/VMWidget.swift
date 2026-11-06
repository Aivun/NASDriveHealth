import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Button intents (run inside the widget extension)

struct StartVMIntent: AppIntent {
    static var title: LocalizedStringResource = "Start virtual machine"

    @Parameter(title: "VM ID") var vmID: Int
    @Parameter(title: "VM name") var vmName: String

    init() {}
    init(vm: VMInfo) { vmID = vm.id; vmName = vm.name }

    func perform() async throws -> some IntentResult {
        PendingStopStore.clear(vmID)
        await VMControl.perform(.start, vmID: vmID, vmName: vmName)
        return .result()
    }
}

/// First tap arms the button ("Stop?"), a second tap within 10 s shuts the VM down gracefully.
struct StopVMIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop virtual machine"

    @Parameter(title: "VM ID") var vmID: Int
    @Parameter(title: "VM name") var vmName: String

    init() {}
    init(vm: VMInfo) { vmID = vm.id; vmName = vm.name }

    func perform() async throws -> some IntentResult {
        if PendingStopStore.isPending(vmID) {
            PendingStopStore.clear(vmID)
            await VMControl.perform(.stop, vmID: vmID, vmName: vmName)
        } else {
            PendingStopStore.set(vmID)
        }
        return .result()
    }
}

// MARK: - Widget

struct VMWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NASVMWidget", provider: Provider()) { entry in
            VMWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("NAS Virtual Machines")
        .description("Start, stop and open the settings of the virtual machines on your TrueNAS.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct VMWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HealthEntry

    var body: some View {
        let maxRows = family == .systemLarge ? 8 : 3
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                Text(entry.snapshot?.hostname ?? "TrueNAS").font(.headline).lineLimit(1)
                Spacer()
                if let vms = entry.snapshot?.vms {
                    let running = vms.filter(\.isRunning).count
                    Text("\(running)/\(vms.count) running")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let snap = entry.snapshot, let vms = snap.vms {
                if vms.isEmpty {
                    Text("No virtual machines found.").font(.caption).foregroundStyle(.secondary)
                } else {
                    let sorted = snap.sortedVMs
                    ForEach(sorted.prefix(maxRows)) { vm in
                        VMRow(vm: vm, config: entry.config,
                              stopPending: entry.pendingStops.contains(vm.id),
                              showSpecs: family == .systemLarge)
                    }
                    if sorted.count > maxRows {
                        Text("+\(sorted.count - maxRows) more — use the large widget or menu bar")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if snap.canControlVMs == false {
                    Text("Read-only key: start/stop will be refused (README → VM controls).")
                        .font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
            } else {
                Text(entry.error ?? "No VM data yet.").font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                if let err = VMControl.lastError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).lineLimit(1)
                } else if let snap = entry.snapshot {
                    Text(snap.fetchedAt, style: .relative) + Text(" ago")
                }
                Spacer()
                RefreshButton()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

struct VMRow: View {
    let vm: VMInfo
    let config: NASConfig
    let stopPending: Bool
    let showSpecs: Bool

    private var stateColor: Color {
        vm.isRunning ? .green : vm.isStopped ? .gray : .orange
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(stateColor).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(vm.name).font(.caption.weight(.medium)).lineLimit(1)
                Text(showSpecs ? "\(vm.stateLabel) · \(vm.specText)" : vm.stateLabel)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)

            Button(intent: StartVMIntent(vm: vm)) {
                Image(systemName: "play.fill").frame(width: 22, height: 18)
            }
            .disabled(!vm.isStopped)
            .help("Start \(vm.name)")

            Button(intent: StopVMIntent(vm: vm)) {
                if stopPending {
                    Text("Stop?").font(.caption2.weight(.bold)).foregroundStyle(.red)
                        .frame(height: 18)
                } else {
                    Image(systemName: "stop.fill").frame(width: 22, height: 18)
                }
            }
            .disabled(!vm.isRunning)
            .help(stopPending ? "Click again to shut down \(vm.name)" : "Stop \(vm.name)")

            if let url = config.vmPageURL {
                Link(destination: url) {
                    Image(systemName: "gearshape.fill").frame(width: 22, height: 18)
                }
                .help("Open virtual machines in TrueNAS")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.caption)
    }
}
