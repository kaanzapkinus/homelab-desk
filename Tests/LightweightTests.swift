import Foundation

@main struct LightweightTests {
    @MainActor static func main() async throws {
        testObservationHealth()
        try testDraftByteLimit()
        testIndependentWindowDemand()
        await testManualRefreshWithoutDemand()
        let resolver = BoundedDNSResolver()
        let res1 = await resolver.resolve(hostname: "localhost", timeoutSeconds: 1)
        precondition(res1)
        let res2 = await resolver.resolve(hostname: "not a valid hostname", timeoutSeconds: 1)
        precondition(!res2)
        print("PASS: LightweightTests passed all checks")
    }

    static func testObservationHealth() {
        precondition(ObservationHealth(status: "Bağlantı Yok") == .negative)
        precondition(ObservationHealth(status: "Bağlantı Yok (Sınırlı)") == .negative)
        precondition(ObservationHealth(status: "Doğrulanamadı") == .negative)
        precondition(ObservationHealth(status: "Erişilebilir") == .positive)
        precondition(ObservationHealth(status: "Aktif (Wi-Fi)") == .positive)
        precondition(ObservationHealth(status: "Arayüz gözlendi (100.64.0.1); oturum doğrulanmadı") == .limited)
        precondition(ObservationHealth(status: "unknown ok service text") == .unknown)
        precondition(ObservationHealth(status: "inactive") == .unknown)
    }

    static func testDraftByteLimit() throws {
        let validDraft = try ChatDraft.message(from: String(repeating: "a", count: 64_000))
        precondition(validDraft.utf8.count == 64_000)
        let oversized = String(repeating: "ş", count: 32_001)
        do {
            _ = try ChatDraft.message(from: oversized)
            preconditionFailure("UTF-8 bytes, not characters, must enforce the limit")
        } catch ChatDraft.ValidationError.tooLarge {
            precondition(oversized.utf8.count == 64_002)
        }
        let trimmedDraft = try ChatDraft.message(from: "  hello \n")
        precondition(trimmedDraft == "hello")
    }

    @MainActor static func testIndependentWindowDemand() {
        let monitor = DeviceMonitor()
        monitor.start()
        precondition(!monitor.isRunning)
        precondition(!monitor.hasVisibleDemand)
        monitor.setDemand(true, for: .mainWindow)
        precondition(monitor.isRunning)
        precondition(monitor.hasVisibleDemand)
        monitor.setDemand(true, for: .metricsPanel)
        monitor.setDemand(false, for: .mainWindow)
        precondition(monitor.isRunning, "Closing main must not stop the visible metrics panel")
        monitor.setDemand(false, for: .metricsPanel)
        precondition(!monitor.isRunning)
        precondition(!monitor.hasVisibleDemand)
        monitor.setDemand(true, for: .mainWindow)
        precondition(monitor.isRunning, "Showing a panel must resume sampling")
        precondition(monitor.hasVisibleDemand)
        monitor.stop()
        precondition(!monitor.isRunning)
    }

    @MainActor static func testManualRefreshWithoutDemand() async {
        let monitor = DeviceMonitor(
            fastSample: {
                var snapshot = DeviceSnapshot()
                snapshot.cpuPercent = 25
                snapshot.memoryUsedBytes = 1024
                return snapshot
            },
            slowSample: {
                var snapshot = DeviceSnapshot()
                snapshot.diskFreeBytes = 4096
                snapshot.dnsStatus = "Çözümleme doğrulandı"
                return snapshot
            }
        )
        await monitor.refresh()
        precondition(!monitor.isRunning)
        precondition(monitor.snapshot.cpuPercent == 25)
        precondition(monitor.snapshot.memoryUsedBytes == 1024)
        precondition(monitor.snapshot.diskFreeBytes == 4096)
        precondition(monitor.snapshot.dnsStatus == "Çözümleme doğrulandı")
        precondition(monitor.history.count == 1)
    }
}
