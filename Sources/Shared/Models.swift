import Foundation

struct DeviceSnapshot: Codable, Sendable {
    var observedAt = Date()
    var cpuPercent: Double? = nil
    var memoryUsedBytes: Double? = nil
    var memoryTotalBytes: Double? = nil
    var memoryPressure: String = "Ölçülmedi"
    var swapUsedBytes: Double? = nil
    var diskFreeBytes: Double? = nil
    var diskTotalBytes: Double? = nil
    var externalVolumes: [String] = []
    var interfaceStatus: String = "Ölçülmedi"
    var internetStatus: String = "Ölçülmedi"
    var dnsStatus: String = "Ölçülmedi"
    var tailscaleStatus: String = "Ölçülmedi"
    var notes: [String] = []
}
struct MetricPoint: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let cpu: Double?
    let memory: Double?
}
struct ServiceTarget: Identifiable, Codable, Sendable {
    var id: String { key }
    let key: String
    let display: String
    var kind: String = "agent"
    var state: String = "unknown"
    var running: Bool = false
    var installed: Bool = false
    var actionable: Bool = false
    var reason: String? = nil
    var activation: String? = nil
    var action: String? = nil
    var actionLabel: String? = nil
    var warning: String? = nil
    var highRisk: Bool = false
    var observedAt: Date = Date()
}
struct RecoveryJob: Identifiable, Codable, Sendable {
    let id: String
    let targetKey: String
    let phase: String
    var message: String? = nil
    var error: String? = nil
    var terminal: Bool { ["healthy", "succeeded", "failed", "timed_out", "cancelled"].contains(phase) }
}
struct RecoveryProposal: Identifiable, Codable, Sendable {
    let id: UUID
    let targetKey: String
    let display: String
    let action: String
    let actionLabel: String
    let warning: String?
    let createdAt: Date
    let highRisk: Bool

    init(
        id: UUID,
        targetKey: String,
        display: String,
        action: String,
        actionLabel: String = "",
        warning: String? = nil,
        createdAt: Date,
        highRisk: Bool
    ) {
        self.id = id
        self.targetKey = targetKey
        self.display = display
        self.action = action
        self.actionLabel = actionLabel
        self.warning = warning
        self.createdAt = createdAt
        self.highRisk = highRisk
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.targetKey = try container.decode(String.self, forKey: .targetKey)
        self.display = try container.decode(String.self, forKey: .display)
        self.action = try container.decode(String.self, forKey: .action)
        self.actionLabel = try container.decodeIfPresent(String.self, forKey: .actionLabel) ?? ""
        self.warning = try container.decodeIfPresent(String.self, forKey: .warning)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.highRisk = try container.decode(Bool.self, forKey: .highRisk)
    }
}
public struct ChatMessage: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var role: String
    public var text: String
    public var date = Date()
    public init(id: UUID = UUID(), role: String, text: String, date: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
    }
}
struct DeskEvent: Identifiable, Codable, Sendable {
    var id = UUID()
    var date = Date()
    let title: String
    let detail: String
    let isError: Bool
}
