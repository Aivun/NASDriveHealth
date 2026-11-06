import Foundation

/// Pulls everything the widget needs from TrueNAS and turns it into a HealthSnapshot.
///
/// Signals used (all read-only, so a "Readonly Admin" API user is enough):
///  • disk.query        — inventory: name, model, serial, HDD/SSD, size, pool
///  • disk.temperatures — current temps (TrueNAS caches these ~5 min, so this doesn't wake disks)
///  • pool.query + boot.get_state — per-disk ZFS state and read/write/checksum error counters
///  • alert.list        — TrueNAS's own Drive Health Management alerts (SMART failures, temps, pool faults)
enum HealthService {

    struct Outcome: Sendable {
        let snapshot: HealthSnapshot?
        let error: String?
        let fromCache: Bool
    }

    /// Fetch live, store on success, fall back to the last stored snapshot on failure.
    static func refreshAndStore() async -> Outcome {
        let config = NASConfig.load()
        guard config.isComplete, let key = SecretStore.load(), !key.isEmpty else {
            return Outcome(snapshot: SnapshotStore.load(), error: "Not set up yet — open NAS Drive Health from the menu bar.", fromCache: true)
        }
        do {
            let snap = try await fetch(config: config, apiKey: key)
            SnapshotStore.save(snap)
            SnapshotStore.lastError = nil
            return Outcome(snapshot: snap, error: nil, fromCache: false)
        } catch {
            let msg = error.localizedDescription
            SnapshotStore.lastError = msg
            return Outcome(snapshot: SnapshotStore.load(), error: msg, fromCache: true)
        }
    }

    static func fetch(config: NASConfig, apiKey: String) async throws -> HealthSnapshot {
        let client = try TrueNASClient(config: config)
        defer { client.close() }
        return try await withTimeout(25, onTimeout: { client.close() }) {
            try await client.login(username: config.username.trimmingCharacters(in: .whitespaces),
                                   apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))

            let info = (try? await client.call("system.info")) as? [String: Any] ?? [:]

            let disksAny: Any
            do {
                disksAny = try await client.call("disk.query", [[], ["extra": ["pools": true]]])
            } catch {
                disksAny = try await client.call("disk.query")
            }
            let disks = disksAny as? [[String: Any]] ?? []
            let names = disks.compactMap { $0.str("name") }

            let tempsAny: Any? = try? await client.call("disk.temperatures", [names])
            let temps = parseTemperatures(tempsAny)

            var poolDicts = (try? await client.call("pool.query")) as? [[String: Any]] ?? []
            if let boot = (try? await client.call("boot.get_state")) as? [String: Any] { poolDicts.append(boot) }

            let alerts = (try? await client.call("alert.list")) as? [[String: Any]] ?? []

            return evaluate(info: info, disks: disks, temps: temps, pools: poolDicts,
                            alerts: alerts, config: config)
        }
    }

    // MARK: - Evaluation

    struct Leaf { var pool: String; var status: String; var r = 0; var w = 0; var c = 0 }

    static func evaluate(info: [String: Any], disks: [[String: Any]], temps: [String: Double],
                         pools: [[String: Any]], alerts: [[String: Any]], config: NASConfig) -> HealthSnapshot {
        // ZFS view of each member disk
        var leaves: [String: Leaf] = [:]
        var poolSummaries: [PoolSummary] = []
        for p in pools {
            let name = p.str("name") ?? "pool"
            let status = (p.str("status") ?? "UNKNOWN").uppercased()
            var issues: [String] = []
            let topology = p.dict("topology") ?? [:]
            for section in ["data", "special", "dedup", "log", "cache", "spare"] {
                walk(topology.arr(section), pool: name, leaves: &leaves, issues: &issues)
            }
            var level: HealthLevel
            switch status {
            case "ONLINE": level = .ok
            case "DEGRADED": level = .warning
            case "FAULTED", "UNAVAIL", "SUSPENDED", "REMOVED": level = .critical
            default: level = .unknown
            }
            if (p["healthy"] as? Bool) == false && level == .ok { level = .warning; issues.append("TrueNAS reports pool as unhealthy") }
            if status != "ONLINE" { issues.insert("Pool is \(status)", at: 0) }
            poolSummaries.append(PoolSummary(name: name, status: status, level: level, issues: issues))
        }

        // Relevant, active alerts
        let relevant = "smart|disk|drive|temperature|pool|zpool|vdev|nvme|scrub|resilver|device|sector"
        var nasAlerts: [NASAlert] = []
        for a in alerts {
            if (a["dismissed"] as? Bool) == true { continue }
            let lvl: HealthLevel
            switch (a.str("level") ?? "").uppercased() {
            case "CRITICAL", "ALERT", "EMERGENCY", "ERROR": lvl = .critical
            case "WARNING": lvl = .warning
            default: continue
            }
            let klass = a.str("klass") ?? ""
            let text = (a.str("formatted") ?? a.str("text") ?? klass)
                .replacingOccurrences(of: "<br>", with: " ")
            guard (klass + " " + text).range(of: relevant, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            nasAlerts.append(NASAlert(level: lvl, klass: klass, text: text))
        }

        // Per-drive verdict
        var drives: [DriveHealth] = []
        for d in disks {
            guard let name = d.str("name") else { continue }
            let serial = d.str("serial") ?? ""
            let model = (d.str("model") ?? "").trimmingCharacters(in: .whitespaces)
            let typeStr = (d.str("type") ?? "").uppercased()
            let kind: DriveKind = name.hasPrefix("nvme") ? .nvme
                : typeStr == "SSD" ? .ssd : typeStr == "HDD" ? .hdd : .unknown
            let size = d.int64("size") ?? 0
            let leaf = leaves[name]
            let pool = leaf?.pool ?? d.str("pool")
            let temp = temps[name]

            var level: HealthLevel = .ok
            var reasons: [String] = []

            if let leaf {
                switch leaf.status {
                case "ONLINE": break
                case "DEGRADED": level = max(level, .warning); reasons.append("ZFS: DEGRADED")
                case "OFFLINE": level = max(level, .warning); reasons.append("ZFS: OFFLINE")
                default: level = max(level, .critical); reasons.append("ZFS: \(leaf.status)")
                }
                let errs = leaf.r + leaf.w + leaf.c
                if errs > 0 {
                    level = max(level, .warning)
                    reasons.append("ZFS errors r/w/c \(leaf.r)/\(leaf.w)/\(leaf.c)")
                }
            }

            if let t = temp {
                let (warn, crit) = kind.isSolidState ? (config.ssdWarn, config.ssdCrit) : (config.hddWarn, config.hddCrit)
                if t >= crit { level = max(level, .critical); reasons.append("Temp \(Int(t))°C ≥ \(Int(crit))°C") }
                else if t >= warn { level = max(level, .warning); reasons.append("Temp \(Int(t))°C ≥ \(Int(warn))°C") }
            }

            let namePattern = "\\b\(NSRegularExpression.escapedPattern(for: name))\\b"
            for a in nasAlerts {
                let hit = a.text.range(of: namePattern, options: .regularExpression) != nil
                    || (!serial.isEmpty && a.text.contains(serial))
                if hit { level = max(level, a.level); reasons.append(a.text) }
            }

            drives.append(DriveHealth(
                name: name, serial: serial, model: model, kind: kind, sizeBytes: size,
                pool: pool, zfsState: leaf?.status,
                readErrors: leaf?.r ?? 0, writeErrors: leaf?.w ?? 0, checksumErrors: leaf?.c ?? 0,
                temperature: temp, level: level, reasons: reasons))
        }

        return HealthSnapshot(
            hostname: info.str("hostname") ?? "TrueNAS",
            version: info.str("version") ?? "",
            fetchedAt: Date(),
            drives: drives,
            pools: poolSummaries,
            alerts: nasAlerts)
    }

    private static func walk(_ vdevs: [[String: Any]], pool: String,
                             leaves: inout [String: Leaf], issues: inout [String]) {
        for v in vdevs {
            let children = v.arr("children")
            let isLeaf = (v.str("type") ?? "").uppercased() == "DISK" || children.isEmpty
            guard isLeaf else { walk(children, pool: pool, leaves: &leaves, issues: &issues); continue }

            let status = (v.str("status") ?? "UNKNOWN").uppercased()
            let stats = v.dict("stats") ?? [:]
            let leaf = Leaf(pool: pool, status: status,
                            r: stats.int("read_errors") ?? 0,
                            w: stats.int("write_errors") ?? 0,
                            c: stats.int("checksum_errors") ?? 0)
            if let disk = v.str("disk"), !disk.isEmpty {
                leaves[disk] = leaf
            } else if status != "ONLINE" {
                // A member that's gone entirely (pulled / dead) won't appear in disk.query.
                let path = v.str("path").map { ($0 as NSString).lastPathComponent } ?? "member"
                issues.append("Missing member \(path): \(status)")
            }
        }
    }

    /// Handles both shapes: {"sda": 34} (≤25.10) and {"sda": {"temperature": 34, …}} (newer).
    static func parseTemperatures(_ any: Any?) -> [String: Double] {
        guard let dict = any as? [String: Any] else { return [:] }
        var out: [String: Double] = [:]
        for (k, v) in dict {
            if let n = v as? NSNumber { out[k] = n.doubleValue; continue }
            if let o = v as? [String: Any] {
                for key in ["temperature", "temp", "current", "value"] {
                    if let n = o[key] as? NSNumber { out[k] = n.doubleValue; break }
                }
            }
        }
        return out
    }
}

// MARK: - Loose JSON helpers

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func int(_ k: String) -> Int? { (self[k] as? NSNumber)?.intValue }
    func int64(_ k: String) -> Int64? { (self[k] as? NSNumber)?.int64Value }
    func dict(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
    func arr(_ k: String) -> [[String: Any]] { self[k] as? [[String: Any]] ?? [] }
}
