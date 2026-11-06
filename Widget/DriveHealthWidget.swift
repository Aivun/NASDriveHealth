import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline

struct HealthEntry: TimelineEntry {
    let date: Date
    let snapshot: HealthSnapshot?
    let error: String?
    let config: NASConfig
    var pendingActions: Set<String> = []
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> HealthEntry {
        HealthEntry(date: .now, snapshot: .preview, error: nil, config: NASConfig())
    }

    func getSnapshot(in context: Context, completion: @escaping (HealthEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(HealthEntry(date: .now, snapshot: SnapshotStore.load(),
                                   error: SnapshotStore.lastError, config: NASConfig.load()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HealthEntry>) -> Void) {
        Task {
            let config = NASConfig.load()
            let pending = PendingActionStore.active
            var entry: HealthEntry
            // The menu bar app refreshes on its own schedule and then reloads the widget;
            // if its data is fresh (or a Stop/Restart confirmation is showing), skip hitting the NAS.
            if let cached = SnapshotStore.load(),
               !pending.isEmpty || Date().timeIntervalSince(cached.fetchedAt) < 90 {
                entry = HealthEntry(date: .now, snapshot: cached, error: SnapshotStore.lastError, config: config)
            } else {
                let outcome = await HealthService.refreshAndStore()
                entry = HealthEntry(date: .now, snapshot: outcome.snapshot, error: outcome.error, config: config)
            }
            entry.pendingActions = pending
            var entries = [entry]
            if !pending.isEmpty {
                // Drop the "Stop?" confirmation once its window has passed.
                var cleared = entry
                cleared.pendingActions = []
                entries.append(HealthEntry(date: Date().addingTimeInterval(PendingActionStore.window),
                                           snapshot: cleared.snapshot, error: cleared.error,
                                           config: cleared.config))
            }
            let next = Date().addingTimeInterval(Double(max(5, config.refreshMinutes)) * 60)
            completion(Timeline(entries: entries, policy: .after(next)))
        }
    }
}

// MARK: - Interactive refresh button (macOS 14+)

struct RefreshDrivesIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh drive health"
    func perform() async throws -> some IntentResult {
        _ = await HealthService.refreshAndStore()   // timeline reloads automatically afterwards
        return .result()
    }
}

// MARK: - Widget

@main
struct DriveHealthWidgetBundle: WidgetBundle {
    var body: some Widget {
        DriveHealthWidget()
        VMWidget()
    }
}

struct DriveHealthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DriveHealthWidget", provider: Provider()) { entry in
            DriveHealthView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("NAS Drive Health")
        .description("Health, temperature and ZFS errors of the drives in your TrueNAS.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct DriveHealthView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HealthEntry

    var body: some View {
        if let snap = entry.snapshot {
            switch family {
            case .systemSmall: SmallView(snap: snap, entry: entry)
            case .systemLarge: ListView(snap: snap, entry: entry, maxRows: 11, showModel: true)
            default: ListView(snap: snap, entry: entry, maxRows: 4, showModel: false)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("NAS Drive Health", systemImage: "externaldrive.badge.questionmark")
                    .font(.headline)
                Text(entry.error ?? "Waiting for first update…")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                RefreshButton()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private func isStale(_ snap: HealthSnapshot, _ config: NASConfig) -> Bool {
    Date().timeIntervalSince(snap.fetchedAt) > Double(max(5, config.refreshMinutes)) * 60 * 3
}

struct RefreshButton: View {
    var body: some View {
        Button(intent: RefreshDrivesIntent()) {
            Image(systemName: "arrow.clockwise").font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

struct FooterView: View {
    let snap: HealthSnapshot
    let entry: HealthEntry

    var body: some View {
        HStack(spacing: 4) {
            if entry.error != nil || isStale(snap, entry.config) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                Text("Offline ·")
            }
            Text(snap.fetchedAt, style: .relative) + Text(" ago")
            Spacer()
            RefreshButton()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

struct SmallView: View {
    let snap: HealthSnapshot
    let entry: HealthEntry

    var body: some View {
        let level: HealthLevel = isStale(snap, entry.config) ? .unknown : snap.level
        VStack(alignment: .leading, spacing: 4) {
            Text(snap.hostname).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: level.symbol)
                .font(.system(size: 30))
                .foregroundStyle(level.color)
            Text(level.label).font(.headline)
            Text(snap.issueCount == 0 ? "\(snap.drives.count) drives OK"
                                      : "\(snap.issueCount) of \(snap.drives.count) need attention")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            if let hot = snap.hottest {
                Text("Hottest \(hot.name) \(hot.tempText)")
                    .font(.caption2).foregroundStyle(hot.tempColor(entry.config))
            }
            Spacer(minLength: 0)
            FooterView(snap: snap, entry: entry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct ListView: View {
    let snap: HealthSnapshot
    let entry: HealthEntry
    let maxRows: Int
    let showModel: Bool

    var body: some View {
        let level: HealthLevel = isStale(snap, entry.config) ? .unknown : snap.level
        let drives = snap.sortedDrives
        let badPools = snap.pools.filter { $0.level >= .warning }
        let alertLines = showModel ? Array(snap.alerts.prefix(2)) : []
        let rows = max(1, maxRows - alertLines.count)

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: level.symbol).foregroundStyle(level.color)
                Text(snap.hostname).font(.headline).lineLimit(1)
                Spacer()
                Text(level.label).font(.caption.weight(.semibold)).foregroundStyle(level.color)
            }
            if let pool = badPools.first {
                Text("\(pool.name): \(pool.issues.first ?? pool.status)")
                    .font(.caption2).foregroundStyle(pool.level.color).lineLimit(1)
            }
            ForEach(drives.prefix(rows)) { d in
                DriveRow(drive: d, config: entry.config, showModel: showModel)
            }
            if drives.count > rows {
                Text("+\(drives.count - rows) more").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(alertLines, id: \.self) { a in
                Label(a.text, systemImage: a.level.symbol)
                    .font(.caption2).foregroundStyle(a.level.color).lineLimit(2)
            }
            Spacer(minLength: 0)
            FooterView(snap: snap, entry: entry)
        }
    }
}

// MARK: - Preview data

extension HealthSnapshot {
    static let preview = HealthSnapshot(
        hostname: "truenas", version: "TrueNAS-26.04", fetchedAt: .now,
        drives: [
            DriveHealth(name: "sda", serial: "A1", model: "WDC WD80EFZZ", kind: .hdd, sizeBytes: 8_000_000_000_000,
                        pool: "tank", zfsState: "ONLINE", readErrors: 0, writeErrors: 0, checksumErrors: 0,
                        temperature: 36, level: .ok, reasons: []),
            DriveHealth(name: "sdb", serial: "A2", model: "WDC WD80EFZZ", kind: .hdd, sizeBytes: 8_000_000_000_000,
                        pool: "tank", zfsState: "ONLINE", readErrors: 0, writeErrors: 0, checksumErrors: 0,
                        temperature: 38, level: .ok, reasons: []),
            DriveHealth(name: "nvme0n1", serial: "N1", model: "Samsung 980", kind: .nvme, sizeBytes: 1_000_000_000_000,
                        pool: "apps", zfsState: "ONLINE", readErrors: 0, writeErrors: 0, checksumErrors: 0,
                        temperature: 44, level: .ok, reasons: []),
        ],
        pools: [], alerts: [])
}
