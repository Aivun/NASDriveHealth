import Foundation
import Security

/// The app and the widget share settings, the API key and the last snapshot
/// through an App Group (TEAMID.nasdrivehealth — injected into Info.plist at build time).
enum AppGroup {
    static let id: String =
        (Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String) ?? "nasdrivehealth"

    static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }

    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
            return url
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NASDriveHealth", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }
}

// MARK: - Settings

struct NASConfig: Codable, Equatable, Sendable {
    var host: String = ""                 // e.g. "truenas.local" or "192.168.1.10" (port optional)
    var username: String = ""             // the TrueNAS user the API key belongs to
    var pinnedFingerprint: String = ""    // SHA-256 of the NAS's TLS cert, set when you trust a self-signed cert
    var refreshMinutes: Int = 10
    var vmPagePath: String = "/ui/vm"     // TrueNAS web UI page the VM "settings" button opens
    var hddWarn: Double = 50
    var hddCrit: Double = 58
    var ssdWarn: Double = 65
    var ssdCrit: Double = 75

    init() {}

    // Tolerant decoding so new fields never wipe saved settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NASConfig.defaultValue
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? d.username
        pinnedFingerprint = try c.decodeIfPresent(String.self, forKey: .pinnedFingerprint) ?? d.pinnedFingerprint
        refreshMinutes = try c.decodeIfPresent(Int.self, forKey: .refreshMinutes) ?? d.refreshMinutes
        vmPagePath = try c.decodeIfPresent(String.self, forKey: .vmPagePath) ?? d.vmPagePath
        hddWarn = try c.decodeIfPresent(Double.self, forKey: .hddWarn) ?? d.hddWarn
        hddCrit = try c.decodeIfPresent(Double.self, forKey: .hddCrit) ?? d.hddCrit
        ssdWarn = try c.decodeIfPresent(Double.self, forKey: .ssdWarn) ?? d.ssdWarn
        ssdCrit = try c.decodeIfPresent(Double.self, forKey: .ssdCrit) ?? d.ssdCrit
    }

    static let defaultValue = NASConfig()
    private static let key = "config"

    static func load() -> NASConfig {
        guard let data = AppGroup.defaults.data(forKey: key),
              let cfg = try? JSONDecoder().decode(NASConfig.self, from: data) else { return NASConfig() }
        return cfg
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { AppGroup.defaults.set(data, forKey: Self.key) }
    }

    var isComplete: Bool {
        !cleanHost.isEmpty && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var cleanHost: String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://", "wss://", "ws://"] where h.lowercased().hasPrefix(prefix) {
            h = String(h.dropFirst(prefix.count))
        }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        return h
    }

    /// Always TLS: TrueNAS revokes a user-linked API key the first time it is sent over plain HTTP.
    var webSocketURL: URL? { cleanHost.isEmpty ? nil : URL(string: "wss://\(cleanHost)/api/current") }
    var webUIURL: URL? { cleanHost.isEmpty ? nil : URL(string: "https://\(cleanHost)/") }

    var vmPageURL: URL? {
        guard !cleanHost.isEmpty else { return nil }
        var path = vmPagePath.trimmingCharacters(in: .whitespaces)
        if path.isEmpty { path = NASConfig.defaultValue.vmPagePath }
        if !path.hasPrefix("/") { path = "/" + path }
        return URL(string: "https://\(cleanHost)\(path)")
    }
}

// MARK: - API key

enum SecretStore {
    private static let service = "NASDriveHealth.apiKey"
    private static var fileURL: URL { AppGroup.containerURL.appendingPathComponent(".apikey") }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "truenas",
         kSecAttrAccessGroup as String: AppGroup.id,
         kSecUseDataProtectionKeychain as String: true]
    }

    static func save(_ key: String) {
        SecItemDelete(baseQuery as CFDictionary)
        try? FileManager.default.removeItem(at: fileURL)
        guard !key.isEmpty else { return }

        var add = baseQuery
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { return }

        // Fallback (e.g. keychain sharing not available with this signing setup):
        // a 0600 file inside the sandboxed App Group container.
        try? Data(key.utf8).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data {
            return String(decoding: data, as: UTF8.self)
        }
        if let s = try? String(contentsOf: fileURL, encoding: .utf8), !s.isEmpty { return s }
        return nil
    }
}

// MARK: - Last snapshot

enum SnapshotStore {
    private static var url: URL { AppGroup.containerURL.appendingPathComponent("snapshot.json") }
    private static let errorKey = "lastError"

    static func save(_ snapshot: HealthSnapshot) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }

    static func load() -> HealthSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(HealthSnapshot.self, from: data)
    }

    static var lastError: String? {
        get { AppGroup.defaults.string(forKey: errorKey) }
        set { AppGroup.defaults.set(newValue, forKey: errorKey) }
    }
}

// MARK: - Two-tap confirmation (Stop) for widget buttons

enum PendingActionStore {
    private static let key = "pendingVMActions"
    static let window: TimeInterval = 10

    static func tag(_ action: VMAction, _ id: Int) -> String { "\(action.rawValue):\(id)" }

    private static var all: [String: Double] {
        get { AppGroup.defaults.dictionary(forKey: key) as? [String: Double] ?? [:] }
        set { AppGroup.defaults.set(newValue, forKey: key) }
    }

    /// Tags (e.g. "stop:3") whose button was tapped once within the confirmation window.
    static var active: Set<String> {
        let now = Date().timeIntervalSince1970
        return Set(all.compactMap { k, t in now - t < window ? k : nil })
    }

    static func isPending(_ action: VMAction, _ id: Int) -> Bool { active.contains(tag(action, id)) }

    /// Arms one action for a VM (disarming any other armed action on that VM).
    static func arm(_ action: VMAction, _ id: Int) {
        var a = all.filter { !$0.key.hasSuffix(":\(id)") }
        a[tag(action, id)] = Date().timeIntervalSince1970
        all = a
    }

    static func clear(_ id: Int) { all = all.filter { !$0.key.hasSuffix(":\(id)") } }
}

