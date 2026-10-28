import SwiftUI
import ServiceManagement

/// PreferencesView: Provides explicit user control over launch-at-login via SMAppService,
/// displays honest runtime information (OMP controller, RPC endpoints, recovery boundaries),
/// and allows window position resetting.
public struct PreferencesView: View {
    @ObservedObject var model: AppModel
    
    @State private var launchAtLoginStatus: SMAppService.Status = .notRegistered
    @State private var launchAtLoginEnabled: Bool = false
    @State private var statusMessage: String? = nil
    @State private var errorMessage: String? = nil
    @State private var isPerformingAction: Bool = false
    
    init(model: AppModel) { self.model = model
         }
    
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Homelab Desk Ayarları")
                            .font(.system(.title2, design: .default, weight: .bold))
                        Text("Sistem başlangıcı, kurtarma politikaları ve çalışma modları")
                            .font(.system(.subheadline, design: .default))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 4)
                
                Divider()
                
                // Section 1: Launch at Login via SMAppService
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sistem Başlangıcı")
                        .font(.system(.headline, design: .default))
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle("Girişte Otomatik Başlat (Launch at Login)", isOn: Binding(
                                get: { launchAtLoginEnabled },
                                set: { toggleLaunchAtLogin($0) }
                            ))
                            .toggleStyle(.switch)
                            .disabled(isPerformingAction)
                            
                            Spacer()
                            
                            statusBadge(for: launchAtLoginStatus)
                        }
                        
                        Text(statusDescription(for: launchAtLoginStatus))
                            .font(.system(.caption, design: .default))
                            .foregroundStyle(.secondary)
                        
                        if launchAtLoginStatus == .requiresApproval {
                            Button("macOS Sistem Ayarları'nı Aç…") {
                                SMAppService.openSystemSettingsLoginItems()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .padding(.top, 4)
                        }
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
                
                Divider()
                
                // Section 2: Çalışma Modları (Desktop, Focus, Remote)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Çalışma Modu")
                        .font(.system(.headline, design: .default))
                    
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            modeCard(
                                title: "Masaüstü Modu",
                                subtitle: "Pencerelerin arkasında, simgelerin üstünde sabit",
                                icon: "desktopcomputer",
                                isSelected: model.windowMode == .desktop
                            ) {
                                model.setWindowMode(.desktop)
                            }
                            
                            modeCard(
                                title: "Odak Modu",
                                subtitle: "Ön planda, klavye ve yazma odağı",
                                icon: "macwindow",
                                isSelected: model.windowMode == .focus
                            ) {
                                model.setWindowMode(.focus)
                            }
                            
                            modeCard(
                                title: "Telefon Modu",
                                subtitle: "450pt tek sütun, dokunmaya uygun",
                                icon: "iphone",
                                isSelected: model.windowMode == .remote
                            ) {
                                model.setWindowMode(.remote)
                            }
                        }
                        Button("Pencere Konumlarını Sıfırla") {
                            resetWindowPositions()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
                
                Divider()
                
                // Section 3: OMP ve Model Yapılandırması
                VStack(alignment: .leading, spacing: 12) {
                    Text("OMP Asistan ve Model Yapılandırması")
                        .font(.system(.headline, design: .default))
                    
                    VStack(alignment: .leading, spacing: 12) {
                        // Model Selection Picker
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Aktif Model")
                                    .font(.system(.subheadline, design: .default, weight: .medium))
                                Spacer()
                                Button(action: {
                                    Task {
                                        await model.chat.refreshAvailableModels()
                                    }
                                }) {
                                    HStack(spacing: 4) {
                                        if model.chat.isLoadingModels {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Image(systemName: "arrow.triangle.2.circlepath")
                                        }
                                        Text("Modelleri Yenile")
                                    }
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .disabled(model.chat.isLoadingModels || model.chat.isRunning)
                            }
                            
                            Picker("", selection: Binding(
                                get: { model.chat.selectedModel },
                                set: { newModel in
                                    model.chat.setModel(newModel)
                                }
                            )) {
                                if model.chat.availableModels.isEmpty {
                                    Text(model.chat.selectedModel.isEmpty ? "Model seçilmedi" : model.chat.selectedModel)
                                        .tag(model.chat.selectedModel)
                                } else {
                                    if !model.chat.availableModels.contains(where: { $0.id == model.chat.selectedModel }) && !model.chat.selectedModel.isEmpty {
                                        Text("\(model.chat.selectedModel) (Mevcut)").tag(model.chat.selectedModel)
                                    }
                                    ForEach(model.chat.availableModels) { item in
                                        Text("\(item.name) (\(item.id))\(item.reasoning == true ? " · Düşünme" : "")")
                                            .tag(item.id)
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(model.chat.isRunning)
                            
                            if model.chat.isRunning {
                                Text("Model seçimi sohbet devam ederken kilitlidir.")
                                    .font(.system(.caption, design: .default))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        // Error / Quota / Limit Status display
                        if let limit = model.chat.usageLimitStatus {
                            HStack(spacing: 6) {
                                Image(systemName: "gauge.with.needle")
                                    .foregroundStyle(.blue)
                                Text(limit)
                                    .font(.system(.caption, design: .default))
                                    .foregroundStyle(.primary)
                            }
                        }
                        
                        if let err = model.chat.lastError ?? model.chat.modelsError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.red)
                                Text(err)
                                    .font(.system(.caption, design: .default))
                                    .foregroundStyle(.red)
                            }
                        }
                        
                        Divider()
                        
                        infoRow(label: "Model Etiketi", value: model.chat.modelLabel.isEmpty ? "Model seçilmedi" : model.chat.modelLabel)
                        infoRow(label: "Bağlantı Durumu", value: model.chat.connectionStatus)
                        infoRow(label: "Çalışma Şekli", value: "İzole yerel RPC (--mode rpc-ui)")
                        infoRow(label: "Yetki Sınırı", value: "Yalnızca salt-okunur tanı ve kurtarma önerisi. Kabuk/komut yetkisi yoktur.")
                        infoRow(label: "Oturum Dizini", value: "~/Library/Application Support/Homelab Desk")
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
                
                Divider()
                
                // Section 4: Kurtarma & Güvenlik Politikası
                VStack(alignment: .leading, spacing: 12) {
                    Text("Kurtarma ve Erişim Güvenliği")
                        .font(.system(.headline, design: .default))
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("• Kurtarma önerileri 60 saniye boyunca geçerlidir ve tek kullanımlıktır.")
                            .font(.system(.caption, design: .default))
                            .foregroundStyle(.secondary)
                        Text("• Tailscale ve uzaktan erişim gibi yüksek riskli servislerde bağımsız erişim teyidi zorunludur.")
                            .font(.system(.caption, design: .default))
                            .foregroundStyle(.secondary)
                        Text("• Yapay zeka modeli doğrudan komut çalıştıramaz; tüm onaylar yerel arayüz üzerinden verilir.")
                            .font(.system(.caption, design: .default))
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                }
                
                // Status / Error Messages
                if let statusMessage = statusMessage {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(statusMessage)
                            .font(.system(.footnote, design: .default))
                    }
                    .padding(8)
                }
                
                if let errorMessage = errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.system(.footnote, design: .default))
                    }
                    .padding(8)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 460, minHeight: 520)
        .onAppear {
            refreshLaunchAtLoginStatus()
            if model.chat.availableModels.isEmpty && !model.chat.isRunning {
                Task {
                    await model.chat.refreshAvailableModels()
                }
            }
        }
    }
    
    // MARK: - SMAppService Launch-at-Login Management
    
    private func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLoginStatus = status
        launchAtLoginEnabled = (status == .enabled)
    }
    
    private func toggleLaunchAtLogin(_ enable: Bool) {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        errorMessage = nil
        statusMessage = nil
        
        do {
            if enable {
                try SMAppService.mainApp.register()
                statusMessage = "Girişte otomatik başlatma kaydedildi."
            } else {
                try SMAppService.mainApp.unregister()
                statusMessage = "Girişte otomatik başlatma kaldırıldı."
            }
        } catch {
            errorMessage = "İşlem başarısız: \(error.localizedDescription)"
        }
        
        refreshLaunchAtLoginStatus()
        isPerformingAction = false
    }
    
    private func resetWindowPositions() {
        NotificationCenter.default.post(name: Notification.Name("HomelabDeskResetWindowPositions"), object: nil)
        statusMessage = "Pencere konumları sıfırlandı."
    }
    
    // MARK: - Helper UI Builders
    
    @ViewBuilder
    private func statusBadge(for status: SMAppService.Status) -> some View {
        switch status {
        case .enabled:
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Etkin").font(.caption).bold()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.15))
            .cornerRadius(6)
        case .requiresApproval:
            HStack(spacing: 4) {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
                Text("Onay Bekliyor").font(.caption).bold()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.15))
            .cornerRadius(6)
        case .notRegistered:
            HStack(spacing: 4) {
                Circle().fill(Color.secondary).frame(width: 8, height: 8)
                Text("Kayıtlı Değil").font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
        case .notFound:
            HStack(spacing: 4) {
                Circle().fill(Color.secondary).frame(width: 8, height: 8)
                Text("Paket Bulunamadı").font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
        @unknown default:
            Text("Bilinmiyor").font(.caption)
        }
    }
    
    private func statusDescription(for status: SMAppService.Status) -> String {
        switch status {
        case .enabled:
            return "Uygulama, macOS oturumu açıldığında otomatik olarak arka planda başlatılacaktır."
        case .requiresApproval:
            return "macOS Sistem Ayarları > Genel > Giriş Öğeleri bölümünden uygulamanın başlatılmasına izin vermeniz gerekmektedir."
        case .notRegistered:
            return "Uygulama açılışta başlamaz; yalnızca manuel açıldığında çalışır."
        case .notFound:
            return "Uygulama henüz /Applications dizinine kurulmamış olabilir (Geliştirme derlemesi)."
        @unknown default:
            return "Durum okunamadı."
        }
    }
    
    @ViewBuilder
    private func modeCard(title: String, subtitle: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 18))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(title)
                    .font(.system(.subheadline, design: .default, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Text(subtitle)
                    .font(.system(.caption2, design: .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
    
    @ViewBuilder
    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(.subheadline, design: .default))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
