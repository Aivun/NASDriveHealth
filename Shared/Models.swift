import Foundation

enum HealthLevel: Int, Codable, Comparable, Sendable {
    case ok = 0
    case unknown = 1
    case warning = 2
    case critical = 3

    static func < (lhs: HealthLevel, rhs: HealthLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .ok: return "Healthy"
        case .unknown: return "Unknown"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

enum DriveKind: String, Codable, Sendable {
    case hdd, ssd, nvme, unknown

    var label: String {
        switch self {
        case .hdd: return "HDD"
        case .ssd: return "SSD"
        case .nvme: return "NVMe"
        case .unknown: return "?"
        }
    }

    var isSolidState: Bool { self == .ssd || self == .nvme }
}

struct DriveHealth: Codable, Identifiable, Hashable, Sendable {
    var id: String { serial.isEmpty ? name : serial }
    let name: String            // sda, nvme0n1 …
    let serial: String
    let model: String
    let kind: DriveKind
    let sizeBytes: Int64
    let pool: String?
    let zfsState: String?       // ONLINE / DEGRADED / FAULTED … (nil = not in a pool)
    let readErrors: Int
    let writeErrors: Int
    let checksumErrors: Int
    let temperature: Double?
    let level: HealthLevel
    let reasons: [String]

    var totalErrors: Int { readErrors + writeErrors + checksumErrors }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .decimal)
    }
}

struct PoolSummary: Codable, Hashable, Sendable {
    let name: String
    let status: String
    let level: HealthLevel
    let issues: [String]
}

struct NASAlert: Codable, Hashable, Sendable {
    let level: HealthLevel
    let klass: String
    let text: String
}

struct HealthSnapshot: Codable, Sendable {
    let hostname: String
    let version: String
    let fetchedAt: Date
    let drives: [DriveHealth]
    let pools: [PoolSummary]
    let alerts: [NASAlert]
    /// nil when the VM list couldn't be read (older snapshot, or no VM support).
    var vms: [VMInfo]? = nil
    /// Whether the API key's account holds VM_WRITE / FULL_ADMIN (nil = couldn't tell).
    var canControlVMs: Bool? = nil

    var sortedVMs: [VMInfo] {
        (vms ?? []).sorted {
            if $0.isRunning != $1.isRunning { return $0.isRunning }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var level: HealthLevel {
        let all = drives.map(\.level) + pools.map(\.level) + alerts.map(\.level)
        return all.max() ?? .unknown
    }

    var issueCount: Int { drives.filter { $0.level >= .warning }.count }

    var hottest: DriveHealth? {
        drives.filter { $0.temperature != nil }.max { ($0.temperature ?? 0) < ($1.temperature ?? 0) }
    }

    /// Worst first, then natural name order (sda, sdb … nvme0n1).
    var sortedDrives: [DriveHealth] {
        drives.sorted {
            if $0.level != $1.level { return $0.level > $1.level }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

struct VMInfo: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let description: String
    let state: String          // RUNNING / STOPPED / SUSPENDED / …
    let autostart: Bool
    let vcpus: Int             // vcpus × cores × threads
    let memoryMiB: Int

    var isRunning: Bool { state == "RUNNING" }
    var isStopped: Bool { state == "STOPPED" }

    var specText: String {
        let gb = Double(memoryMiB) / 1024
        let mem = gb >= 10 || gb == gb.rounded() ? "\(Int(gb.rounded())) GB" : String(format: "%.1f GB", gb)
        return "\(vcpus) vCPU · \(mem)"
    }

    var stateLabel: String { String(state.prefix(1)) + state.dropFirst().lowercased() }
}
