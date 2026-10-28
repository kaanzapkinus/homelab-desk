import Foundation

@MainActor
final class RecoveryBackend {
    private let nodePath: String
    private let bridgePathOverride: String?

    init(nodePath: String = "/opt/homebrew/bin/node", bridgePath: String? = nil) {
        if FileManager.default.isExecutableFile(atPath: nodePath) {
            self.nodePath = nodePath
        } else if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/node") {
            self.nodePath = "/usr/local/bin/node"
        } else if FileManager.default.isExecutableFile(atPath: "/usr/bin/node") {
            self.nodePath = "/usr/bin/node"
        } else {
            self.nodePath = nodePath
        }
        self.bridgePathOverride = bridgePath
    }

    func targets() async throws -> [ServiceTarget] {
        let payload: [String: Any] = ["command": "inventory"]
        let data = try await invokeBridge(payload: payload)
        let response = try decodeEnvelope(data: data)
        guard let targets = response.targets else {
            throw RecoveryBackendError.invalidResponse("Targets array missing in bridge response")
        }
        return targets
    }

    func diagnostics(targetKey: String?) async throws -> String {
        var payload: [String: Any] = ["command": "diagnostics"]
        if let key = targetKey {
            payload["targetKey"] = key
        }
        let data = try await invokeBridge(payload: payload)
        let response = try decodeEnvelope(data: data)
        guard let diag = response.diagnostics else {
            throw RecoveryBackendError.invalidResponse("Diagnostics string missing in bridge response")
        }
        return diag
    }

    func restart(targetKey: String, action: String? = nil, independentAccess: Bool, approvedAt: Date) async throws -> RecoveryJob {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateString = formatter.string(from: approvedAt)

        var payload: [String: Any] = [
            "command": "recover",
            "targetKey": targetKey,
            "independentAccess": independentAccess,
            "approvedAt": dateString
        ]
        if let action = action {
            payload["action"] = action
        }
        let data = try await invokeBridge(payload: payload)
        let response = try decodeEnvelope(data: data)
        guard let job = response.job else {
            throw RecoveryBackendError.invalidResponse("Job missing in recovery response")
        }
        return job
    }

    func job(id: String) async throws -> RecoveryJob {
        let payload: [String: Any] = [
            "command": "job",
            "id": id
        ]
        let data = try await invokeBridge(payload: payload)
        let response = try decodeEnvelope(data: data)
        guard let job = response.job else {
            throw RecoveryBackendError.invalidResponse("Job missing in job status response")
        }
        return job
    }

    private func resolveBridgePath() -> String? {
        if let override = bridgePathOverride, FileManager.default.fileExists(atPath: override) {
            return override
        }
        if let resourcePath = Bundle.main.path(forResource: "recovery", ofType: "cjs") {
            return resourcePath
        }
        if let resDir = Bundle.main.resourcePath {
            let inBundle = (resDir as NSString).appendingPathComponent("Bridge/recovery.cjs")
            if FileManager.default.fileExists(atPath: inBundle) {
                return inBundle
            }
        }
        let cwdCandidate = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent("bridge/recovery.cjs")
        if FileManager.default.fileExists(atPath: cwdCandidate) {
            return cwdCandidate
        }
        return nil
    }

    private func invokeBridge(payload: [String: Any], timeout: TimeInterval = 15.0) async throws -> Data {
        guard let bridge = resolveBridgePath(), FileManager.default.fileExists(atPath: bridge) else {
            throw RecoveryBackendError.bridgeNotFound
        }
        guard FileManager.default.isExecutableFile(atPath: nodePath) else {
            throw RecoveryBackendError.nodeNotFound(nodePath)
        }

        let inputData = try JSONSerialization.data(withJSONObject: payload, options: [])
        guard inputData.count <= 8192 else {
            throw RecoveryBackendError.payloadTooLarge
        }

        let node = self.nodePath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: node)
                process.arguments = [bridge]

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()

                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                var stdoutData = Data()
                var stderrData = Data()
                let drainGroup = DispatchGroup()

                drainGroup.enter()
                DispatchQueue.global().async {
                    stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    drainGroup.leave()
                }

                drainGroup.enter()
                DispatchQueue.global().async {
                    stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    drainGroup.leave()
                }

                do {
                    try process.run()
                    stdinPipe.fileHandleForWriting.write(inputData)
                    try stdinPipe.fileHandleForWriting.close()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                var didTimeout = false
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    didTimeout = true
                    process.terminate()
                }
                timer.resume()

                process.waitUntilExit()
                _ = drainGroup.wait(timeout: .now() + 2.0)
                timer.cancel()

                if didTimeout {
                    continuation.resume(throwing: RecoveryBackendError.timeout)
                    return
                }

                if process.terminationStatus != 0 && stdoutData.isEmpty {
                    let errStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(throwing: RecoveryBackendError.processFailed(status: process.terminationStatus, error: errStr))
                    return
                }

                continuation.resume(returning: stdoutData)
            }
        }
    }

    private func decodeEnvelope(data: Data) throws -> BridgeEnvelope {
        let decoder = JSONDecoder()
        let iso8601WithMillis = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let iso8601Standard = Date.ISO8601FormatStyle()

        decoder.dateDecodingStrategy = .custom { d in
            let container = try d.singleValueContainer()
            let dateStr = try container.decode(String.self)
            if let date = try? iso8601WithMillis.parse(dateStr) {
                return date
            }
            if let date = try? iso8601Standard.parse(dateStr) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date: \(dateStr)")
        }

        let envelope = try decoder.decode(BridgeEnvelope.self, from: data)
        if !envelope.ok {
            throw RecoveryBackendError.bridgeFailed(envelope.error ?? "Unknown bridge error")
        }
        return envelope
    }
}

private struct BridgeEnvelope: Decodable {
    let ok: Bool
    let error: String?
    let targets: [ServiceTarget]?
    let diagnostics: String?
    let job: RecoveryJob?
}

enum RecoveryBackendError: LocalizedError, Equatable {
    case bridgeNotFound
    case nodeNotFound(String)
    case payloadTooLarge
    case timeout
    case processFailed(status: Int32, error: String)
    case bridgeFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .bridgeNotFound:
            return "Kurtarma köprüsü (recovery.cjs) bulunamadı."
        case .nodeNotFound(let path):
            return "Node.js çalıştırılabilir dosyası bulunamadı: \(path)"
        case .payloadTooLarge:
            return "İstek boyutu 8 KiB sınırını aştı."
        case .timeout:
            return "Kurtarma köprüsü zaman aşımına uğradı."
        case .processFailed(let status, let err):
            return "Köprü süreci başarısız oldu (çıkış kodu \(status)): \(err)"
        case .bridgeFailed(let msg):
            return msg
        case .invalidResponse(let msg):
            return "Köprü yanıtı geçersiz: \(msg)"
        }
    }
}
