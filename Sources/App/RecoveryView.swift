import SwiftUI
import AppKit

/// RecoveryView: Handles deterministic local service recovery, approval cards,
/// active execution jobs, bounded system events, and diagnostic export.
/// Recovery operations never execute directly from list buttons; they create
/// an expiring native proposal requiring explicit user confirmation.
public struct RecoveryView: View {
    @ObservedObject var model: AppModel
    
    @State private var acknowledgedIndependentAccess: Bool = false
    @State private var copiedDiagnosticsMessage: String? = nil
    @State private var isCopyingDiagnostics: Bool = false
    
    init(model: AppModel) { self.model = model
         }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: model.remoteMode ? 20 : 16) {
                // Section 1: Active Error Banner
                if let error = model.errorMessage {
                    errorBanner(error)
                }
                
                // Section 2: Active Recovery Proposal Confirmation Card
                if let proposal = model.proposal {
                    proposalCard(proposal)
                }
                
                // Section 3: In-Flight & Recent Recovery Jobs
                if !model.jobs.isEmpty {
                    jobsSection
                }
                
                // Section 4: Critical Service Targets List
                servicesSection
                
                // Section 5: Bounded System Events & Diagnostics
                eventsSection
            }
            .padding(model.remoteMode ? 16 : 12)
        }
    }
    
    // MARK: - Error Banner
    
    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: model.remoteMode ? 22 : 18))
                .foregroundStyle(.white)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Hata Oluştu")
                    .font(.system(model.remoteMode ? .title3 : .headline, design: .default, weight: .bold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(model.remoteMode ? .body : .subheadline, design: .default))
                    .foregroundStyle(.white.opacity(0.95))
            }
            
            Spacer()
            
            Button {
                model.errorMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: model.remoteMode ? 22 : 16))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(model.remoteMode ? 16 : 12)
        .background(Color.red)
        .cornerRadius(10)
    }
    
    // MARK: - Proposal Confirmation Card
    
    @ViewBuilder
    private func proposalCard(_ proposal: RecoveryProposal) -> some View {
        VStack(alignment: .leading, spacing: model.remoteMode ? 16 : 12) {
            HStack(spacing: 10) {
                Image(systemName: proposal.highRisk ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: model.remoteMode ? 28 : 22))
                    .foregroundStyle(proposal.highRisk ? Color.orange : Color.accentColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kurtarma Onayı Gerekiyor")
                        .font(.system(model.remoteMode ? .title2 : .headline, design: .default, weight: .bold))
                    let labelText = proposal.actionLabel.isEmpty ? proposal.action.uppercased() : proposal.actionLabel
                    Text("İşlem: \(labelText) • Servis: \(proposal.display)")
                        .font(.system(model.remoteMode ? .body : .subheadline, design: .default))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // 60-second TTL countdown indicator
                Text("60 sn")
                    .font(.system(model.remoteMode ? .body : .caption, design: .monospaced, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(6)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Hedef Anahtar:")
                        .font(.system(model.remoteMode ? .body : .subheadline, design: .default))
                        .foregroundStyle(.secondary)
                    Text(proposal.targetKey)
                        .font(.system(model.remoteMode ? .body : .subheadline, design: .monospaced, weight: .medium))
                }
                HStack {
                    Text("Oluşturulma:")
                        .font(.system(model.remoteMode ? .body : .subheadline, design: .default))
                        .foregroundStyle(.secondary)
                    Text(proposal.createdAt.formatted(date: .omitted, time: .standard))
                        .font(.system(model.remoteMode ? .body : .subheadline, design: .monospaced))
                }
            }
            
            // Canonical Warning & High Risk Warning with Explicit Checkbox
            let hasWarning = (proposal.warning != nil && !(proposal.warning?.isEmpty ?? true))
            if proposal.highRisk || hasWarning {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "shield.slash.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: model.remoteMode ? 20 : 16))
                        Text(proposal.warning ?? "DİKKAT: Bu servis kritik bir erişim yoludur (ör. Tailscale / Uzak Masaüstü). Yeniden başlatma sırasında mevcut uzak oturumunuz kopabilir.")
                            .font(.system(model.remoteMode ? .callout : .caption, design: .default, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                    
                    if proposal.highRisk {
                        Toggle(isOn: $acknowledgedIndependentAccess) {
                            Text("Bağımsız harici erişim yolum olduğunu onaylıyorum.")
                                .font(.system(model.remoteMode ? .body : .subheadline, design: .default, weight: .semibold))
                        }
                        .toggleStyle(.checkbox)
                        .padding(.top, 4)
                    }
                }
                .padding(model.remoteMode ? 14 : 10)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(8)
            }
            
            // Actions: Cancel & Confirm
            HStack(spacing: 12) {
                Button(role: .cancel) {
                    model.cancelRecovery()
                    acknowledgedIndependentAccess = false
                } label: {
                    Text("İptal Et")
                        .font(.system(model.remoteMode ? .title3 : .body, design: .default, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: model.remoteMode ? 44 : 32)
                }
                .buttonStyle(.bordered)
                .controlSize(model.remoteMode ? .large : .regular)
                
                Button {
                    let independent = acknowledgedIndependentAccess
                    Task {
                        await model.confirmRecovery(independentAccess: independent)
                        acknowledgedIndependentAccess = false
                    }
                } label: {
                    HStack {
                        if model.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 4)
                        }
                        Text("Onayla ve Başlat")
                            .font(.system(model.remoteMode ? .title3 : .body, design: .default, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: model.remoteMode ? 44 : 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(proposal.highRisk ? .orange : .accentColor)
                .controlSize(model.remoteMode ? .large : .regular)
                .disabled((proposal.highRisk && !acknowledgedIndependentAccess) || model.isLoading)
            }
            .padding(.top, 6)
        }
        .padding(model.remoteMode ? 18 : 14)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(proposal.highRisk ? Color.orange : Color.accentColor, lineWidth: 2)
        )
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 6, x: 0, y: 3)
    }
    
    // MARK: - Jobs Section
    
    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kurtarma İşlemleri")
                .font(.system(model.remoteMode ? .title3 : .headline, design: .default))
            
            VStack(spacing: 8) {
                ForEach(model.jobs) { job in
                    jobRow(job)
                }
            }
        }
    }
    
    @ViewBuilder
    private func jobRow(_ job: RecoveryJob) -> some View {
        HStack(spacing: 10) {
            phaseIndicator(for: job.phase)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(job.targetKey)
                        .font(.system(model.remoteMode ? .body : .subheadline, design: .monospaced, weight: .semibold))
                    Spacer()
                    Text(job.phase.uppercased())
                        .font(.system(model.remoteMode ? .caption : .caption2, design: .monospaced, weight: .bold))
                        .foregroundStyle(phaseColor(for: job.phase))
                }
                
                if let message = job.message {
                    Text(message)
                        .font(.system(model.remoteMode ? .callout : .caption, design: .default))
                        .foregroundStyle(.secondary)
                }
                
                if let error = job.error {
                    Text("Hata: \(error)")
                        .font(.system(model.remoteMode ? .callout : .caption, design: .default, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(model.remoteMode ? 12 : 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - Services Section
    
    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Kritik Servisler")
                    .font(.system(model.remoteMode ? .title3 : .headline, design: .default))
                Spacer()
                Text("\(model.targets.count) Servis")
                    .font(.system(model.remoteMode ? .callout : .caption, design: .default))
                    .foregroundStyle(.secondary)
            }
            
            if model.targets.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("Kayıtlı servis hedefi bulunamadı.")
                            .font(.system(model.remoteMode ? .body : .subheadline, design: .default))
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    Spacer()
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.targets) { target in
                        serviceRow(target)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func serviceRow(_ target: ServiceTarget) -> some View {
        VStack(alignment: .leading, spacing: model.remoteMode ? 10 : 6) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(target.running ? Color.green : (target.installed ? Color.red : Color.secondary))
                    .frame(width: model.remoteMode ? 12 : 10, height: model.remoteMode ? 12 : 10)
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(target.display)
                            .font(.system(model.remoteMode ? .title3 : .body, design: .default, weight: .semibold))
                        
                        if target.highRisk {
                            Text("YÜKSEK RİSK")
                                .font(.system(size: model.remoteMode ? 11 : 9, weight: .heavy))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.2))
                                .foregroundStyle(.orange)
                                .cornerRadius(4)
                        }
                    }
                    
                    HStack(spacing: 8) {
                        Text(target.key)
                            .font(.system(model.remoteMode ? .footnote : .caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        
                        Text("•")
                            .foregroundStyle(.secondary)
                        
                        Text(target.kind)
                            .font(.system(model.remoteMode ? .footnote : .caption, design: .default))
                            .foregroundStyle(.secondary)
                        
                        Text("•")
                            .foregroundStyle(.secondary)
                        
                        Text(target.running ? "Çalışıyor" : (target.installed ? "Durduruldu" : "Yüklü Değil"))
                            .font(.system(model.remoteMode ? .footnote : .caption, design: .default, weight: .medium))
                            .foregroundStyle(target.running ? Color.green : (target.installed ? Color.red : Color.secondary))
                    }
                }
                
                Spacer()
                
                // Restart Action Button (Creates a proposal, does NOT directly execute)
                Button {
                    model.requestRecovery(target)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        let buttonText = (target.actionLabel != nil && !(target.actionLabel?.isEmpty ?? true)) ? target.actionLabel! : "Yeniden Başlat"
                        Text(buttonText)
                    }
                    .font(.system(model.remoteMode ? .body : .caption, design: .default, weight: .medium))
                    .padding(.horizontal, model.remoteMode ? 14 : 10)
                }
                .buttonStyle(.bordered)
                .controlSize(model.remoteMode ? .large : .small)
                .disabled(!target.actionable || model.isLoading || model.proposal != nil)
            }
            
            // Canonical target warning and activation notes
            if let warning = target.warning, !warning.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: model.remoteMode ? 14 : 11))
                    Text(warning)
                        .font(.system(model.remoteMode ? .callout : .caption2, design: .default))
                        .foregroundStyle(.orange)
                }
                .padding(.leading, model.remoteMode ? 22 : 20)
            }
            
            if let reason = target.reason, !reason.isEmpty {
                Text("Not: \(reason)")
                    .font(.system(model.remoteMode ? .callout : .caption2, design: .default))
                    .foregroundStyle(.secondary)
                    .padding(.leading, model.remoteMode ? 22 : 20)
            }
            
            HStack {
                Spacer()
                Text("Gözlem: \(target.observedAt.formatted(date: .omitted, time: .standard))")
                    .font(.system(model.remoteMode ? .caption : .caption2, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.8))
            }
        }
        .padding(model.remoteMode ? 14 : 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - Events & Diagnostics Section
    
    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Olay Günlüğü")
                    .font(.system(model.remoteMode ? .title3 : .headline, design: .default))
                
                Spacer()
                
                // Copy diagnostics button invokes model.recovery.diagnostics async
                Button {
                    copyDiagnostics()
                } label: {
                    HStack(spacing: 4) {
                        if isCopyingDiagnostics {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "doc.on.doc")
                        }
                        Text(copiedDiagnosticsMessage ?? "Tanı Bilgisini Kopyala")
                    }
                    .font(.system(model.remoteMode ? .body : .caption, design: .default, weight: .medium))
                    .frame(minHeight: model.remoteMode ? 44 : 26)
                }
                .buttonStyle(.bordered)
                .controlSize(model.remoteMode ? .large : .small)
                .disabled(isCopyingDiagnostics)
            }
            
            if model.events.isEmpty {
                HStack {
                    Spacer()
                    Text("Henüz kaydedilmiş sistem olayı yok.")
                        .font(.system(model.remoteMode ? .body : .subheadline, design: .default))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(model.events.suffix(30).reversed())) { event in
                        eventRow(event)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func eventRow(_ event: DeskEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: event.isError ? "exclamationmark.circle.fill" : "info.circle.fill")
                .font(.system(size: model.remoteMode ? 16 : 13))
                .foregroundStyle(event.isError ? Color.red : Color.secondary)
                .padding(.top, 2)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(event.title)
                        .font(.system(model.remoteMode ? .body : .subheadline, design: .default, weight: .medium))
                    Spacer()
                    Text(event.date.formatted(date: .omitted, time: .standard))
                        .font(.system(model.remoteMode ? .caption : .caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.system(model.remoteMode ? .callout : .caption, design: .default))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(model.remoteMode ? 10 : 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }
    
    // MARK: - Actions & Helpers
    
    private func copyDiagnostics() {
        guard !isCopyingDiagnostics else { return }
        isCopyingDiagnostics = true
        
        Task {
            do {
                let diagnosticsText = try await model.recovery.diagnostics(targetKey: nil)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(diagnosticsText, forType: .string)
                copiedDiagnosticsMessage = "Kopyalandı"
            } catch {
                copiedDiagnosticsMessage = "Tanı alınamadı"
                model.errorMessage = error.localizedDescription
            }
            isCopyingDiagnostics = false
            
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            
            await MainActor.run {
                copiedDiagnosticsMessage = nil
            }
        }
    }
    
    @ViewBuilder
    private func phaseIndicator(for phase: String) -> some View {
        switch phase {
        case "starting", "in_progress", "restarting":
            ProgressView()
                .controlSize(.small)
        case "succeeded":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case "failed", "timed_out":
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case "cancelled":
            Image(systemName: "slash.circle.fill")
                .foregroundStyle(.secondary)
        default:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }
    
    private func phaseColor(for phase: String) -> Color {
        switch phase {
        case "starting", "in_progress", "restarting":
            return .orange
        case "succeeded":
            return .green
        case "failed", "timed_out":
            return .red
        default:
            return .secondary
        }
    }
}
