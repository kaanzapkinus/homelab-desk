import Foundation

// MARK: - RPC Transport & Protocol Constants

public enum RPCConstants {
    /// Largest logical frame OMP emits before it chunks (also the protocol-v1 write cap): 1 MiB.
    public static let maxRPCFrameBytes: Int = 1024 * 1024
    /// Outbound reassembled frame ceiling for protocol-v2 chunks: 64 MiB.
    public static let maxRPCReassembledBytes: Int = 64 * 1024 * 1024
    /// Inbound command cap written to OMP stdin as a single JSONL line: 150 MiB.
    public static let maxInboundCommandBytes: Int = 150 * 1024 * 1024
    /// Expected max raw payload per outbound chunk: 256 KiB.
    public static let rpcChunkPayloadBytes: Int = 256 * 1024
    /// Bounded chat history stored in local memory and persisted to disk.
    public static let maxHistoryMessages: Int = 100
    /// Max file size read for local persisted chat history: 512 KiB.
    public static let maxHistoryFileSize: Int = 512 * 1024
}

// MARK: - Protocol Version

public enum RPCProtocolVersion: Int, Sendable, Codable {
    case v1 = 1
    case v2 = 2
}

// MARK: - Outbound Chunk Frame (OMP -> Host)

public struct RPCChunk: Codable, Sendable {
    public let type: String
    public let chunkId: String
    public let index: Int
    public let count: Int
    public let byteLength: Int
    public let data: String

    public init(chunkId: String, index: Int, count: Int, byteLength: Int, data: String) {
        self.type = "rpc_chunk"
        self.chunkId = chunkId
        self.index = index
        self.count = count
        self.byteLength = byteLength
        self.data = data
    }
}

// MARK: - RPC Frame Decoder (NDJSON + Protocol-v2 Chunk Reassembly)

public final class RPCFrameDecoder {
    private struct PendingChunks {
        let chunkId: String
        let count: Int
        let byteLength: Int
        var nextIndex: Int
        var chunks: [Data]
        var receivedBytes: Int
    }

    private var pending: PendingChunks?

    public init() {}

    public func reset() {
        pending = nil
    }

    /// Feeds a parsed JSON dictionary.
    /// If the record is `rpc_chunk`, buffers chunks and returns the reassembled logical frame when complete.
    /// If the record is a regular frame, validates no chunk sequence was interrupted and returns it.
    /// Returns `nil` when waiting for additional chunks.
    public func push(record: [String: Any]) throws -> [String: Any]? {
        guard let type = record["type"] as? String else {
            throw RPCError.invalidFrame("RPC frame missing required 'type' string")
        }

        if type != "rpc_chunk" {
            if pending != nil {
                pending = nil
                throw RPCError.chunkInterrupted("RPC chunk sequence interrupted by non-chunk frame type '\(type)'")
            }
            return record
        }

        guard let chunkId = record["chunkId"] as? String,
              !chunkId.isEmpty, chunkId.count <= 128,
              let index = record["index"] as? Int,
              let count = record["count"] as? Int,
              let byteLength = record["byteLength"] as? Int,
              let base64Data = record["data"] as? String else {
            throw RPCError.invalidChunk("Invalid or missing RPC chunk metadata fields")
        }

        let maxChunkCount = (RPCConstants.maxRPCReassembledBytes / RPCConstants.rpcChunkPayloadBytes) + 1
        guard index >= 0,
              count >= 2,
              count <= maxChunkCount,
              index < count,
              byteLength >= RPCConstants.maxRPCFrameBytes,
              byteLength <= RPCConstants.maxRPCReassembledBytes else {
            throw RPCError.invalidChunk("RPC chunk metadata out of bounds: index=\(index), count=\(count), byteLength=\(byteLength)")
        }

        guard let chunkBytes = Data(base64Encoded: base64Data),
              chunkBytes.count <= RPCConstants.rpcChunkPayloadBytes else {
            throw RPCError.invalidChunk("RPC chunk payload exceeds 256KiB or contains invalid base64")
        }

        if pending == nil {
            guard index == 0 else {
                throw RPCError.chunkSequenceMismatch("RPC chunk sequence must start at index 0, received index \(index)")
            }
            pending = PendingChunks(
                chunkId: chunkId,
                count: count,
                byteLength: byteLength,
                nextIndex: 0,
                chunks: [],
                receivedBytes: 0
            )
        }

        guard var current = pending,
              current.chunkId == chunkId,
              current.count == count,
              current.byteLength == byteLength,
              current.nextIndex == index else {
            let expectedIndex = pending?.nextIndex ?? 0
            pending = nil
            throw RPCError.chunkSequenceMismatch("RPC chunk sequence mismatch: expected index \(expectedIndex), received \(index)")
        }

        current.chunks.append(chunkBytes)
        current.receivedBytes += chunkBytes.count
        current.nextIndex += 1

        guard current.receivedBytes <= current.byteLength else {
            pending = nil
            throw RPCError.chunkLengthExceeded("RPC chunks exceeded declared byteLength (\(current.receivedBytes) > \(current.byteLength))")
        }

        if current.nextIndex < current.count {
            pending = current
            return nil
        }

        guard current.receivedBytes == current.byteLength else {
            let received = current.receivedBytes
            let expected = current.byteLength
            pending = nil
            throw RPCError.chunkLengthMismatch("RPC chunk sequence length mismatch: expected \(expected), received \(received)")
        }

        pending = nil

        var totalData = Data()
        totalData.reserveCapacity(current.byteLength)
        for chunk in current.chunks {
            totalData.append(chunk)
        }

        guard let jsonObject = try JSONSerialization.jsonObject(with: totalData) as? [String: Any],
              let decodedType = jsonObject["type"] as? String, !decodedType.isEmpty else {
            throw RPCError.invalidFrame("Reassembled RPC frame is not a valid JSON object with 'type'")
        }

        return jsonObject
    }
}

// MARK: - Inbound Command Encoding (Host -> OMP stdin)

public enum RPCCommandEncoder {
    /// Physical JSONL record for commands written to OMP stdin.
    /// Commands are always single unchunked lines ending in `\n`.
    public static func encode(_ frame: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(frame) else {
            throw RPCError.invalidFrame("Frame is not a valid JSON object")
        }
        var data = try JSONSerialization.data(withJSONObject: frame, options: [])
        guard data.count + 1 <= RPCConstants.maxInboundCommandBytes else {
            throw RPCError.commandTooLarge("RPC command exceeds inbound transport limit of \(RPCConstants.maxInboundCommandBytes) bytes")
        }
        data.append(0x0A) // '\n'
        return data
    }
}

// MARK: - Host Tools Registry & Safety Boundary

public enum RPCHostToolRegistry {
    /// Host tools exposed to the model via set_host_tools.
    /// Diagnostic reads and recovery proposals only.
    public static let allowedTools: Set<String> = [
        "read_device_snapshot",
        "inspect_services",
        "read_diagnostics",
        "propose_recovery",
        "read_recovery_job"
    ]

    /// Forbidden tools that must NEVER be passed to onHostTool or registered.
    /// execute_approved_recovery is an INTERNAL native-controller operation invoked by the user's approval callback.
    public static let forbiddenTools: Set<String> = [
        "execute_approved_recovery"
    ]

    public static func isAllowed(_ name: String) -> Bool {
        return allowedTools.contains(name) && !forbiddenTools.contains(name)
    }

    /// Full definitions for OMP `set_host_tools` command.
    public static func definitions() -> [[String: Any]] {
        return [
            [
                "name": "read_device_snapshot",
                "description": "Read current live host metrics (CPU, RAM, swap, disk, network, tailscale).",
                "parameters": [
                    "type": "object",
                    "properties": [:] as [String: Any]
                ]
            ],
            [
                "name": "inspect_services",
                "description": "Inspect critical system services and their health/readiness states.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "targetKey": [
                            "type": "string",
                            "description": "Optional specific service target key (e.g. caddy, status, ompweb, crd, tailscale, orbstack)."
                        ]
                    ]
                ]
            ],
            [
                "name": "read_diagnostics",
                "description": "Read untrusted bounded service diagnostics and recent logs.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "targetKey": [
                            "type": "string",
                            "description": "Optional service target key."
                        ]
                    ]
                ]
            ],
            [
                "name": "propose_recovery",
                "description": "Propose service recovery. This opens an unexecuted native confirmation card for the user. Does not execute.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "targetKey": [
                            "type": "string",
                            "description": "The service target key to propose for restart."
                        ]
                    ],
                    "required": ["targetKey"]
                ]
            ],
            [
                "name": "read_recovery_job",
                "description": "Read the status and progress of a recovery job by id.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "Recovery job identifier."
                        ]
                    ],
                    "required": ["id"]
                ]
            ]
        ]
    }

    /// Formats an OMP `host_tool_result` frame matching the MCP tool result schema.
    public static func makeResult(id: String, contentText: String, isError: Bool) -> [String: Any] {
        return [
            "type": "host_tool_result",
            "id": id,
            "isError": isError,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": contentText
                    ]
                ]
            ]
        ]
    }
}

// MARK: - OMP Model Info Model

public struct OmpModelInfo: Identifiable, Hashable, Codable, Sendable {
    public var id: String {
        if provider.isEmpty { return modelId }
        return "\(provider)/\(modelId)"
    }
    public let modelId: String
    public let provider: String
    public let name: String
    public let reasoning: Bool?
    public let contextWindow: Int?
    public let maxTokens: Int?

    public init(
        modelId: String,
        provider: String,
        name: String,
        reasoning: Bool? = nil,
        contextWindow: Int? = nil,
        maxTokens: Int? = nil
    ) {
        self.modelId = modelId
        self.provider = provider
        self.name = name
        self.reasoning = reasoning
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
    }

    public init(from dictionary: [String: Any]) {
        let mId = (dictionary["id"] as? String) ?? ""
        let prov = (dictionary["provider"] as? String) ?? ""
        let n = (dictionary["name"] as? String) ?? mId
        let r = dictionary["reasoning"] as? Bool
        let cw = dictionary["contextWindow"] as? Int
        let mt = dictionary["maxTokens"] as? Int
        self.init(modelId: mId, provider: prov, name: n, reasoning: r, contextWindow: cw, maxTokens: mt)
    }
}

public struct OmpModelCatalog: Codable, Sendable {
    public let models: [OmpModelInfo]
    public init(models: [OmpModelInfo]) {
        self.models = models
    }
}

// MARK: - RPC Error Definitions

public enum RPCError: LocalizedError, Sendable {
    case processNotRunning
    case processExited(code: Int32, stderr: String)
    case invalidFrame(String)
    case invalidChunk(String)
    case chunkInterrupted(String)
    case chunkSequenceMismatch(String)
    case chunkLengthExceeded(String)
    case chunkLengthMismatch(String)
    case commandTooLarge(String)
    case commandFailed(command: String, message: String, code: String?)
    case commandTimeout(String)
    case negotiationFailed(String)
    case toolForbidden(String)
    case binaryNotFound(String)
    case modelMismatch(expected: String, actual: String)
    case resetFailed(String)
    case handshakeFailed(String)
    public var errorDescription: String? {
        switch self {
        case .processNotRunning:
            return "OMP RPC işlemi çalışmıyor."
        case .processExited(let code, let stderr):
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "OMP işlemi kapandı (çıkış kodu: \(code))\(tail.isEmpty ? "" : ": \(tail)")."
        case .invalidFrame(let msg):
            return "Geçersiz RPC çerçevesi: \(msg)"
        case .invalidChunk(let msg):
            return "Geçersiz RPC parçası: \(msg)"
        case .chunkInterrupted(let msg):
            return "RPC parça sırası kesintiye uğradı: \(msg)"
        case .chunkSequenceMismatch(let msg):
            return "RPC parça sıra uyuşmazlığı: \(msg)"
        case .chunkLengthExceeded(let msg):
            return "RPC parça uzunluğu aşıldı: \(msg)"
        case .chunkLengthMismatch(let msg):
            return "RPC parça uzunluğu uyuşmuyor: \(msg)"
        case .commandTooLarge(let msg):
            return "RPC komutu çok büyük: \(msg)"
        case .commandFailed(let cmd, let msg, let code):
            return "RPC komutu (\(cmd)) başarısız: \(msg)\(code.map { " (kod: \($0))" } ?? "")"
        case .commandTimeout(let cmd):
            return "RPC komutu (\(cmd)) zaman aşımına uğradı."
        case .negotiationFailed(let msg):
            return "Protokol anlaşması başarısız: \(msg)"
        case .toolForbidden(let name):
            return "Yetkisiz veya tehlikeli araç çağrısı engellendi: \(name)"
        case .binaryNotFound(let path):
            return "OMP çalıştırılabilir dosyası bulunamadı: \(path)"
        case .modelMismatch(let expected, let actual):
            return "OMP beklenen model (\(expected)) yerine '\(actual)' başlattı; sessiz fallback engellendi."
        case .resetFailed(let msg):
            return "Oturum sıfırlama başarısız: \(msg)"
        case .handshakeFailed(let msg):
            return "OMP el sıkışma hatası: \(msg)"
        }
    }
}
