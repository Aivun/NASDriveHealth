import Foundation
import CryptoKit
import Security

/// Minimal JSON-RPC 2.0 client for the TrueNAS WebSocket API (wss://host/api/current).
/// Works with TrueNAS 25.04 and newer (the REST API is gone as of 26.04).
final class TrueNASClient: NSObject, URLSessionDelegate, @unchecked Sendable {

    enum ClientError: LocalizedError {
        case badHost
        case untrustedCertificate(fingerprint: String)
        case authFailed(String)
        case timeout
        case rpc(code: Int, message: String)
        case protocolError(String)

        var errorDescription: String? {
            switch self {
            case .badHost: return "Enter the NAS host name or IP address."
            case .untrustedCertificate: return "The NAS uses a certificate macOS doesn't trust (TrueNAS's default self-signed one?)."
            case .authFailed(let why): return "TrueNAS rejected the API key (\(why)). Check the username and key."
            case .timeout: return "Timed out talking to the NAS."
            case .rpc(_, let message): return "TrueNAS error: \(message)"
            case .protocolError(let s): return "Unexpected response: \(s)"
            }
        }
    }

    private let url: URL
    private let pinnedFingerprint: String
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!
    private var nextId = 1
    private let lock = NSLock()
    private var _certRejectedFingerprint: String?

    var certRejectedFingerprint: String? { lock.withLock { _certRejectedFingerprint } }

    init(config: NASConfig) throws {
        guard let url = config.webSocketURL else { throw ClientError.badHost }
        self.url = url
        self.pinnedFingerprint = config.pinnedFingerprint
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    // MARK: JSON-RPC

    func call(_ method: String, _ params: [Any] = []) async throws -> Any {
        let id: Int = lock.withLock { defer { nextId += 1 }; return nextId }
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let out = try JSONSerialization.data(withJSONObject: payload)
        do {
            try await task.send(.string(String(decoding: out, as: UTF8.self)))
            while true {
                let message = try await task.receive()
                let data: Data
                switch message {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: continue
                }
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                // Skip event notifications and replies to other ids.
                guard let rid = (obj["id"] as? NSNumber)?.intValue, rid == id else { continue }
                if let err = obj["error"] as? [String: Any] {
                    let code = (err["code"] as? NSNumber)?.intValue ?? 0
                    let dataObj = err["data"] as? [String: Any]
                    let msg = (dataObj?["reason"] as? String) ?? (err["message"] as? String) ?? "unknown error"
                    throw ClientError.rpc(code: code, message: msg)
                }
                return obj["result"] ?? NSNull()
            }
        } catch let e as ClientError {
            throw e
        } catch {
            if let fp = certRejectedFingerprint { throw ClientError.untrustedCertificate(fingerprint: fp) }
            throw error
        }
    }

    /// API-key login. `auth.login_ex` (25.04+) first; `auth.login_with_api_key` as a fallback.
    func login(username: String, apiKey: String) async throws {
        do {
            let result = try await call("auth.login_ex", [[
                "mechanism": "API_KEY_PLAIN",
                "username": username,
                "api_key": apiKey,
            ]])
            let type = ((result as? [String: Any])?["response_type"] as? String) ?? "?"
            guard type == "SUCCESS" else { throw ClientError.authFailed(type) }
        } catch ClientError.rpc {
            let ok = try await call("auth.login_with_api_key", [apiKey])
            guard (ok as? Bool) == true else { throw ClientError.authFailed("login_with_api_key returned false") }
        }
    }

    // MARK: TLS

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        let fp = Self.leafFingerprint(trust) ?? ""

        if !pinnedFingerprint.isEmpty {
            // Pinned: accept exactly this certificate (hostname/CA checks skipped on purpose,
            // so a self-signed cert on an IP address works).
            if fp == pinnedFingerprint { return (.useCredential, URLCredential(trust: trust)) }
            lock.withLock { _certRejectedFingerprint = fp }
            return (.cancelAuthenticationChallenge, nil)
        }
        if SecTrustEvaluateWithError(trust, nil) {
            return (.useCredential, URLCredential(trust: trust))
        }
        lock.withLock { _certRejectedFingerprint = fp }
        return (.cancelAuthenticationChallenge, nil)
    }

    static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

/// Runs `op` with a deadline; `onTimeout` must unblock `op` (we close the socket).
func withTimeout<T: Sendable>(_ seconds: Double,
                              onTimeout: @escaping @Sendable () -> Void,
                              _ op: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await op() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            onTimeout()
            throw TrueNASClient.ClientError.timeout
        }
        guard let first = try await group.next() else { throw TrueNASClient.ClientError.timeout }
        group.cancelAll()
        return first
    }
}
