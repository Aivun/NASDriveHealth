import Foundation

enum VMAction: String, Sendable {
    case start, stop, restart

    var verb: String { rawValue }
}

/// Starts / stops a TrueNAS VM. Needs an API key whose account has the VM_WRITE role
/// (see README → "VM controls"). Stop is a graceful ACPI shutdown, like pressing the power button;
/// Restart is TrueNAS's vm.restart (shut down, then start again).
enum VMControl {
    private static let errorKey = "lastVMError"

    static var lastError: String? {
        get { AppGroup.defaults.string(forKey: errorKey) }
        set { AppGroup.defaults.set(newValue, forKey: errorKey) }
    }

    /// Returns an error message, or nil on success. Refreshes the stored snapshot afterwards.
    @discardableResult
    static func perform(_ action: VMAction, vmID: Int, vmName: String? = nil) async -> String? {
        let config = NASConfig.load()
        guard config.isComplete, let key = SecretStore.load(), !key.isEmpty else {
            lastError = "Not set up yet — open NAS Drive Health from the menu bar."
            return lastError
        }
        let label = vmName ?? "VM \(vmID)"
        var message: String?
        do {
            let client = try TrueNASClient(config: config)
            defer { client.close() }
            try await withTimeout(25, onTimeout: { client.close() }) {
                try await client.login(username: config.username.trimmingCharacters(in: .whitespaces),
                                       apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
                switch action {
                case .start:
                    _ = try await client.call("vm.start", [vmID])
                case .stop:
                    _ = try await client.call("vm.stop", [vmID, ["force": false, "force_after_timeout": false]])
                case .restart:
                    _ = try await client.call("vm.restart", [vmID])
                }
            }
        } catch TrueNASClient.ClientError.rpc(let code, let msg) {
            let lower = msg.lowercased()
            if code == 13 || lower.contains("not authorized") || lower.contains("permission") || lower.contains("eacces") {
                message = "Can't \(action.verb) \(label): this API key's account lacks the VM_WRITE role (see README → VM controls)."
            } else if code == 12 || lower.contains("memory") {
                message = "Can't start \(label): not enough free memory on the NAS."
            } else {
                message = "Couldn't \(action.verb) \(label): \(msg)"
            }
        } catch {
            message = "Couldn't \(action.verb) \(label): \(error.localizedDescription)"
        }
        lastError = message

        // Give the hypervisor a moment, then pull fresh state for the widget/app.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        _ = await HealthService.refreshAndStore()
        return message
    }
}
