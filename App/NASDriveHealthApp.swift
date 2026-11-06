import SwiftUI
import AppKit
import WidgetKit
import ServiceManagement

@main
struct NASDriveHealthApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            Image(systemName: model.level.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("NAS Drive Health Settings", id: "settings") {
            SettingsView().environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: HealthSnapshot? = SnapshotStore.load()
    @Published var lastError: String? = SnapshotStore.lastError
    @Published var isRefreshing = false
    @Published var config = NASConfig.load()
    private var timer: Timer?

    private var queueTimer: Timer?

    init() {
        reschedule()
        Task { await refresh() }
        listenForWidgetRestarts()
    }

    /// The widget queues restarts (they take minutes) and pings us via a Darwin notification.
    /// A slow poll covers any missed ping.
    private func listenForWidgetRestarts() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let model = Unmanaged<AppModel>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in model.runQueuedRestarts() }
            },
            RestartQueue.notification as CFString, nil, .deliverImmediately)
        queueTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runQueuedRestarts() }
        }
        runQueuedRestarts()
    }

    func runQueuedRestarts() {
        for item in RestartQueue.drain() where !busyVMs.contains(item.id) {
            let vm = snapshot?.vms?.first { $0.id == item.id }
                ?? VMInfo(id: item.id, name: item.name, description: "", state: "RUNNING",
                          autostart: false, vcpus: 0, memoryMiB: 0)
            Task { await vmAction(.restart, vm) }
        }
    }

    func dismissVMMessage() {
        vmMessage = nil
        VMControl.lastError = nil
        WidgetCenter.shared.reloadAllTimelines()
    }

    var level: HealthLevel {
        guard let s = snapshot else { return .unknown }
        return lastError == nil ? s.level : max(s.level, .unknown)
    }

    func reschedule() {
        timer?.invalidate()
        let interval = Double(max(1, config.refreshMinutes)) * 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let outcome = await HealthService.refreshAndStore()
        if let s = outcome.snapshot { snapshot = s }
        lastError = outcome.error
        isRefreshing = false
        WidgetCenter.shared.reloadAllTimelines()
    }

    @Published var busyVMs: Set<Int> = []
    @Published var vmMessage: String?

    func vmAction(_ action: VMAction, _ vm: VMInfo) async {
        busyVMs.insert(vm.id)
        vmMessage = nil
        if action == .restart { WidgetCenter.shared.reloadAllTimelines() }   // show "Restarting…"
        vmMessage = await VMControl.perform(action, vmID: vm.id, vmName: vm.name)
        busyVMs.remove(vm.id)
        if let s = SnapshotStore.load() { snapshot = s }
        WidgetCenter.shared.reloadAllTimelines()
    }

    func saveConfig(_ new: NASConfig) {
        config = new
        new.save()
        reschedule()
    }
}

struct MenuContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var armed: String?   // "stop:3" / "restart:5" awaiting a second click

    /// First click arms Stop/Restart, a second click within 10 s runs it.
    private func confirmTap(_ action: VMAction, _ vm: VMInfo) {
        let tag = PendingActionStore.tag(action, vm.id)
        if armed == tag {
            armed = nil
            Task { await model.vmAction(action, vm) }
        } else {
            armed = tag
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if armed == tag { armed = nil }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: model.level.symbol).foregroundStyle(model.level.color)
                Text(model.snapshot?.hostname ?? "NAS Drive Health").font(.headline)
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.small) }
            }

            if let err = model.lastError {
                Text(err).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            if let snap = model.snapshot {
                ForEach(snap.pools.filter { $0.level >= .warning }, id: \.self) { p in
                    Text("\(p.name): \(p.issues.joined(separator: "; "))")
                        .font(.caption).foregroundStyle(p.level.color)
                }
                Divider()
                ForEach(snap.sortedDrives) { d in
                    VStack(alignment: .leading, spacing: 1) {
                        DriveRow(drive: d, config: model.config, showModel: true)
                        ForEach(d.reasons, id: \.self) { r in
                            Text(r).font(.caption2).foregroundStyle(d.level.color).padding(.leading, 13)
                        }
                    }
                }
                if let vms = snap.vms, !vms.isEmpty {
                    Divider()
                    HStack {
                        Text("Virtual machines").font(.caption.weight(.semibold))
                        Spacer()
                        if snap.canControlVMs == false {
                            Text("read-only key").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    ForEach(snap.sortedVMs) { vm in
                        MenuVMRow(vm: vm, busy: model.busyVMs.contains(vm.id) || RestartTracker.active.contains(vm.id),
                                  settingsURL: model.config.vmPageURL,
                                  stopArmed: armed == PendingActionStore.tag(.stop, vm.id),
                                  restartArmed: armed == PendingActionStore.tag(.restart, vm.id),
                                  onStart: { armed = nil; Task { await model.vmAction(.start, vm) } },
                                  onStop: { confirmTap(.stop, vm) },
                                  onRestart: { confirmTap(.restart, vm) })
                    }
                    if let msg = model.vmMessage {
                        HStack(alignment: .top, spacing: 4) {
                            Text(msg).font(.caption2).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button { model.dismissVMMessage() } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Dismiss")
                        }
                    }
                }
                if !snap.alerts.isEmpty {
                    Divider()
                    ForEach(snap.alerts, id: \.self) { a in
                        Label(a.text, systemImage: a.level.symbol)
                            .font(.caption).foregroundStyle(a.level.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                (Text("Updated ") + Text(snap.fetchedAt, style: .relative) + Text(" ago"))
                    .font(.caption2).foregroundStyle(.secondary)
            } else if model.lastError == nil {
                Text("No data yet.").font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Refresh") { Task { await model.refresh() } }
                Button(model.config.isComplete ? "Settings…" : "Set up…") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                if let url = model.config.webUIURL {
                    Button("Open TrueNAS") { NSWorkspace.shared.open(url) }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 380)
    }
}

struct MenuVMRow: View {
    let vm: VMInfo
    let busy: Bool
    let settingsURL: URL?
    let stopArmed: Bool
    let restartArmed: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(vm.isRunning ? Color.green : vm.isStopped ? Color.gray : Color.orange)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(vm.name).font(.caption.weight(.medium)).lineLimit(1)
                Text("\(vm.stateLabel) · \(vm.specText)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if busy { ProgressView().controlSize(.mini) }
            Button(action: onStart) { Image(systemName: "play.fill") }
                .disabled(!vm.isStopped || busy).help("Start")
            Button(action: onStop) {
                if stopArmed {
                    Text("Shut down?").foregroundStyle(.red)
                } else {
                    Image(systemName: "stop.fill")
                }
            }
            .disabled(!vm.isRunning || busy)
            .help(stopArmed ? "Click again to shut down \(vm.name)" : "Shut down (asks to confirm)")
            Button(action: onRestart) {
                if restartArmed {
                    Text("Restart?").foregroundStyle(.orange)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(!vm.isRunning || busy)
            .help(restartArmed ? "Click again to restart \(vm.name)" : "Restart (asks to confirm)")
            Button {
                if let settingsURL { NSWorkspace.shared.open(settingsURL) }
            } label: { Image(systemName: "gearshape.fill") }
                .disabled(settingsURL == nil).help("Open virtual machines in TrueNAS")
        }
        .controlSize(.small)
    }
}
