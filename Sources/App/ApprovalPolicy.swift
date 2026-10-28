import Foundation

@MainActor
final class ApprovalPolicy {
    private struct StoredProposal {
        let id: UUID
        let targetKey: String
        let display: String
        let action: String
        let actionLabel: String
        let warning: String?
        let createdAt: Date
        let highRisk: Bool
        let actionable: Bool
        let installed: Bool
        var consumed: Bool
    }

    private var pending: [UUID: StoredProposal] = [:]

    init() {}

    func propose(target: ServiceTarget, now: Date = Date()) -> RecoveryProposal {
        pruneExpired(now: now)
        let id = UUID()
        let isScheduled = target.activation == "scheduled"
        let isUnloaded = target.state == "stopped" || target.state == "not loaded" || !target.installed
        let defaultAction = isScheduled ? "run_now" : (isUnloaded ? "restore" : "restart")
        let action = target.action ?? defaultAction
        let actionLabel: String
        if let label = target.actionLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            actionLabel = label
        } else {
            actionLabel = isScheduled ? "Şimdi Çalıştır" : (isUnloaded ? "Geri Yükle" : "Yeniden Başlat")
        }
        let warning = target.warning

        let proposal = RecoveryProposal(
            id: id,
            targetKey: target.key,
            display: target.display,
            action: action,
            actionLabel: actionLabel,
            warning: warning,
            createdAt: now,
            highRisk: target.highRisk
        )
        pending[id] = StoredProposal(
            id: id,
            targetKey: target.key,
            display: target.display,
            action: action,
            actionLabel: actionLabel,
            warning: warning,
            createdAt: now,
            highRisk: target.highRisk,
            actionable: target.actionable,
            installed: target.installed,
            consumed: false
        )
        return proposal
    }

    func consume(_ proposal: RecoveryProposal, targetKey: String, independentAccess: Bool, now: Date = Date()) throws {
        guard let stored = pending[proposal.id] else {
            throw ApprovalPolicyError.proposalNotFound
        }

        guard !stored.consumed else {
            throw ApprovalPolicyError.alreadyConsumed
        }

        guard stored.installed && stored.actionable else {
            throw ApprovalPolicyError.targetNotActionable
        }

        let age = now.timeIntervalSince(stored.createdAt)
        guard age >= -5.0 && age <= 60.0 else {
            throw ApprovalPolicyError.expired
        }

        guard targetKey == stored.targetKey && proposal.targetKey == stored.targetKey else {
            throw ApprovalPolicyError.targetMismatch
        }

        guard proposal.display == stored.display &&
              proposal.action == stored.action &&
              proposal.actionLabel == stored.actionLabel &&
              proposal.warning == stored.warning &&
              proposal.createdAt == stored.createdAt &&
              proposal.highRisk == stored.highRisk else {
            throw ApprovalPolicyError.proposalTampered
        }

        if stored.highRisk && !independentAccess {
            throw ApprovalPolicyError.independentAccessRequired
        }

        pending[proposal.id]?.consumed = true
    }

    private func pruneExpired(now: Date) {
        pending = pending.filter { _, stored in
            now.timeIntervalSince(stored.createdAt) < 300.0
        }
    }
}

enum ApprovalPolicyError: LocalizedError, Equatable {
    case proposalNotFound
    case alreadyConsumed
    case expired
    case targetMismatch
    case proposalTampered
    case independentAccessRequired
    case targetNotActionable

    var errorDescription: String? {
        switch self {
        case .proposalNotFound:
            return "Onay kaydı bulunamadı."
        case .alreadyConsumed:
            return "Onay kaydı daha önce kullanıldı (tek kullanım kuralı)."
        case .expired:
            return "Onay süresi doldu (60 saniye sınırı)."
        case .targetMismatch:
            return "Onaylanan hedef ile istenen hedef eşleşmiyor."
        case .proposalTampered:
            return "Öneri alanları değiştirilmiş; işlem engellendi."
        case .independentAccessRequired:
            return "Yüksek riskli erişim yolu için bağımsız erişim teyidi gereklidir."
        case .targetNotActionable:
            return "Hedef servis kurtarma için uygun veya kurulu değil."
        }
    }
}
