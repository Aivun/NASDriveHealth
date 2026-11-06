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

    func saveConfig(_ new: NASConfig) {
        config = new
        new.save()
        reschedule()
    }
}

struct MenuContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

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
