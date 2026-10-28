import Foundation
import Combine

@MainActor final class AppModel: ObservableObject {
    enum WindowMode: String, CaseIterable, Sendable {
        case desktop
        case focus
        case remote
    }

    enum LiveDestination: String, CaseIterable, Identifiable, Sendable {
        case metrics = "Metrikler"
        case chat = "Sohbet"
        case recovery = "Kurtarma"

        var id: String { rawValue }
        var title: String { rawValue }
        var icon: String {
            switch self {
            case .metrics: return "chart.xyaxis.line"
            case .chat: return "bubble.left.and.bubble.right.fill"
            case .recovery: return "wrench.and.screwdriver.fill"
            }
        }
    }

    let monitor = DeviceMonitor()
    let chat = OMPClient()
    let recovery = RecoveryBackend()
    private let approvals = ApprovalPolicy()
    @Published var targets: [ServiceTarget] = []
    @Published var events: [DeskEvent] = []
    @Published var proposal: RecoveryProposal?
    @Published var jobs: [RecoveryJob] = []
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var windowMode: WindowMode = .desktop
    @Published var selectedDestination: LiveDestination = .chat
    @Published var remoteMode = false
    var onWindowModeChange: ((WindowMode) -> Void)?
    private var refreshTask: Task<Void, Never>?
    private var jobTasks: [String: Task<Void, Never>] = [:]
    private let eventURL: URL

    func setWindowMode(_ mode: WindowMode) {
        windowMode = mode
        let isRemote = (mode == .remote)
        if remoteMode != isRemote {
            remoteMode = isRemote
        }
        onWindowModeChange?(mode)
    }

    func navigate(to route: String) {
        switch route {
        case "overview", "memory", "disk", "connection":
            selectedDestination = .metrics
        case "services":
            selectedDestination = .recovery
        case "chat":
            selectedDestination = .chat
        default:
            break
        }
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Homelab Desk", isDirectory: true)
        eventURL = support.appendingPathComponent("events.json")
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: eventURL.path) {
                let data = try Data(contentsOf: eventURL)
                if data.count <= 256_000 { events = Array(try JSONDecoder().decode([DeskEvent].self, from: data).suffix(80)) }
            }
        } catch { errorMessage = "Yerel olay geçmişi okunamadı: \(error.localizedDescription)" }
        chat.onHostTool = { [weak self] name, arguments in
            guard let self else { throw DeskError.unavailable("Uygulama kapandı") }
            return try await self.hostTool(name, arguments)
        }
    }

    func start() {
        guard refreshTask == nil else { return }
        monitor.start()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                if self?.monitor.hasVisibleDemand == true {
                    await self?.refreshServices()
                }
                do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { break }
            }
        }
    }
    func shutdown() {
        refreshTask?.cancel(); refreshTask = nil
        jobTasks.values.forEach { $0.cancel() }; jobTasks.removeAll()
        monitor.stop(); chat.close()
    }
    func refresh() async {
        await monitor.refresh()
        await refreshServices()
    }
    private func refreshServices() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            targets = try await recovery.targets()
            if errorMessage?.hasPrefix("Servis envanteri") == true { errorMessage = nil }
        } catch {
            errorMessage = "Servis envanteri güncellenemedi. Eski kayıtlar güncel sağlık değildir: \(error.localizedDescription)"
        }
    }
    func send(_ text: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.utf8.count <= 64_000 else { return }
        await chat.send(prompt)
    }
    func stop() async { await chat.stop() }
    func newConversation() async { await chat.newConversation() }

    func requestRecovery(_ target: ServiceTarget) {
        guard target.actionable, target.installed else {
            errorMessage = target.reason ?? "Bu hedef için kurtarma yetkisi yok."
            return
        }
        guard proposal == nil else {
            errorMessage = "Önce açık işlem önerisini onaylayın veya iptal edin."
            return
        }
        proposal = approvals.propose(target: target)
    }
    func cancelRecovery() {
        if let proposal { record("İşlem iptal edildi", proposal.display, isError: false) }
        proposal = nil
    }
    func confirmRecovery(independentAccess: Bool) async {
        guard let current = proposal else { return }
        proposal = nil
        do {
            try approvals.consume(current, targetKey: current.targetKey, independentAccess: independentAccess)
            let job = try await recovery.restart(targetKey: current.targetKey, action: current.action, independentAccess: independentAccess, approvedAt: current.createdAt)
            jobs.insert(job, at: 0); jobs = Array(jobs.prefix(20))
            record("Kurtarma istendi", "\(current.display): \(job.phase). Hazır olduğu henüz doğrulanmadı.", isError: false)
            observe(job)
        } catch {
            errorMessage = "İşlem başlatılmadı: \(error.localizedDescription)"
            record("Kurtarma engellendi", error.localizedDescription, isError: true)
        }
    }
    private func observe(_ initial: RecoveryJob) {
        guard jobTasks[initial.id] == nil else { return }
        jobTasks[initial.id] = Task { [weak self] in
            defer { self?.jobTasks[initial.id] = nil }
            for _ in 0..<300 {
                guard !Task.isCancelled, let self else { return }
                do {
                    let update = try await self.recovery.job(id: initial.id)
                    if let index = self.jobs.firstIndex(where: { $0.id == update.id }) { self.jobs[index] = update }
                    if update.terminal {
                        self.record("Kurtarma sonucu: \(update.phase)", update.error ?? update.message ?? update.targetKey, isError: !["healthy", "succeeded"].contains(update.phase))
                        await self.refreshServices(); return
                    }
                } catch {
                    self.errorMessage = "İşlem sonucu okunamadı; başarı varsayılmıyor: \(error.localizedDescription)"
                }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
            self?.record("İzleme süresi doldu", "Worker durdurulmadı. Sonuç servis listesinden yeniden kontrol edilmeli.", isError: true)
        }
    }
    func record(_ title: String, _ detail: String, isError: Bool) {
        events.append(DeskEvent(title: title, detail: String(detail.prefix(4_000)), isError: isError))
        events = Array(events.suffix(80))
        do {
            try JSONEncoder().encode(events).write(to: eventURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: eventURL.path)
        } catch { errorMessage = "Olay kaydı diske yazılamadı: \(error.localizedDescription)" }
    }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DeskError.unavailable("Geçersiz gözlem") }
        return object
    }
    private func hostTool(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        switch name {
        case "read_device_snapshot":
            await monitor.refresh()
            try Task.checkCancellation()
            return try object(monitor.snapshot)
        case "inspect_services":
            let fresh = try await recovery.targets()
            try Task.checkCancellation()
            targets = fresh
            let requested = arguments["targetKey"] as? String
            let selected = requested.map { key in fresh.filter { $0.key == key } } ?? fresh
            return ["observedAt": ISO8601DateFormatter().string(from: Date()), "targets": try selected.map { try object($0) }]
        case "read_diagnostics":
            return ["untrustedContent": true, "diagnostics": try await recovery.diagnostics(targetKey: arguments["targetKey"] as? String)]
        case "propose_recovery":
            guard let key = arguments["targetKey"] as? String else { throw DeskError.unavailable("Hedef gerekli") }
            let fresh = try await recovery.targets()
            try Task.checkCancellation()
            targets = fresh
            guard let target = fresh.first(where: { $0.key == key }), target.actionable, target.installed else { throw DeskError.unavailable("Hedef bulunamadı veya yetkili değil") }
            guard proposal == nil else { throw DeskError.unavailable("Başka bir öneri kullanıcı onayını bekliyor") }
            requestRecovery(target)
            return ["status": "awaiting_native_user_confirmation", "targetKey": key, "message": "Yalnızca öneri açıldı. İşlem çalıştırılmadı; onay yetkisi modelde değil."]
        case "read_recovery_job":
            guard let id = arguments["id"] as? String, jobs.contains(where: { $0.id == id }) else { throw DeskError.unavailable("Bu uygulamanın bilinen işlem kimliği gerekli") }
            return try object(try await recovery.job(id: id))
        default:
            throw DeskError.unavailable("Bu araç için yetki yok: \(name)")
        }
    }
}

enum DeskError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { switch self { case .unavailable(let message): return message } }
}
