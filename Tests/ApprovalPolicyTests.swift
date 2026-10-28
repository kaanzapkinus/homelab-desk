import Foundation

@main struct ApprovalPolicyChecks {
    @MainActor static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let target = ServiceTarget(key: "agent:com.homelab.ompweb", display: "OMP Web", installed: true, actionable: true)
        let policy = ApprovalPolicy()
        let fresh = policy.propose(target: target, now: now)
        assert(fresh.action == "restart", "Standard target must have restart action")
        assert(fresh.actionLabel == "Yeniden Başlat", "Standard target must have canonical actionLabel")
        try policy.consume(fresh, targetKey: target.key, independentAccess: false, now: now.addingTimeInterval(1))
        expectDenied("single use") { try policy.consume(fresh, targetKey: target.key, independentAccess: false, now: now.addingTimeInterval(2)) }
        let expired = policy.propose(target: target, now: now)
        expectDenied("expiry") { try policy.consume(expired, targetKey: target.key, independentAccess: false, now: now.addingTimeInterval(61)) }
        let wrong = policy.propose(target: target, now: now)
        expectDenied("target substitution") { try policy.consume(wrong, targetKey: "agent:com.homelab.agyauth", independentAccess: false, now: now) }

        // Scheduled target test: must have action "run_now" and canonical actionLabel
        let scheduledTarget = ServiceTarget(
            key: "agent:com.homelab.backup",
            display: "Homelab Backup",
            installed: true,
            actionable: true,
            activation: "scheduled",
            actionLabel: "Şimdi Çalıştır",
            warning: "Günlük yedekleme betiği hemen çalıştırılır."
        )
        let scheduledProp = policy.propose(target: scheduledTarget, now: now)
        assert(scheduledProp.action == "run_now", "Scheduled job must propose canonical run_now action")
        assert(scheduledProp.actionLabel == "Şimdi Çalıştır", "Scheduled job must propose actionLabel")
        assert(scheduledProp.warning == "Günlük yedekleme betiği hemen çalıştırılır.", "Scheduled job warning must be preserved")

        // Tampering action from run_now to restart must be denied
        let tamperedAction = RecoveryProposal(
            id: scheduledProp.id,
            targetKey: scheduledProp.targetKey,
            display: scheduledProp.display,
            action: "restart",
            actionLabel: scheduledProp.actionLabel,
            warning: scheduledProp.warning,
            createdAt: scheduledProp.createdAt,
            highRisk: scheduledProp.highRisk
        )
        expectDenied("action tampering") { try policy.consume(tamperedAction, targetKey: scheduledTarget.key, independentAccess: false, now: now) }

        // Tampering actionLabel must be denied
        let tamperedLabel = RecoveryProposal(
            id: scheduledProp.id,
            targetKey: scheduledProp.targetKey,
            display: scheduledProp.display,
            action: scheduledProp.action,
            actionLabel: "Farklı Etiket",
            warning: scheduledProp.warning,
            createdAt: scheduledProp.createdAt,
            highRisk: scheduledProp.highRisk
        )
        expectDenied("label tampering") { try policy.consume(tamperedLabel, targetKey: scheduledTarget.key, independentAccess: false, now: now) }

        // Tampering warning must be denied
        let tamperedWarning = RecoveryProposal(
            id: scheduledProp.id,
            targetKey: scheduledProp.targetKey,
            display: scheduledProp.display,
            action: scheduledProp.action,
            actionLabel: scheduledProp.actionLabel,
            warning: nil,
            createdAt: scheduledProp.createdAt,
            highRisk: scheduledProp.highRisk
        )
        expectDenied("warning tampering") { try policy.consume(tamperedWarning, targetKey: scheduledTarget.key, independentAccess: false, now: now) }

        // High risk target checks
        let risk = ServiceTarget(
            key: "daemon:homebrew.mxcl.tailscale",
            display: "Tailscale",
            kind: "daemon",
            installed: true,
            actionable: true,
            warning: "Tailscale yeniden başlatılırken Hub bağlantısı kısa süre kesilebilir.",
            highRisk: true
        )
        let risky = policy.propose(target: risk, now: now)
        expectDenied("sole access protection") { try policy.consume(risky, targetKey: risk.key, independentAccess: false, now: now) }
        let acknowledged = policy.propose(target: risk, now: now)
        try policy.consume(acknowledged, targetKey: risk.key, independentAccess: true, now: now)
        let original = policy.propose(target: risk, now: now)
        let forged = RecoveryProposal(
            id: original.id,
            targetKey: original.targetKey,
            display: original.display,
            action: original.action,
            actionLabel: original.actionLabel,
            warning: original.warning,
            createdAt: original.createdAt,
            highRisk: false
        )
        expectDenied("risk downgrade") { try policy.consume(forged, targetKey: risk.key, independentAccess: false, now: now) }

        let absent = ServiceTarget(key: "agent:com.homelab.ompweb", display: "Absent", installed: false, actionable: false)
        let unavailable = policy.propose(target: absent, now: now)
        expectDenied("unavailable target") { try policy.consume(unavailable, targetKey: absent.key, independentAccess: false, now: now) }

        print("PASS approval: single-use, expiry, target binding, scheduled run_now, action/label/warning binding, access protection, risk tampering, unavailable target")
    }
    static func expectDenied(_ name: String, _ operation: () throws -> Void) {
        do { try operation(); fatalError("Unsafe approval accepted: \(name)") } catch { }
    }
}
