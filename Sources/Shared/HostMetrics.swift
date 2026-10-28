import Foundation
import Darwin
import Network

/// Serialized sampler for host metrics on macOS.
/// Thread-safe actor that maintains CPU delta baseline across samples.
/// Usable in sandboxed WidgetKit extension and the native application.
actor HostMetrics {
    static let shared = HostMetrics()

    static func sample() async -> DeviceSnapshot {
        await shared.sample()
    }

    private struct CPULoadSample {
        let ticks: host_cpu_load_info_data_t
        let date: Date
    }

    private var lastCPUSample: CPULoadSample?

    init() {}

    /// Complete bounded snapshot for independent WidgetKit requests.
    func sample() async -> DeviceSnapshot {
        var snapshot = sampleFast()
        let slow = await sampleSlow()
        snapshot.diskFreeBytes = slow.diskFreeBytes
        snapshot.diskTotalBytes = slow.diskTotalBytes
        snapshot.externalVolumes = slow.externalVolumes
        snapshot.interfaceStatus = slow.interfaceStatus
        snapshot.internetStatus = slow.internetStatus
        snapshot.dnsStatus = slow.dnsStatus
        snapshot.tailscaleStatus = slow.tailscaleStatus
        return snapshot
    }

    /// Cheap Mach/sysctl observations, independent of disk and connectivity work.
    func sampleFast() -> DeviceSnapshot {
        var snapshot = DeviceSnapshot()
        // 1. CPU Utilization (Mach HOST_CPU_LOAD_INFO delta)
        snapshot.cpuPercent = sampleCPU()
        if snapshot.cpuPercent == nil {
            snapshot.notes.append("İlk CPU ölçümü bekleniyor")
        }

        // 2. Memory, Swap, and Pressure
        let mem = sampleMemory()
        snapshot.memoryUsedBytes = mem.used
        snapshot.memoryTotalBytes = mem.total
        snapshot.memoryPressure = mem.pressure
        snapshot.swapUsedBytes = mem.swap
        return snapshot
    }

    /// Slow observations, called on demand or at the app's 30–60 second cadence.
    func sampleSlow() async -> DeviceSnapshot {
        var snapshot = DeviceSnapshot()
        // Disk Space and External Volume Presence
        let disk = sampleDisk()
        snapshot.diskFreeBytes = disk.free
        snapshot.diskTotalBytes = disk.total
        snapshot.externalVolumes = disk.external

        // 4. Distinct Network Connectivity Observations
        let conn = await sampleConnectivity()
        snapshot.interfaceStatus = conn.interface
        snapshot.internetStatus = conn.internet
        snapshot.dnsStatus = conn.dns
        snapshot.tailscaleStatus = conn.tailscale

        return snapshot
    }

    // MARK: - CPU (Mach host_statistics)

    private func sampleCPU() -> Double? {
        var cpuInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)

        let kr = withUnsafeMutablePointer(to: &cpuInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPointer, &count)
            }
        }

        guard kr == KERN_SUCCESS else {
            return nil
        }

        let now = Date()
        guard let prev = lastCPUSample else {
            lastCPUSample = CPULoadSample(ticks: cpuInfo, date: now)
            return nil // First sample is unavailable; never fake 0
        }

        let elapsed = now.timeIntervalSince(prev.date)
        if elapsed < 0.2 {
            // Sample interval too small for meaningful rate; retain previous baseline
            return nil
        }
        if elapsed > 120.0 {
            // Long gap (e.g. system sleep/wake); reset baseline
            lastCPUSample = CPULoadSample(ticks: cpuInfo, date: now)
            return nil
        }

        // Ensure ticks haven't wrapped or rebooted
        guard cpuInfo.cpu_ticks.0 >= prev.ticks.cpu_ticks.0,
              cpuInfo.cpu_ticks.1 >= prev.ticks.cpu_ticks.1,
              cpuInfo.cpu_ticks.2 >= prev.ticks.cpu_ticks.2,
              cpuInfo.cpu_ticks.3 >= prev.ticks.cpu_ticks.3 else {
            lastCPUSample = CPULoadSample(ticks: cpuInfo, date: now)
            return nil
        }

        let userDelta = Double(cpuInfo.cpu_ticks.0 - prev.ticks.cpu_ticks.0)
        let systemDelta = Double(cpuInfo.cpu_ticks.1 - prev.ticks.cpu_ticks.1)
        let idleDelta = Double(cpuInfo.cpu_ticks.2 - prev.ticks.cpu_ticks.2)
        let niceDelta = Double(cpuInfo.cpu_ticks.3 - prev.ticks.cpu_ticks.3)

        let totalTicks = userDelta + systemDelta + idleDelta + niceDelta
        let usedTicks = userDelta + systemDelta + niceDelta

        lastCPUSample = CPULoadSample(ticks: cpuInfo, date: now)

        guard totalTicks > 0 else {
            return nil
        }

        let percent = (usedTicks / totalTicks) * 100.0
        return min(max((percent * 10.0).rounded() / 10.0, 0.0), 100.0)
    }

    // MARK: - Memory, Swap & Pressure

    private func sampleMemory() -> (used: Double?, total: Double?, pressure: String, swap: Double?) {
        var totalBytes: Double? = nil
        var usedBytes: Double? = nil
        var pressure = "Ölçülmedi"
        var swapBytes: Double? = nil

        // 1. Total Physical RAM via sysctl hw.memsize
        var memsize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &memsize, &size, nil, 0) == 0 {
            totalBytes = Double(memsize)
        }

        // 2. Mach VM Statistics (HOST_VM_INFO64)
        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let kr = withUnsafeMutablePointer(to: &vmStats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPointer, &count)
            }
        }

        if kr == KERN_SUCCESS {
            var pageSize: vm_size_t = 0
            host_page_size(mach_host_self(), &pageSize)
            if pageSize == 0 {
                pageSize = vm_kernel_page_size > 0 ? vm_kernel_page_size : vm_size_t(getpagesize())
            }

            // macOS Activity Monitor: Used = App (internal - purgeable) + Wired + Compressed
            let appPages: UInt64
            if vmStats.internal_page_count > 0 {
                if vmStats.internal_page_count >= vmStats.purgeable_count {
                    appPages = UInt64(vmStats.internal_page_count - vmStats.purgeable_count)
                } else {
                    appPages = UInt64(vmStats.internal_page_count)
                }
            } else {
                appPages = UInt64(vmStats.active_count)
            }
            let wiredPages = UInt64(vmStats.wire_count)
            let compressedPages = UInt64(vmStats.compressor_page_count)
            let totalPages = appPages + wiredPages + compressedPages
            usedBytes = Double(totalPages * UInt64(pageSize))
        }

        // 3. Memory Pressure via sysctl kern.memorystatus_vm_pressure_level
        var pressureLevel: Int32 = 0
        var pSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &pSize, nil, 0) == 0 {
            switch pressureLevel {
            case 1:
                pressure = "Normal"
            case 2:
                pressure = "Uyarı"
            case 4:
                pressure = "Kritik"
            default:
                pressure = "Ölçülemedi"
            }
        }

        // 4. Swap Usage via sysctl vm.swapusage
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            swapBytes = Double(swap.xsu_used)
        }

        return (usedBytes, totalBytes, pressure, swapBytes)
    }

    // MARK: - Disk Space & Mounted External Volumes

    private func sampleDisk() -> (free: Double?, total: Double?, external: [String]) {
        var freeBytes: Double? = nil
        var totalBytes: Double? = nil
        var externalNames: [String] = []

        // Root volume "/" capacity (without touching file contents)
        let rootURL = URL(fileURLWithPath: "/")
        if let values = try? rootURL.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]) {
            if let total = values.volumeTotalCapacity {
                totalBytes = Double(total)
            }
            if let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) {
                freeBytes = Double(available)
            }
        }

        if freeBytes == nil || totalBytes == nil {
            if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/") {
                if totalBytes == nil, let total = attrs[.systemSize] as? NSNumber {
                    totalBytes = total.doubleValue
                }
                if freeBytes == nil, let free = attrs[.systemFreeSize] as? NSNumber {
                    freeBytes = free.doubleValue
                }
            }
        }

        // Mounted external volumes (metadata only; never read volume contents)
        let volumeKeys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeLocalizedNameKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey
        ]
        if let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(volumeKeys), options: [.skipHiddenVolumes]) {
            for url in urls {
                guard url.path != "/" else { continue }
                guard let values = try? url.resourceValues(forKeys: volumeKeys) else { continue }
                let isInternal = values.volumeIsInternal ?? true
                let isRemovable = values.volumeIsRemovable ?? false

                if !isInternal || isRemovable {
                    let name = values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent
                    if !name.isEmpty && !externalNames.contains(name) {
                        externalNames.append(name)
                    }
                }
            }
        }

        return (freeBytes, totalBytes, externalNames.sorted())
    }

    // MARK: - Connectivity

    private func sampleConnectivity() async -> (interface: String, internet: String, dns: String, tailscale: String) {
        let path = PathObserver.shared.currentPath()

        var interfaceStatus = "Ölçülmedi"
        var internetStatus = "Ölçülmedi"
        var dnsStatus = "Ölçülmedi"

        switch path.status {
        case .satisfied:
            if path.usesInterfaceType(.wiredEthernet) {
                interfaceStatus = "Aktif (Ethernet)"
            } else if path.usesInterfaceType(.wifi) {
                interfaceStatus = "Aktif (Wi-Fi)"
            } else if path.usesInterfaceType(.cellular) {
                interfaceStatus = "Aktif (Hücresel)"
            } else {
                interfaceStatus = "Aktif"
            }

            // Test internet IP connectivity and DNS resolution concurrently with strict bounds
            async let internetReachable = checkInternetProbe()
            async let dnsWorking = checkDNSProbe()

            let isInternet = await internetReachable
            let isDNS = await dnsWorking

            internetStatus = isInternet ? "Erişilebilir" : "Erişilemiyor"
            dnsStatus = isDNS ? "Çözümleme doğrulandı" : "Doğrulanamadı"

        case .requiresConnection:
            interfaceStatus = "Bağlantı Gerekiyor"
            internetStatus = "Bağlantı Yok"
            dnsStatus = "Bağlantı Yok"

        case .unsatisfied:
            interfaceStatus = "Bağlantı Yok"
            internetStatus = "Bağlantı Yok"
            dnsStatus = "Bağlantı Yok"

        @unknown default:
            interfaceStatus = "Bilinmiyor"
            internetStatus = "Bilinmiyor"
            dnsStatus = "Bilinmiyor"
        }

        // Tailscale interface observation (marked limited; no process launch in Shared/extension)
        let tailscaleStatus = observeTailscaleInterface()

        return (interfaceStatus, internetStatus, dnsStatus, tailscaleStatus)
    }

    // MARK: - Native Bounded Probes

    private func checkInternetProbe(timeoutSeconds: Double = 0.6) -> Bool {
        if probeSocket(ip: "1.1.1.1", port: 53, timeout: timeoutSeconds) {
            return true
        }
        return probeSocket(ip: "8.8.8.8", port: 53, timeout: 0.4)
    }

    private func probeSocket(ip: String, port: UInt16, timeout: Double) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian

        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if res == 0 {
            return true
        }

        if errno != EINPROGRESS {
            return false
        }

        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
        let pollTimeout = Int32(timeout * 1000)
        let pollRes = poll(&pfd, 1, pollTimeout)

        if pollRes > 0 {
            var error: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(sock, SOL_SOCKET, SO_ERROR, &error, &len) == 0 && error == 0 {
                return true
            }
        }
        return false
    }

    private func checkDNSProbe(hostname: String = "apple.com", timeoutSeconds: Double = 0.6) async -> Bool {
        await BoundedDNSResolver.shared.resolve(hostname: hostname, timeoutSeconds: timeoutSeconds)
    }

    private func observeTailscaleInterface() -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return "Arayüz gözlenemedi; oturum doğrulanmadı"
        }
        defer { freeifaddrs(firstAddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        var foundTailscaleIP: String? = nil
        var foundTailscaleIface: String? = nil

        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }

            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            guard isUp && isRunning else { continue }

            let name = String(cString: current.pointee.ifa_name)
            guard let addr = current.pointee.ifa_addr else { continue }
            let family = addr.pointee.sa_family

            if family == UInt8(AF_INET) {
                var addrIn = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addrIn.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ipStr = String(cString: buffer)
                    let parts = ipStr.split(separator: ".").compactMap { Int($0) }
                    // Tailscale CGNAT IPv4 range: 100.64.0.0/10 (100.64.0.0 - 100.127.255.255)
                    if parts.count == 4 && parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127 {
                        foundTailscaleIP = ipStr
                        foundTailscaleIface = name
                        break
                    }
                }
            } else if family == UInt8(AF_INET6) {
                var addrIn6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &addrIn6.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                    let ip6Str = String(cString: buffer).lowercased()
                    // Tailscale IPv6 prefix fd7a:115c:a1e0::/48
                    if ip6Str.hasPrefix("fd7a:115c:a1e0:") {
                        foundTailscaleIP = ip6Str
                        foundTailscaleIface = name
                        break
                    }
                }
            }

            if name.hasPrefix("tailscale") {
                foundTailscaleIface = name
            }
        }

        if let ip = foundTailscaleIP {
            return "Arayüz gözlendi (\(ip)); oturum doğrulanmadı"
        } else if let iface = foundTailscaleIface {
            return "Arayüz gözlendi (\(iface)); oturum doğrulanmadı"
        } else {
            return "Arayüz gözlenmedi; oturum doğrulanmadı"
        }
    }
}

// MARK: - PathObserver

private final class PathObserver: @unchecked Sendable {
    static let shared = PathObserver()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "homelab.desk.pathmonitor", qos: .utility)
    private let lock = NSLock()
    private var cachedPath: NWPath?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            self.lock.lock()
            self.cachedPath = path
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    func currentPath() -> NWPath {
        lock.lock()
        defer { lock.unlock() }
        return cachedPath ?? monitor.currentPath
    }
}

/// Resolver-only probe: no TCP handshake, and no work on MainActor.
/// A timed-out OS lookup may finish later; at most one lookup is ever outstanding.
final class BoundedDNSResolver: @unchecked Sendable {
    static let shared = BoundedDNSResolver()
    private let queue = DispatchQueue(label: "homelab.desk.resolver", qos: .utility)
    private let lock = NSLock()
    private var isResolving = false

    func resolve(hostname: String, timeoutSeconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !isResolving else {
                lock.unlock()
                continuation.resume(returning: false)
                return
            }
            isResolving = true
            lock.unlock()
            let gate = DNSProbeGate(continuation)
            queue.async { [self] in
                var result: UnsafeMutablePointer<addrinfo>?
                let status = getaddrinfo(hostname, nil, nil, &result)
                let resolved = status == 0 && result != nil
                if let result { freeaddrinfo(result) }
                lock.lock()
                isResolving = false
                lock.unlock()
                gate.finish(resolved)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.01, timeoutSeconds)) {
                gate.finish(false)
            }
        }
    }
}

private final class DNSProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ success: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: success)
    }
}

/// Presentation classification accepts only known local observations, never arbitrary service text.
enum ObservationHealth {
    case positive, negative, limited, unknown

    init(status: String) {
        let value = status.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "Bağlantı Yok", "Bağlantı Yok (Sınırlı)", "Bağlantı Gerekiyor",
             "Erişilemiyor", "Doğrulanamadı", "Oturum Kapalı", "Durduruldu":
            self = .negative
        case "Aktif", "Erişilebilir", "Çözümleme doğrulandı", "Bağlı", "Hazır":
            self = .positive
        case "Arayüz gözlenmedi; oturum doğrulanmadı", "Arayüz gözlenemedi; oturum doğrulanmadı":
            self = .limited
        default:
            if value.hasPrefix("Arayüz gözlendi ("), value.hasSuffix("); oturum doğrulanmadı") {
                self = .limited
            } else if ["Aktif (Ethernet)", "Aktif (Wi-Fi)", "Aktif (Hücresel)"].contains(value) {
                self = .positive
            } else {
                self = .unknown
            }
        }
    }
}
