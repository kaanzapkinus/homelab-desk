import SwiftUI
import WidgetKit
import Foundation

private struct DeskEntry: TimelineEntry {
    let date: Date
    let snapshot: DeviceSnapshot
    let serviceSummary: String
}
private struct DeskProvider: TimelineProvider {
    func placeholder(in context: Context) -> DeskEntry {
        DeskEntry(date: Date(), snapshot: DeviceSnapshot(), serviceSummary: "Ölçüm bekleniyor")
    }
    func getSnapshot(in context: Context, completion: @escaping (DeskEntry) -> Void) {
        if context.isPreview { completion(placeholder(in: context)); return }
        Task { completion(await collect()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DeskEntry>) -> Void) {
        Task {
            let entry = await collect()
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(900))))
        }
    }
    private func resolveStatusURL() -> URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "HomelabStatusURL") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            return nil
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" else {
            return nil
        }
        guard let host = url.host?.lowercased(),
              host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" else {
            return nil
        }
        return url
    }
    private func collect() async -> DeskEntry {
        _ = await HostMetrics.sample()
        try? await Task.sleep(nanoseconds: 400_000_000)
        let snapshot = await HostMetrics.sample()
        let raw = (Bundle.main.object(forInfoDictionaryKey: "HomelabStatusURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary: String
        if raw.isEmpty {
            summary = "Servis URL yapılandırılmadı · uygulamada kontrol edin"
        } else if let url = resolveStatusURL() {
            summary = await queryServiceHealth(url: url)
        } else {
            summary = "Geçersiz servis adresi · sadece yerel HTTP loopback desteklenir"
        }
        return DeskEntry(date: Date(), snapshot: snapshot, serviceSummary: summary)
    }
    private func queryServiceHealth(url: URL) async -> String {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            let (data, response) = try await URLSession.shared.data(for: request)
            if let response = response as? HTTPURLResponse, response.statusCode == 200, data.count < 262_144,
               let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let observedAt = (object["observedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                let age = observedAt.map { Date().timeIntervalSince($0) }
                if object["stale"] as? Bool == false, let age, age >= -5, age <= 30,
                   let ready = object["readyCount"] as? Int, let total = object["total"] as? Int,
                   total > 0, ready >= 0, ready <= total {
                    let maintenance = object["maintenance"] as? [String: Any]
                    return maintenance?["active"] as? Bool == true
                        ? "Bakım etkin · \(ready)/\(total) hedef yanıtlıyor"
                        : "\(ready)/\(total) hedef yanıtlıyor · API gözlemi"
                } else {
                    return "Servis gözlemi güncel değil · uygulamada kontrol edin"
                }
            } else {
                return "Servis API yanıt vermedi · uygulamada kontrol edin"
            }
        } catch {
            return "Durum API erişilemiyor · uygulamada yerel kontrol"
        }
    }
}

private enum DeskWidgetKind: String {
    case overview, memory, disk, connection, services
    var title: String {
        switch self {
        case .overview: return "Mac özeti"
        case .memory: return "CPU ve bellek"
        case .disk: return "Depolama"
        case .connection: return "Bağlantı"
        case .services: return "Kritik servisler"
        }
    }
    var symbol: String {
        switch self {
        case .overview: return "desktopcomputer"
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .connection: return "network"
        case .services: return "cross.case"
        }
    }
}
private struct DeskWidgetView: View {
    let entry: DeskEntry
    let kind: DeskWidgetKind
    @Environment(\.widgetFamily) private var family
    private func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Ölçülemedi" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
    private var cpu: String {
        entry.snapshot.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "Ölçülemedi"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(kind.title, systemImage: kind.symbol).font(.headline)
            switch kind {
            case .overview, .memory:
                row("CPU", cpu)
                row("Bellek", bytes(entry.snapshot.memoryUsedBytes))
                if family != .systemSmall {
                    row("Toplam", bytes(entry.snapshot.memoryTotalBytes))
                    row("Bellek baskısı", entry.snapshot.memoryPressure)
                    row("Swap", bytes(entry.snapshot.swapUsedBytes))
                }
            case .disk:
                row("Boş", bytes(entry.snapshot.diskFreeBytes))
                row("Toplam", bytes(entry.snapshot.diskTotalBytes))
                if family != .systemSmall {
                    Text(entry.snapshot.externalVolumes.isEmpty ? "Harici disk gözlenmedi" : entry.snapshot.externalVolumes.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            case .connection:
                Text(entry.snapshot.interfaceStatus).font(.subheadline).lineLimit(2)
                if family != .systemSmall {
                    row("İnternet", entry.snapshot.internetStatus)
                    row("DNS", entry.snapshot.dnsStatus)
                    row("Tailscale", entry.snapshot.tailscaleStatus)
                } else { Text("Canlı ayrıntı için açın").font(.caption).foregroundStyle(.secondary) }
            case .services:
                Text(entry.serviceSummary).font(.subheadline).lineLimit(3)
                Text("Kurtarma için uygulamayı açın. İşlem otomatik çalışmaz.").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Text("Son ölçüm")
                Text(entry.snapshot.observedAt, style: .time)
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .containerBackground(.background, for: .widget)
        .widgetURL(URL(string: "homelabdesk://panel/\(kind.rawValue)"))
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium).multilineTextAlignment(.trailing)
        }.font(.subheadline)
    }
}
private struct DeskWidget: Widget {
    let selection: DeskWidgetKind
    init() { selection = .overview }
    init(selection: DeskWidgetKind) { self.selection = selection }
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.homelab.desk.\(selection.rawValue)", provider: DeskProvider()) { entry in
            DeskWidgetView(entry: entry, kind: selection)
        }
        .configurationDisplayName(selection.title)
        .description("Mac mini ölçümlerinin zaman damgalı özeti. Canlı ayrıntı Homelab Desk uygulamasında.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
@main struct HomelabDeskWidgets: WidgetBundle {
    var body: some Widget {
        DeskWidget(selection: .overview)
        DeskWidget(selection: .memory)
        DeskWidget(selection: .disk)
        DeskWidget(selection: .connection)
        DeskWidget(selection: .services)
    }
}
