import SwiftUI
import AppKit

/// DashboardView: Full native main surface integrating live host metrics,
/// local OMP chat, and deterministic service recovery.
/// Adapts dynamically between desktop multi-column and phone-friendly 450pt single-column remote mode.
public struct DashboardView: View {
    @ObservedObject var model: AppModel
    
    init(model: AppModel) {
        self.model = model
    }
    
    public var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Main Toolbar
                toolbarView
                
                Divider()
                
                // Adaptive Content
                if model.remoteMode || geometry.size.width < 640 {
                    remoteSingleColumnView
                } else {
                    desktopMultiColumnView(width: geometry.size.width)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
    
    // MARK: - Toolbar View
    
    private var toolbarView: some View {
        HStack(spacing: 12) {
            // Mode Segmented Controls (Desktop / Odak / Telefon)
            Picker("", selection: Binding(
                get: {
                    model.windowMode
                },
                set: { newMode in
                    model.setWindowMode(newMode)
                }
            )) {
                Text("Masaüstü").tag(AppModel.WindowMode.desktop)
                Text("Odak").tag(AppModel.WindowMode.focus)
                Text("Telefon").tag(AppModel.WindowMode.remote)
            }
            .pickerStyle(.segmented)
            .frame(width: model.remoteMode ? 240 : 200)
            
            Spacer()
            
            // Refresh Button
            Button {
                Task {
                    await model.refresh()
                }
            } label: {
                HStack(spacing: 4) {
                    if model.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    if !model.remoteMode {
                        Text("Yenile")
                    }
                }
                .font(.system(model.remoteMode ? .body : .caption, design: .default))
                .frame(minHeight: model.remoteMode ? 44 : 26)
            }
            .buttonStyle(.bordered)
            .controlSize(model.remoteMode ? .large : .small)
            .disabled(model.isLoading)
            
            // Compact Metrics Panel Button
            Button {
                NotificationCenter.default.post(name: Notification.Name("HomelabDeskToggleMetricsPanel"), object: nil)
            } label: {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: model.remoteMode ? 18 : 13))
                    .frame(minHeight: model.remoteMode ? 44 : 26)
            }
            .buttonStyle(.bordered)
            .controlSize(model.remoteMode ? .large : .small)
            .help("Kompakt Canlı Metrik Panelini Aç/Kapat")
            
            // Settings Button
            Button {
                NotificationCenter.default.post(name: Notification.Name("HomelabDeskShowPreferences"), object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: model.remoteMode ? 18 : 13))
                    .frame(minHeight: model.remoteMode ? 44 : 26)
            }
            .buttonStyle(.bordered)
            .controlSize(model.remoteMode ? .large : .small)
        }
        .padding(.horizontal, model.remoteMode ? 16 : 12)
        .padding(.vertical, model.remoteMode ? 12 : 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - Remote Enlarged Single-Column View (450pt, 18pt+ font, 44pt+ buttons)
    
    private var remoteSingleColumnView: some View {
        VStack(spacing: 0) {
            // Segmented Section Picker driven by model selected live destination
            Picker("", selection: $model.selectedDestination) {
                ForEach(AppModel.LiveDestination.allCases) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            
            Divider()
            
            // Selected Section Surface
            Group {
                switch model.selectedDestination {
                case .metrics:
                    ScrollView {
                        LiveMetricsOverview(monitor: model.monitor, remoteMode: true)
                            .padding(16)
                    }
                case .chat:
                    ChatView(model: model)
                case .recovery:
                    RecoveryView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    // MARK: - Desktop Multi-Column View
    
    @ViewBuilder
    private func desktopMultiColumnView(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            // Left Column: Live Metrics & Recovery Services
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Live Metrics Subview observing DeviceMonitor directly
                        LiveMetricsOverview(monitor: model.monitor, remoteMode: false)
                        
                        Divider()
                        
                        // Recovery Section
                        RecoveryView(model: model)
                    }
                    .padding(12)
                }
            }
            .frame(width: max(340, min(480, width * 0.45)))
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
            
            Divider()
            
            // Right Column: Chat View
            ChatView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Live Metrics Overview (Observes DeviceMonitor directly)

public struct LiveMetricsOverview: View {
    @ObservedObject var monitor: DeviceMonitor
    let remoteMode: Bool
    
    init(monitor: DeviceMonitor, remoteMode: Bool = false) { self.monitor = monitor
    self.remoteMode = remoteMode
         }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: remoteMode ? 14 : 10) {
            // Header with observation timestamp
            HStack {
                Text("Sistem Metrikleri")
                    .font(.system(remoteMode ? .title3 : .headline, design: .default, weight: .bold))
                Spacer()
                Button {
                    NotificationCenter.default.post(name: Notification.Name("HomelabDeskShowMetricsPanel"), object: nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pip.enter")
                        if !remoteMode {
                            Text("Kompakt Panel")
                        }
                    }
                    .font(.system(remoteMode ? .caption : .caption2, design: .default))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .help("Kompakt paneli göster (çift tıklama ile de açılabilir)")
                
                Text("Gözlem: \(monitor.snapshot.observedAt.formatted(date: .omitted, time: .standard))")
                    .font(.system(remoteMode ? .caption : .caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            
            // CPU & Memory Cards Grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: remoteMode ? 12 : 8) {
                cpuCard
                memoryCard
            }
            
            // Disk & Network Cards Grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: remoteMode ? 12 : 8) {
                diskCard
                networkCard
            }
            
            // Notes if present
            if !monitor.snapshot.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(monitor.snapshot.notes, id: \.self) { note in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.system(size: remoteMode ? 14 : 11))
                                .foregroundStyle(.secondary)
                            Text(note)
                                .font(.system(remoteMode ? .callout : .caption, design: .default))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            NotificationCenter.default.post(name: Notification.Name("HomelabDeskShowMetricsPanel"), object: nil)
        }
    }
    
    // MARK: - CPU Card with Native Path Sparkline
    
    private var cpuCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("İşlemci (CPU)", systemImage: "cpu")
                    .font(.system(remoteMode ? .body : .caption, design: .default, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let cpu = monitor.snapshot.cpuPercent {
                    Text(String(format: "%.1f%%", cpu))
                        .font(.system(remoteMode ? .title2 : .body, design: .monospaced, weight: .bold))
                } else {
                    Text("Ölçülüyor…")
                        .font(.system(remoteMode ? .callout : .caption, design: .default))
                        .foregroundStyle(.secondary)
                }
            }
            
            // Sparkline of CPU history
            NativeSparklineView(
                points: monitor.history.compactMap { $0.cpu },
                color: Color.accentColor,
                height: remoteMode ? 44 : 32
            )
        }
        .padding(remoteMode ? 12 : 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - Memory Card
    
    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Bellek (RAM)", systemImage: "memorychip")
                    .font(.system(remoteMode ? .body : .caption, design: .default, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                pressureBadge(for: monitor.snapshot.memoryPressure)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                if let used = monitor.snapshot.memoryUsedBytes, let total = monitor.snapshot.memoryTotalBytes {
                    Text("\(formatBytes(used)) / \(formatBytes(total))")
                        .font(.system(remoteMode ? .title3 : .subheadline, design: .monospaced, weight: .bold))
                } else {
                    Text("—")
                        .font(.system(remoteMode ? .title3 : .subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                
                if let swap = monitor.snapshot.swapUsedBytes, swap > 0 {
                    Text("Swap: \(formatBytes(swap))")
                        .font(.system(remoteMode ? .caption : .caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            
            // Sparkline of Memory history
            NativeSparklineView(
                points: monitor.history.compactMap { pt in
                    guard let mem = pt.memory, let total = monitor.snapshot.memoryTotalBytes, total > 0 else { return nil }
                    return (mem / total) * 100.0
                },
                color: Color.purple,
                height: remoteMode ? 32 : 24
            )
        }
        .padding(remoteMode ? 12 : 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - Disk Card
    
    private var diskCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Dahili Disk", systemImage: "internaldrive")
                    .font(.system(remoteMode ? .body : .caption, design: .default, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            
            if let free = monitor.snapshot.diskFreeBytes, let total = monitor.snapshot.diskTotalBytes {
                let used = total - free
                let percentUsed = total > 0 ? (used / total) * 100.0 : 0.0
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(formatBytes(free)) boş")
                        .font(.system(remoteMode ? .title3 : .subheadline, design: .monospaced, weight: .bold))
                    Text("Toplam: \(formatBytes(total)) (% \(Int(percentUsed)) dolu)")
                        .font(.system(remoteMode ? .caption : .caption2, design: .default))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("—")
                    .font(.system(remoteMode ? .title3 : .subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            
            if !monitor.snapshot.externalVolumes.isEmpty {
                Text("Harici: \(monitor.snapshot.externalVolumes.joined(separator: ", "))")
                    .font(.system(remoteMode ? .caption : .caption2, design: .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(remoteMode ? 12 : 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - Network Card
    
    private var networkCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Ağ & Tailscale", systemImage: "network")
                    .font(.system(remoteMode ? .body : .caption, design: .default, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                statusFact(label: "Ağ Kartı", value: monitor.snapshot.interfaceStatus)
                statusFact(label: "İnternet", value: monitor.snapshot.internetStatus)
                statusFact(label: "DNS", value: monitor.snapshot.dnsStatus)
                statusFact(label: "Tailscale", value: monitor.snapshot.tailscaleStatus)
            }
        }
        .padding(remoteMode ? 12 : 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - Helpers
    
    @ViewBuilder
    private func statusFact(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(factColor(value))
                .frame(width: remoteMode ? 8 : 6, height: remoteMode ? 8 : 6)
            Text(label + ":")
                .font(.system(remoteMode ? .caption : .caption2, design: .default))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(remoteMode ? .caption : .caption2, design: .default, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
        }
    }
    
    private func factColor(_ value: String) -> Color {
        switch ObservationHealth(status: value) {
        case .positive:
            return .green
        case .negative:
            return .red
        case .limited:
            return .orange
        case .unknown:
            return .secondary
        }
    }
    
    @ViewBuilder
    private func pressureBadge(for pressure: String) -> some View {
        let p = pressure.lowercased()
        let color: Color = {
            if p.contains("kritik") || p.contains("critical") { return .red }
            if p.contains("uyarı") || p.contains("warning") { return .orange }
            if p.contains("normal") { return .green }
            return .secondary
        }()
        
        Text(pressure)
            .font(.system(remoteMode ? .caption : .caption2, design: .default, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .cornerRadius(4)
    }
    
    private func formatBytes(_ bytes: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Compact Metrics Panel View (For Separate Compact Live Metrics Panel Window)

public struct CompactMetricsPanelView: View {
    @ObservedObject var monitor: DeviceMonitor
    
    init(monitor: DeviceMonitor) { self.monitor = monitor
         }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(Color.accentColor)
                Text("Homelab Canlı Panel")
                    .font(.system(.subheadline, design: .default, weight: .bold))
                Spacer()
                Button {
                    NotificationCenter.default.post(name: Notification.Name("HomelabDeskFocusWindow"), object: nil)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("Ana Pencereyi Aç")
                
                Text(monitor.snapshot.observedAt.formatted(date: .omitted, time: .standard))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            
            Divider()
            
            // CPU & RAM Row
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CPU")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let cpu = monitor.snapshot.cpuPercent {
                        Text(String(format: "%.1f%%", cpu))
                            .font(.system(.body, design: .monospaced, weight: .bold))
                    } else {
                        Text("—")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                NativeSparklineView(
                    points: monitor.history.compactMap { $0.cpu },
                    color: Color.accentColor,
                    height: 22
                )
                .frame(width: 70)
                
                Divider()
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("RAM")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let used = monitor.snapshot.memoryUsedBytes {
                        Text(formatBytes(used))
                            .font(.system(.body, design: .monospaced, weight: .bold))
                    } else {
                        Text("—")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // Tailscale & Internet Indicators
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(observationColor(monitor.snapshot.tailscaleStatus))
                        .frame(width: 6, height: 6)
                    Text("Tailscale: \(monitor.snapshot.tailscaleStatus)")
                        .font(.system(.caption2, design: .default))
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(observationColor(monitor.snapshot.internetStatus))
                        .frame(width: 6, height: 6)
                    Text("İnternet: \(monitor.snapshot.internetStatus)")
                        .font(.system(.caption2, design: .default))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(width: 300, height: 110)
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            NotificationCenter.default.post(name: Notification.Name("HomelabDeskFocusWindow"), object: nil)
        }
    }
    
    private func observationColor(_ status: String) -> Color {
        switch ObservationHealth(status: status) {
        case .positive:
            return .green
        case .negative:
            return .red
        case .limited:
            return .orange
        case .unknown:
            return .secondary
        }
    }
    private func formatBytes(_ bytes: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Native Path Sparkline View (No external packages, smooth & robust)

public struct NativeSparklineView: View {
    let points: [Double]
    let color: Color
    let height: CGFloat
    
    init(points: [Double], color: Color = .accentColor, height: CGFloat = 30) { self.points = points
    self.color = color
    self.height = height
         }
    
    public var body: some View {
        GeometryReader { geometry in
            if points.count >= 2 {
                let validPoints = points.suffix(30)
                let minVal = 0.0
                let maxVal = max(100.0, validPoints.max() ?? 100.0)
                let range = max(1.0, maxVal - minVal)
                
                let stepX = geometry.size.width / CGFloat(validPoints.count - 1)
                
                ZStack {
                    // Filled Area
                    Path { path in
                        for (index, val) in validPoints.enumerated() {
                            let x = CGFloat(index) * stepX
                            let normalized = CGFloat((val - minVal) / range)
                            let y = geometry.size.height * (1.0 - normalized)
                            
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                        path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                        path.addLine(to: CGPoint(x: 0, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.3), color.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    
                    // Stroke Line
                    Path { path in
                        for (index, val) in validPoints.enumerated() {
                            let x = CGFloat(index) * stepX
                            let normalized = CGFloat((val - minVal) / range)
                            let y = geometry.size.height * (1.0 - normalized)
                            
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            } else {
                // Placeholder line when insufficient data
                Rectangle()
                    .fill(color.opacity(0.1))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(height: height)
    }
}
