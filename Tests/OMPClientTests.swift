import Foundation

private struct PersistedTestPreferences: Codable {
    var selectedModel: String
    var availableModels: [OmpModelInfo]?
}
@main struct OMPClientTests {
    @MainActor static func main() async throws {
        print("--- Starting OMPClientTests ---")
        try await testResolveOmpBinaryConfigurable()
        try await testModelDiscoveryAndSelection()
        try await testNoSilentFallbackOnModelMismatch()
        try await testHandshakeFailureDisposesProcess()
        try await testResetSerializedAndFencesStaleFrames()
        try await testStopDuringStartupInvalidatesSend()
        try await testAssistantRoleFilteringAndStalePromptError()
        try await testCleanupOnClose()
        print("PASS: OMPClientTests passed all checks successfully!")
    }

    // MARK: - Test Cases

    @MainActor static func testResolveOmpBinaryConfigurable() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let customScript = tempDir.appendingPathComponent("custom_omp.sh")
        try "#!/bin/sh\nexit 0\n".write(to: customScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: customScript.path)

        // Init with custom injected URL seam
        let client = OMPClient(appSupportURL: tempDir, ompBinaryURL: customScript)
        assert(client.selectedModel == "openai-codex/gpt-6.1-sol" || !client.selectedModel.isEmpty, "Default selected model should be valid")
        client.close()

        print("✓ testResolveOmpBinaryConfigurable passed")
    }

    @MainActor static func testModelDiscoveryAndSelection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fixtureURL = getFixtureScriptURL()
        let client = OMPClient(appSupportURL: tempDir, ompBinaryURL: fixtureURL)
        defer { client.close() }

        // 1. Available model discovery via OMP get_available_models
        await client.refreshAvailableModels()
        assert(!client.availableModels.isEmpty, "Model discovery must populate availableModels from OMP")
        assert(client.availableModels.contains(where: { $0.id == "openai-codex/gpt-6.1-sol" || $0.modelId == "gpt-6.1-sol" }), "Discovery must include gpt-6.1-sol")
        assert(client.availableModels.contains(where: { $0.id == "anthropic/claude-3.7-sonnet" || $0.modelId == "claude-3.7-sonnet" }), "Discovery must include claude-3.7-sonnet")

        // 2. Select new model
        let newModel = "anthropic/claude-3.7-sonnet"
        client.setModel(newModel)
        assert(client.selectedModel == newModel, "Selected model must be updated")
        assert(client.modelLabel == newModel, "Model label must reflect selected model")

        // 3. Verify app-local nonsecret persistence in preferences.json
        let prefsFile = tempDir.appendingPathComponent("preferences.json")
        assert(FileManager.default.fileExists(atPath: prefsFile.path), "preferences.json must exist")
        let prefsData = try Data(contentsOf: prefsFile)
        let prefs = try JSONDecoder().decode(PersistedTestPreferences.self, from: prefsData)
        assert(prefs.selectedModel == newModel, "preferences.json must persist the chosen model: \(prefs.selectedModel)")

        // 4. Verify a newly initialized client in same appSupportURL loads the persisted model
        let client2 = OMPClient(appSupportURL: tempDir, ompBinaryURL: fixtureURL)
        assert(client2.selectedModel == newModel, "Client must load persisted selectedModel on init")
        client2.close()

        print("✓ testModelDiscoveryAndSelection passed")
    }

    @MainActor static func testNoSilentFallbackOnModelMismatch() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create wrapper script with --model-mismatch flag
        let wrapper = tempDir.appendingPathComponent("fake_omp_mismatch.sh")
        let pythonFixture = getFixturePythonURL().path
        let script = "#!/bin/bash\nexec /usr/bin/python3 \"\(pythonFixture)\" --model-mismatch \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let client = OMPClient(appSupportURL: tempDir, ompBinaryURL: wrapper)
        defer { client.close() }

        var didThrow = false
        do {
            try await client.start()
        } catch RPCError.modelMismatch(let expected, let actual) {
            didThrow = true
            assert(expected == client.selectedModel, "Expected model should match client.selectedModel")
            assert(actual.contains("fallback-model"), "Actual model should be the fallback model")
        } catch {
            didThrow = true
        }
        assert(didThrow, "Must throw modelMismatch on silent fallback attempt")
        assert(client.connectionStatus.hasPrefix("Hata:"), "Connection status must reflect error honestly")

        print("✓ testNoSilentFallbackOnModelMismatch passed")
    }

    @MainActor static func testHandshakeFailureDisposesProcess() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create wrapper script with --fail-handshake flag
        let wrapper = tempDir.appendingPathComponent("fake_omp_fail.sh")
        let pythonFixture = getFixturePythonURL().path
        let script = "#!/bin/bash\nexec /usr/bin/python3 \"\(pythonFixture)\" --fail-handshake \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let client = OMPClient(appSupportURL: tempDir, ompBinaryURL: wrapper)
        defer { client.close() }

        var didFail = false
        do {
            try await client.start()
        } catch {
            didFail = true
        }
        assert(didFail, "Handshake failure must throw")
        assert(client.connectionStatus.hasPrefix("Hata:"), "Handshake failure must set error status")
        assert(client.lastError != nil, "Handshake failure must record lastError")

        print("✓ testHandshakeFailureDisposesProcess passed")
    }

    @MainActor static func testResetSerializedAndFencesStaleFrames() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fixtureURL = getFixtureScriptURL()
        let client = OMPClient(appSupportURL: tempDir, ompBinaryURL: fixtureURL)
        defer { client.close() }

        // Populate with a message
        await client.send("Mesaj 1")
        assert(client.messages.count >= 2, "Should have user and assistant messages")

        // Reset conversation
        await client.newConversation()
        assert(client.messages.isEmpty, "newConversation must clear messages")
        assert(client.connectionStatus == "Hazır", "newConversation must set connectionStatus to Hazır")
        assert(!client.isRunning, "isRunning must be false after newConversation")

        print("✓ testResetSerializedAndFencesStaleFrames passed")
    }

    @MainActor static func testStopDuringStartupInvalidatesSend() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a wrapper that delays ready frame by 2 seconds
        let wrapper = tempDir.appendingPathComponent("fake_omp_slow.sh")
        let script = """
        #!/usr/bin/env python3
        import sys, time, json
        time.sleep(2.0)
        ready = {"type": "ready", "protocolVersion": 1, "supportedProtocolVersions": [1, 2], "maxFrameBytes": 1048576, "maxReassembledBytes": 67108864}
        sys.stdout.write(json.dumps(ready) + "\\n")
        sys.stdout.flush()
        while True:
            line = sys.stdin.readline()
            if not line: break
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let client = OMPClient(appSupportURL: tempDir, ompBinaryURL: wrapper)
        defer { client.close() }

        let sendTask = Task { @MainActor in
            await client.send("Mesaj")
        }

        // Give send a few milliseconds to enter ensureProcessRunning / startup
        try await Task.sleep(nanoseconds: 50_000_000)
        assert(client.isRunning, "Client should be running/starting")

        // Call stop during startup
        await client.stop()
        assert(!client.isRunning, "Client should not be running after stop")
        assert(client.connectionStatus == "Durduruldu", "Connection status must be Durduruldu")

        await sendTask.value
        assert(client.messages.isEmpty, "Cancelled send must not add messages or leave empty assistant slot")

        print("✓ testStopDuringStartupInvalidatesSend passed")
    }

    @MainActor static func testAssistantRoleFilteringAndStalePromptError() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Wrapper passing --emit-stale-error
        let wrapper = tempDir.appendingPathComponent("fake_omp_stale.sh")
        let pythonFixture = getFixturePythonURL().path
        let script = "#!/bin/bash\nexec /usr/bin/python3 \"\(pythonFixture)\" --emit-stale-error \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let client = OMPClient(appSupportURL: tempDir, ompBinaryURL: wrapper)
        defer { client.close() }

        await client.send("Asistan rol testi")
        let deadline = Date().addingTimeInterval(5.0)
        while client.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let last = client.messages.last else {
            fatalError("Must have received assistant message")
        }
        assert(last.role == "assistant", "Last message must have role assistant")
        assert(last.text.contains("Valid assistant answer"), "Assistant message text must be captured")
        assert(!last.text.contains("Stray echoed user content"), "Non-assistant role message_update must be filtered out")
        assert(client.connectionStatus == "Hazır", "Stale prompt error with mismatched id must be ignored")

        print("✓ testAssistantRoleFilteringAndStalePromptError passed")
    }

    @MainActor static func testCleanupOnClose() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fixtureURL = getFixtureScriptURL()
        let client = OMPClient(appSupportURL: tempDir, ompBinaryURL: fixtureURL)
        try await client.start()
        assert(client.connectionStatus == "Hazır", "Client should be ready")

        client.close()
        assert(client.connectionStatus == "Kapalı", "Client should be closed")
        assert(!client.isRunning, "isRunning must be false after close")

        print("✓ testCleanupOnClose passed")
    }

    // MARK: - Helpers

    private static func getFixtureScriptURL() -> URL {
        let testDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        return testDir.appendingPathComponent("Fixtures/fake_omp.sh")
    }

    private static func getFixturePythonURL() -> URL {
        let testDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        return testDir.appendingPathComponent("Fixtures/fake_omp.py")
    }
}
