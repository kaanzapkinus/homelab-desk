import Foundation
import Combine

/// Visible windows share fast CPU/RAM samples; disk and network observations have a slow cadence.
@MainActor
final class DeviceMonitor: ObservableObject {
    enum DemandSource: Hashable { case mainWindow, metricsPanel }

    @Published var snapshot: DeviceSnapshot
    @Published var history: [MetricPoint]
    @Published private(set) var slowObservedAt: Date?

    var isRunning: Bool { monitorTask != nil }
    var hasVisibleDemand: Bool { !visibleSources.isEmpty }

    private var visibleSources: Set<DemandSource> = []
    private var isStarted = false
    private var monitorTask: Task<Void, Never>?
    private var slowTask: Task<Void, Never>?
    private var isRefreshingFast = false
    private let intervalSeconds: TimeInterval
    private let slowIntervalSeconds: TimeInterval
    private let fastSample: @Sendable () async -> DeviceSnapshot
    private let slowSample: @Sendable () async -> DeviceSnapshot

    init(
        initialSnapshot: DeviceSnapshot = DeviceSnapshot(),
        intervalSeconds: TimeInterval = 2.5,
        slowIntervalSeconds: TimeInterval = 45,
        fastSample: (@Sendable () async -> DeviceSnapshot)? = nil,
        slowSample: (@Sendable () async -> DeviceSnapshot)? = nil
    ) {
        snapshot = initialSnapshot
        history = []
        self.intervalSeconds = max(2, min(intervalSeconds, 3))
        self.slowIntervalSeconds = max(30, min(slowIntervalSeconds, 60))
        // Independent actors keep a slow network/disk observation out of the CPU/RAM path.
        let fastMetrics = HostMetrics()
        let slowMetrics = HostMetrics()
        self.fastSample = fastSample ?? { await fastMetrics.sampleFast() }
        self.slowSample = slowSample ?? { await slowMetrics.sampleSlow() }
    }

    /// Enables sampling, but only visible demand starts the periodic loop.
    func start() {
        isStarted = true
        updateLoop()
    }

    func setDemand(_ visible: Bool, for source: DemandSource) {
        if visible { visibleSources.insert(source) } else { visibleSources.remove(source) }
        updateLoop()
    }

    func stop() {
        isStarted = false
        updateLoop()
        slowTask?.cancel()
        slowTask = nil
    }

    /// Explicit refresh remains available with no visible windows and refreshes both cadences.
    func refresh() async {
        await refreshFast()
        await requestSlowRefresh(force: true)?.value
    }

    private func updateLoop() {
        guard isStarted && hasVisibleDemand else {
            monitorTask?.cancel()
            monitorTask = nil
            return
        }
        guard monitorTask == nil else { return }
        let interval = intervalSeconds
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshFast()
                guard !Task.isCancelled else { break }
                self?.requestSlowRefresh(force: false)
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch { break }
            }
        }
    }

    private func refreshFast() async {
        guard !isRefreshingFast else { return }
        isRefreshingFast = true
        defer { isRefreshingFast = false }
        let next = await fastSample()
        guard !Task.isCancelled else { return }
        snapshot.observedAt = next.observedAt
        snapshot.cpuPercent = next.cpuPercent
        snapshot.memoryUsedBytes = next.memoryUsedBytes
        snapshot.memoryTotalBytes = next.memoryTotalBytes
        snapshot.memoryPressure = next.memoryPressure
        snapshot.swapUsedBytes = next.swapUsedBytes
        snapshot.notes = next.notes
        history.append(MetricPoint(date: next.observedAt, cpu: next.cpuPercent, memory: next.memoryUsedBytes))
        if history.count > 120 { history.removeFirst(history.count - 120) }
    }

    @discardableResult
    private func requestSlowRefresh(force: Bool) -> Task<Void, Never>? {
        if let slowTask { return slowTask }
        if !force, let slowObservedAt, Date().timeIntervalSince(slowObservedAt) < slowIntervalSeconds { return nil }
        let sample = slowSample
        let task = Task { [weak self] in
            let next = await sample()
            guard !Task.isCancelled, let self else { return }
            self.snapshot.diskFreeBytes = next.diskFreeBytes
            self.snapshot.diskTotalBytes = next.diskTotalBytes
            self.snapshot.externalVolumes = next.externalVolumes
            self.snapshot.interfaceStatus = next.interfaceStatus
            self.snapshot.internetStatus = next.internetStatus
            self.snapshot.dnsStatus = next.dnsStatus
            self.snapshot.tailscaleStatus = next.tailscaleStatus
            self.slowObservedAt = next.observedAt
            self.slowTask = nil
        }
        slowTask = task
        return task
    }

    deinit {
        monitorTask?.cancel()
        slowTask?.cancel()
    }
}
