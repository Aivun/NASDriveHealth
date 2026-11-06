import Foundation

enum VMAction: String, Sendable {
    case start, stop, restart

    var verb: String { rawValue }
}

/// Starts / stops / restarts a TrueNAS VM. Needs an API key whose account has the VM_WRITE role
/// (see README → "VM controls"). Stop is a graceful ACPI shutdown, like pressing the power button.
enum VMControl {
    private static let errorKey = "lastVMError"

    static var lastError: String? {
        get { AppGroup.defaults.string(forKey: errorKey) }
        set { AppGroup.defaults.set(newValue, forKey: errorKey) }
    }

    private enum RestartError: Error {
        case didNotStop, vmGone
        case startFailed(Error)
    }

    /// Returns an error message, or nil on success. Refreshes the stored snapshot afterwards.
    @discardableResult
    static func perform(_ action: VMAction, vmID: Int, vmName: String? = nil) async -> String? {
        if action == .restart { return await restart(vmID: vmID, vmName: vmName) }

        guard let creds = credentials() else { return lastError }
        let (config, key) = creds
        let label = vmName ?? "VM \(vmID)"
        var message: String?
        do {
            let client = try TrueNASClient(config: config)
            defer { client.close() }
            try await withTimeout(25, onTimeout: { client.close() }) {
                try await login(client, config, key)
                if action == .start {
                    _ = try await client.call("vm.start", [vmID])
                } else {
                    _ = try await client.call("vm.stop", [vmID, ["force": false, "force_after_timeout": false]])
                }
            }
        } catch {
            message = describe(error, verb: action.verb, label: label)
        }
        lastError = message

        // Give the hypervisor a moment, then pull fresh state for the widget/app.
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        _ = await HealthService.refreshAndStore()
        return message
    }

    /// Restart done step by step instead of TrueNAS's vm.restart job, so a failed start is reported:
    /// graceful shutdown → wait until STOPPED (≤ 5 min) → short pause so passthrough devices
    /// (e.g. a GPU) are released → start, retrying once.
    /// Takes minutes for a Windows guest, so it runs in the menu bar app, not the widget.
    static func restart(vmID: Int, vmName: String?) async -> String? {
        guard let creds = credentials() else { return lastError }
        let (config, key) = creds
        let label = vmName ?? "VM \(vmID)"
        RestartTracker.begin(vmID)
        defer { RestartTracker.end(vmID) }

        var message: String?
        do {
            let client = try TrueNASClient(config: config)
            defer { client.close() }
            try await withTimeout(7 * 60, onTimeout: { client.close() }) {
                try await login(client, config, key)

                if try await state(client, vmID) != "STOPPED" {
                    _ = try await client.call("vm.stop", [vmID, ["force": false, "force_after_timeout": false]])
                    let deadline = Date().addingTimeInterval(5 * 60)
                    while try await state(client, vmID) != "STOPPED" {
                        if Date() > deadline { throw RestartError.didNotStop }
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }

                do {
                    _ = try await client.call("vm.start", [vmID])
                } catch {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    do {
                        _ = try await client.call("vm.start", [vmID])
                    } catch {
                        throw RestartError.startFailed(error)
                    }
                }
            }
        } catch RestartError.didNotStop {
            message = "\(label) didn't shut down within 5 minutes, so it wasn't started again. Check its console in TrueNAS."
        } catch RestartError.vmGone {
            message = "\(label) no longer exists on the NAS."
        } catch RestartError.startFailed(let underlying) {
            message = "\(label) shut down but didn't start again — " + describe(underlying, verb: "start", label: label)
        } catch {
            message = describe(error, verb: "restart", label: label)
        }
        lastError = message

        try? await Task.sleep(nanoseconds: 3_000_000_000)
        _ = await HealthService.refreshAndStore()
        return message
    }

    // MARK: Helpers

    private static func credentials() -> (NASConfig, String)? {
        let config = NASConfig.load()
        guard config.isComplete, let key = SecretStore.load(), !key.isEmpty else {
            lastError = "Not set up yet — open NAS Drive Health from the menu bar."
            return nil
        }
        return (config, key)
    }

    private static func login(_ client: TrueNASClient, _ config: NASConfig, _ key: String) async throws {
        try await client.login(username: config.username.trimmingCharacters(in: .whitespaces),
                               apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func state(_ client: TrueNASClient, _ id: Int) async throws -> String {
        let result = try await client.call("vm.query", [[["id", "=", id]]])
        guard let vm = (result as? [[String: Any]])?.first else { throw RestartError.vmGone }
        return ((vm.dict("status") ?? [:]).str("state") ?? "UNKNOWN").uppercased()
    }

    private static func describe(_ error: Error, verb: String, label: String) -> String {
        if case TrueNASClient.ClientError.rpc(let code, let msg) = error {
            let lower = msg.lowercased()
            if code == 13 || lower.contains("not authorized") || lower.contains("permission") || lower.contains("eacces") {
                return "Can't \(verb) \(label): this API key's account lacks the VM_WRITE role (see README → VM controls)."
            }
            if code == 12 || lower.contains("memory") {
                return "Can't start \(label): not enough free memory on the NAS."
            }
            return "Couldn't \(verb) \(label): \(msg)"
        }
        return "Couldn't \(verb) \(label): \(error.localizedDescription)"
    }
}
