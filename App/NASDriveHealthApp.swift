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

    init() {
        reschedule()
        Task { await refresh() }
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
    @State private var armedStop: Int?

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
                        MenuVMRow(vm: vm, busy: model.busyVMs.contains(vm.id),
                                  settingsURL: model.config.vmPageURL,
                                  stopArmed: armedStop == vm.id,
                                  onStart: { armedStop = nil; Task { await model.vmAction(.start, vm) } },
                                  onStop: {
                                      if armedStop == vm.id {
                                          armedStop = nil
                                          Task { await model.vmAction(.stop, vm) }
                                      } else {
                                          armedStop = vm.id
                                          Task {   // disarm after 10 s
                                              try? await Task.sleep(nanoseconds: 10_000_000_000)
                                              if armedStop == vm.id { armedStop = nil }
                                          }
                                      }
                                  })
                    }
                    if let msg = model.vmMessage {
                        Text(msg).font(.caption2).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
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
    let onStart: () -> Void
    let onStop: () -> Void

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
            Button {
                if let settingsURL { NSWorkspace.shared.open(settingsURL) }
            } label: { Image(systemName: "gearshape.fill") }
                .disabled(settingsURL == nil).help("Open virtual machines in TrueNAS")
        }
        .controlSize(.small)
    }
}
