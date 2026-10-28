import Foundation
import Combine

/// Complete native OMP NDJSON RPC client for Homelab Desk.
/// Spawns and manages an isolated local OMP process with built-ins and global MCP disabled,
/// handles protocol-v2 chunk reassembly, supports dynamic model selection and discovery via get_available_models,
/// rejects unauthorized mutations and silent fallbacks, and fences stale frames across conversations.
@MainActor
public final class OMPClient: ObservableObject {
    @Published public var messages: [ChatMessage] = []
    @Published public var isRunning: Bool = false
    @Published public var connectionStatus: String = "Hazır"
    @Published public var modelLabel: String = "openai-codex/gpt-6.1-sol"

    // MARK: - Model Selection, Discovery & Status

    @Published public var selectedModel: String = "openai-codex/gpt-6.1-sol"
    @Published public var availableModels: [OmpModelInfo] = []
    @Published public var isLoadingModels: Bool = false
    @Published public var modelsError: String? = nil
    @Published public var lastError: String? = nil
    @Published public var usageLimitStatus: String? = nil

    /// Native host tool callback. Invoked only for registered readonly and propose tools.
    /// execute_approved_recovery is never routed here.
    public var onHostTool: ((String, [String: Any]) async throws -> [String: Any])?

    // MARK: - Private State

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?

    private let decoder = RPCFrameDecoder()
    private var nextCommandId: Int = 1
    private var protocolVersion: RPCProtocolVersion = .v1

    private var pendingCommands: [String: (continuation: CheckedContinuation<[String: Any], Error>, command: String, timer: Task<Void, Never>?)] = [:]
    private var readyContinuation: CheckedContinuation<[String: Any], Error>?
    private var readyTimer: Task<Void, Never>?
    private var earlyReadyFrame: [String: Any]?

    private var isInitialized: Bool = false
    private var startTask: Task<Void, Error>?
    private var activePromptCommandId: String?

    private var processGeneration: Int = 0
    private var conversationGeneration: Int = 0
    private var currentSendToken: UUID? = nil
    private var pendingHostToolTasks: [String: (task: Task<Void, Never>, processGen: Int, convGen: Int)] = [:]

    private var stderrTail: String = ""
    private let maxStderrTailBytes: Int = 8192

    private let appSupportURL: URL
    private let historyURL: URL
    private let sessionStateURL: URL
    private let preferencesURL: URL
    private let customOmpBinaryURL: URL?

    private var currentSessionFile: String?
    private var currentSessionId: String?

    // MARK: - Session & Preferences Persistence State Models

    private struct PersistedSessionState: Codable {
        let sessionFile: String
        let sessionId: String?
    }

    private struct PersistedClientPreferences: Codable {
        var selectedModel: String
        var availableModels: [OmpModelInfo]?
    }

    // MARK: - Lifecycle

    public init(appSupportURL: URL? = nil, ompBinaryURL: URL? = nil) {
        let support = appSupportURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Homelab Desk", isDirectory: true)
        self.appSupportURL = support
        self.customOmpBinaryURL = ompBinaryURL
        self.historyURL = support.appendingPathComponent("chat_history.json")
        self.sessionStateURL = support.appendingPathComponent("session_state.json")
        self.preferencesURL = support.appendingPathComponent("preferences.json")

        // Load persisted local app preferences, history and session metadata; no process launch on init.
        loadPersistedPreferences()
        loadPersistedHistory()
        loadPersistedSession()
    }

    deinit {
        stdoutTask?.cancel()
        stderrTask?.cancel()
        readyTimer?.cancel()
        for (_, entry) in pendingHostToolTasks {
            entry.task.cancel()
        }
        for (_, entry) in pendingCommands {
            entry.timer?.cancel()
        }
        try? stdinPipe?.fileHandleForWriting.close()
        if process?.isRunning == true { process?.terminate() }
    }

    // MARK: - Public API

    /// Starts the isolated OMP process and performs handshake/negotiation.
    public func start() async throws {
        if let existingStart = startTask {
            try await existingStart.value
            return
        }
        if process?.isRunning == true && isInitialized {
            return
        }

        let task = Task { @MainActor [weak self] () throws in
            guard let self = self else { return }
            defer { self.startTask = nil }
            try await self.launchAndHandshake()
        }
        self.startTask = task
        do {
            try await task.value
        } catch {
            guard !Task.isCancelled else { throw CancellationError() }
            throw error
        }
    }

    /// Selects a new model, persists it to local preferences, and disposes the owned process.
    /// Disabled while inference is actively running.
    public func setModel(_ newModel: String) {
        guard !isRunning else { return }
        let trimmed = newModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed != selectedModel else { return }

        selectedModel = trimmed
        modelLabel = trimmed
        savePersistedPreferences()

        // Disposes the current child so the next conversation or prompt uses the newly chosen model
        close()
    }

    /// Discovers available models via OMP `get_available_models` command.
    public func refreshAvailableModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        modelsError = nil

        do {
            try await ensureProcessRunning()

            let cmdId = "gam_\(nextCommandId)"
            nextCommandId += 1
            let frame: [String: Any] = [
                "id": cmdId,
                "type": "get_available_models"
            ]
            let result = try await sendCommand(frame, timeoutMs: 30_000)
            if let rawModels = result["models"] as? [[String: Any]] {
                let parsed = rawModels.map { OmpModelInfo(from: $0) }
                if !parsed.isEmpty {
                    self.availableModels = parsed
                    savePersistedPreferences()
                }
            }
            isLoadingModels = false
        } catch {
            isLoadingModels = false
            let errText = "Modeller alınamadı: \(error.localizedDescription)"
            modelsError = errText
            lastError = errText
        }
    }

    /// Sends a user prompt into the chat and streams the assistant response.
    public func send(_ text: String) async {
        guard !isRunning else { return }
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.utf8.count <= 64_000 else { return }

        let sendToken = UUID()
        self.currentSendToken = sendToken
        let sendConvGen = self.conversationGeneration

        // Reserve send state before first suspension
        isRunning = true
        connectionStatus = "Başlatılıyor..."
        lastError = nil

        do {
            try await ensureProcessRunning()
        } catch {
            guard self.currentSendToken == sendToken, self.conversationGeneration == sendConvGen else { return }
            isRunning = false
            currentSendToken = nil
            connectionStatus = "Hata: \(error.localizedDescription)"
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: "system", text: "OMP başlatılamadı: \(error.localizedDescription)"))
            return
        }

        guard self.currentSendToken == sendToken,
              self.conversationGeneration == sendConvGen,
              !Task.isCancelled,
              isRunning else {
            return
        }

        let userMessage = ChatMessage(role: "user", text: prompt)
        messages.append(userMessage)
        saveHistory()

        connectionStatus = "Çalışıyor..."

        // Ensure an empty assistant message slot is ready for streaming
        let assistantMessage = ChatMessage(role: "assistant", text: "")
        messages.append(assistantMessage)

        let cmdId = "p_\(nextCommandId)"
        nextCommandId += 1
        activePromptCommandId = cmdId

        let promptFrame: [String: Any] = [
            "id": cmdId,
            "type": "prompt",
            "message": prompt
        ]

        do {
            _ = try await sendCommand(promptFrame, timeoutMs: 30_000)
        } catch {
            guard self.currentSendToken == sendToken, self.conversationGeneration == sendConvGen else { return }
            activePromptCommandId = nil
            currentSendToken = nil
            isRunning = false
            connectionStatus = "Hata: \(error.localizedDescription)"
            lastError = error.localizedDescription
            if let lastIndex = messages.indices.last, messages[lastIndex].role == "assistant", messages[lastIndex].text.isEmpty {
                messages.remove(at: lastIndex)
            }
            messages.append(ChatMessage(role: "system", text: "Mesaj gönderilemedi: \(error.localizedDescription)"))
            saveHistory()
            return
        }

        guard self.currentSendToken == sendToken,
              self.conversationGeneration == sendConvGen,
              !Task.isCancelled,
              isRunning else {
            activePromptCommandId = nil
            currentSendToken = nil
            isRunning = false
            connectionStatus = "Durduruldu"
            return
        }
    }

    /// Stops the in-flight inference run via OMP abort or startup invalidation.
    public func stop() async {
        guard isRunning else { return }
        currentSendToken = nil
        activePromptCommandId = nil

        // If currently in startup phase, cancel startup task and close process
        if let st = startTask {
            st.cancel()
            startTask = nil
            close()
        } else if process?.isRunning == true && isInitialized {
            let abortId = "a_\(nextCommandId)"
            nextCommandId += 1
            let abortFrame: [String: Any] = [
                "id": abortId,
                "type": "abort"
            ]
            _ = try? await sendCommand(abortFrame, timeoutMs: 5_000)
        }

        isRunning = false
        connectionStatus = "Durduruldu"

        // Remove trailing empty assistant slot left by aborted send
        if let lastIndex = messages.indices.last, messages[lastIndex].role == "assistant", messages[lastIndex].text.isEmpty {
            messages.remove(at: lastIndex)
        }
        saveHistory()
    }

    /// Resets conversation state and disposes the owned OMP process to fence stale frames.
    /// Serialized against send; leaves no process running until next user interaction.
    public func newConversation() async {
        // Cancel in-flight send if any
        currentSendToken = nil
        activePromptCommandId = nil
        for (_, entry) in pendingHostToolTasks {
            entry.task.cancel()
        }
        pendingHostToolTasks.removeAll()

        // Terminate existing owned process to fence stale frames across conversation boundary
        close()

        conversationGeneration += 1
        currentSessionFile = nil
        currentSessionId = nil

        if FileManager.default.fileExists(atPath: sessionStateURL.path) {
            do {
                try FileManager.default.removeItem(at: sessionStateURL)
            } catch {
                connectionStatus = "Hata: Oturum sıfırlanamadı (\(error.localizedDescription))"
                lastError = error.localizedDescription
                return
            }
        }

        messages.removeAll()
        saveHistory()
        isRunning = false
        connectionStatus = "Hazır"
        lastError = nil
    }

    /// Cleanly closes stdin and terminates the owned OMP process.
    public func close() {
        processGeneration += 1
        conversationGeneration += 1
        currentSendToken = nil
        isInitialized = false
        activePromptCommandId = nil
        stdoutTask?.cancel()
        stdoutTask = nil
        stderrTask?.cancel()
        stderrTask = nil

        readyTimer?.cancel()
        readyTimer = nil
        earlyReadyFrame = nil

        for (_, entry) in pendingHostToolTasks {
            entry.task.cancel()
        }
        pendingHostToolTasks.removeAll()

        for (_, entry) in pendingCommands {
            entry.timer?.cancel()
            entry.continuation.resume(throwing: RPCError.processNotRunning)
        }
        pendingCommands.removeAll()

        if let readyCont = readyContinuation {
            readyContinuation = nil
            readyCont.resume(throwing: RPCError.processNotRunning)
        }

        if let stdin = stdinPipe {
            try? stdin.fileHandleForWriting.close()
            stdinPipe = nil
        }

        if let proc = process {
            if proc.isRunning {
                proc.terminate()
            }
            process = nil
        }

        stdoutPipe = nil
        stderrPipe = nil
        decoder.reset()

        isRunning = false
        connectionStatus = "Kapalı"
    }

    // MARK: - Process Launch & Handshake

    private func ensureProcessRunning() async throws {
        if let existingStart = startTask {
            try await existingStart.value
            return
        }
        if process?.isRunning == true && isInitialized {
            return
        }
        try await start()
    }

    private func launchAndHandshake() async throws {
        do {
            try await performLaunchAndHandshake()
        } catch {
            close()
            connectionStatus = "Hata: \(error.localizedDescription)"
            lastError = error.localizedDescription
            throw error
        }
    }

    private func performLaunchAndHandshake() async throws {
        connectionStatus = "Başlatılıyor..."
        isInitialized = false
        lastError = nil

        do {
            try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw RPCError.commandFailed(command: "mkdir", message: "Uygulama oturum dizini oluşturulamadı: \(error.localizedDescription)", code: nil)
        }

        let runtimeConfigURL = appSupportURL.appendingPathComponent("runtime.yml")
        let runtimeConfigContent = """
        disabledProviders:
          - native
          - mcp-json
          - claude
          - claude-plugins
          - codex
          - gemini
          - opencode
          - cursor
          - windsurf
          - cline
          - github
          - vscode
          - agent-plugins
          - omp-plugins
        mcp:
          enableProjectConfig: false
          notifications: false
        retry:
          modelFallback: false
          usageAwareFallback: false
          fallbackChains:
            default: []
        """
        do {
            try Data(runtimeConfigContent.utf8).write(to: runtimeConfigURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtimeConfigURL.path)
        } catch {
            throw RPCError.commandFailed(command: "write_config", message: "Çalışma yapılandırması yazılamadı: \(error.localizedDescription)", code: nil)
        }

        let binaryPath = resolveOmpBinary()
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw RPCError.binaryNotFound(binaryPath)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.currentDirectoryURL = appSupportURL

        var args = [
            "--mode", "rpc-ui",
            "--model", selectedModel,
            "--config", runtimeConfigURL.path,
            "--no-tools",
            "--no-extensions",
            "--no-skills",
            "--no-rules",
            "--no-context-files",
            "--no-lsp",
            "--no-title",
            "--cwd", appSupportURL.path
        ]

        if let sessionFile = currentSessionFile,
           !sessionFile.isEmpty,
           FileManager.default.fileExists(atPath: sessionFile),
           !messages.isEmpty {
            args.append(contentsOf: ["--resume", sessionFile])
        }

        proc.arguments = args

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "OMP_PROFILE")
        env.removeValue(forKey: "PI_PROFILE")
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.process = proc
        self.stderrTail = ""

        processGeneration += 1
        let launchGen = processGeneration

        proc.terminationHandler = { [weak self] p in
            let exitCode = p.terminationStatus
            Task { @MainActor in
                self?.handleProcessTermination(exitCode: exitCode, generation: launchGen, process: p)
            }
        }

        earlyReadyFrame = nil
        startReaderTasks(stdout: stdout, stderr: stderr, processGeneration: launchGen)

        do {
            try proc.run()
        } catch {
            throw RPCError.commandFailed(command: "spawn", message: "OMP süreci başlatılamadı: \(error.localizedDescription)", code: nil)
        }

        // Wait for ready frame with explicit timeout waiter (no taskgroup hang)
        connectionStatus = "Hazır bekleniyor..."
        let readyFrame: [String: Any]
        if let early = self.earlyReadyFrame {
            self.earlyReadyFrame = nil
            readyFrame = early
        } else {
            readyFrame = try await withCheckedThrowingContinuation { [weak self] cont in
                guard let self = self else {
                    cont.resume(throwing: RPCError.processNotRunning)
                    return
                }
                self.readyContinuation = cont
                self.readyTimer = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: 45_000_000_000)
                        self?.handleReadyTimeout()
                    } catch {}
                }
            }
        }

        // Protocol negotiation: Spec prefers negotiate2
        let supportedVersions = (readyFrame["supportedProtocolVersions"] as? [Int]) ?? []
        if supportedVersions.contains(2) {
            connectionStatus = "Protokol anlaşması (v2)..."
            let negId = "neg_\(nextCommandId)"
            nextCommandId += 1
            let negFrame: [String: Any] = [
                "id": negId,
                "type": "negotiate_protocol",
                "protocolVersion": 2
            ]
            let negResult = try await sendCommand(negFrame, timeoutMs: 15_000)
            if (negResult["protocolVersion"] as? Int) == 2 {
                self.protocolVersion = .v2
            }
        }

        // Host tools registration: Register readonly and propose tools only
        connectionStatus = "Host araçları kaydediliyor..."
        let toolsId = "tools_\(nextCommandId)"
        nextCommandId += 1
        let toolsFrame: [String: Any] = [
            "id": toolsId,
            "type": "set_host_tools",
            "tools": RPCHostToolRegistry.definitions()
        ]
        _ = try await sendCommand(toolsFrame, timeoutMs: 15_000)

        // Query actual model and session identity via get_state
        connectionStatus = "Model durumu alınıyor..."
        let stateId = "st_\(nextCommandId)"
        nextCommandId += 1
        let stateFrame: [String: Any] = [
            "id": stateId,
            "type": "get_state"
        ]
        let stateResult = try await sendCommand(stateFrame, timeoutMs: 15_000)
        var actualModel = ""
        if let modelObj = stateResult["model"] as? [String: Any],
           let id = modelObj["id"] as? String {
            let provider = modelObj["provider"] as? String ?? ""
            actualModel = provider.isEmpty ? id : "\(provider)/\(id)"
            self.modelLabel = actualModel
        }
        if let usageObj = stateResult["usageLimit"] as? [String: Any] {
            if let tier = usageObj["tier"] as? String {
                self.usageLimitStatus = "Kota/Tier: \(tier)"
            }
        }

        // Strict verification: No silent fallback!
        let targetModel = self.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !actualModel.isEmpty && !targetModel.isEmpty {
            let matches = (actualModel == targetModel) ||
                          actualModel.hasSuffix("/\(targetModel)") ||
                          targetModel.hasSuffix("/\(actualModel)")
            guard matches else {
                throw RPCError.modelMismatch(expected: targetModel, actual: actualModel)
            }
        }

        if let sFile = stateResult["sessionFile"] as? String, !sFile.isEmpty {
            self.currentSessionFile = sFile
            saveSessionState()
        }
        if let sId = stateResult["sessionId"] as? String, !sId.isEmpty {
            self.currentSessionId = sId
        }

        self.isInitialized = true
        connectionStatus = "Hazır"
    }

    private func handleReadyTimeout() {
        readyTimer?.cancel()
        readyTimer = nil
        if let cont = readyContinuation {
            readyContinuation = nil
            cont.resume(throwing: RPCError.commandFailed(command: "ready", message: "OMP hazır sinyali zaman aşımına uğradı", code: nil))
        }
    }

    private func resolveOmpBinary() -> String {
        if let custom = customOmpBinaryURL {
            return custom.path
        }
        if let envBin = ProcessInfo.processInfo.environment["OMP_BIN"],
           !envBin.isEmpty,
           FileManager.default.isExecutableFile(atPath: envBin) {
            return envBin
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let homeCandidates = [
            "\(home)/.local/bin/omp"
        ]
        for candidate in homeCandidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        if let pathVar = ProcessInfo.processInfo.environment["PATH"] {
            let paths = pathVar.split(separator: ":").map(String.init)
            for dir in paths {
                let candidate = (dir as NSString).appendingPathComponent("omp")
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        let standardCandidates = [
            "/opt/homebrew/bin/omp",
            "/usr/local/bin/omp",
            "/usr/bin/omp",
            "/bin/omp"
        ]
        for candidate in standardCandidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return "\(home)/.local/bin/omp"
    }

    // MARK: - Process I/O & NDJSON Framing

    private func startReaderTasks(stdout: Pipe, stderr: Pipe, processGeneration: Int) {
        let stdoutHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading

        stdoutTask = Task.detached { [weak self] in
            var buffer = Data()
            while !Task.isCancelled {
                let chunk = stdoutHandle.availableData
                if chunk.isEmpty {
                    await self?.handleEOF(generation: processGeneration)
                    break
                }
                buffer.append(chunk)

                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: 0..<newlineIndex)
                    buffer.removeSubrange(0...newlineIndex)
                    if !lineData.isEmpty {
                        await self?.processStdoutLine(lineData, generation: processGeneration)
                    }
                }

                if buffer.count > RPCConstants.maxRPCFrameBytes * 2 {
                    buffer.removeAll()
                }
            }
        }

        stderrTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let chunk = stderrHandle.availableData
                if chunk.isEmpty { break }
                await self?.appendStderr(chunk, generation: processGeneration)
            }
        }
    }

    private func processStdoutLine(_ lineData: Data, generation: Int) {
        guard generation == self.processGeneration else { return }
        guard let rawObject = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return
        }

        do {
            guard let frame = try decoder.push(record: rawObject) else {
                return // Awaiting more protocol-v2 chunks
            }
            handleFrame(frame, generation: generation)
        } catch {
            guard generation == self.processGeneration else { return }
            stderrTail.append("\nRPC framing error: \(error.localizedDescription)")
            close()
        }
    }

    private func appendStderr(_ data: Data, generation: Int) {
        guard generation == self.processGeneration else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        stderrTail.append(text)
        if stderrTail.count > maxStderrTailBytes {
            stderrTail = String(stderrTail.suffix(maxStderrTailBytes))
        }
    }

    private func handleEOF(generation: Int) {
        guard generation == self.processGeneration else { return }
        if process?.isRunning == false || isRunning {
            isRunning = false
            connectionStatus = "Bağlantı kesildi"
            saveHistory()
        }
    }

    private func handleProcessTermination(exitCode: Int32, generation: Int, process: Process) {
        guard generation == processGeneration, self.process === process else {
            return
        }

        let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        isInitialized = false
        isRunning = false
        activePromptCommandId = nil
        connectionStatus = exitCode == 0 ? "Bağlantı kapandı" : "Hata (\(exitCode))"

        readyTimer?.cancel()
        readyTimer = nil
        if let readyCont = readyContinuation {
            readyContinuation = nil
            readyCont.resume(throwing: RPCError.processExited(code: exitCode, stderr: tail))
        }

        for (_, entry) in pendingHostToolTasks {
            entry.task.cancel()
        }
        pendingHostToolTasks.removeAll()

        for (_, entry) in pendingCommands {
            entry.timer?.cancel()
            entry.continuation.resume(throwing: RPCError.processExited(code: exitCode, stderr: tail))
        }
        pendingCommands.removeAll()

        stdoutTask?.cancel()
        stdoutTask = nil
        stderrTask?.cancel()
        stderrTask = nil

        self.process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        decoder.reset()

        saveHistory()
    }

    // MARK: - Frame Dispatcher

    private func handleFrame(_ frame: [String: Any], generation: Int) {
        guard generation == self.processGeneration else { return }
        guard let type = frame["type"] as? String else { return }

        switch type {
        case "ready":
            readyTimer?.cancel()
            readyTimer = nil
            if let cont = readyContinuation {
                readyContinuation = nil
                cont.resume(returning: frame)
            } else {
                earlyReadyFrame = frame
            }

        case "response":
            let id = frame["id"] as? String
            let success = (frame["success"] as? Bool) ?? false

            if let id = id, let entry = pendingCommands.removeValue(forKey: id) {
                entry.timer?.cancel()
                if success {
                    let data = (frame["data"] as? [String: Any]) ?? [:]
                    entry.continuation.resume(returning: data)
                } else {
                    let errorMsg = (frame["error"] as? String) ?? "RPC komutu başarısız"
                    let code = frame["code"] as? String
                    if entry.command == "prompt" && id == activePromptCommandId {
                        handlePromptFailure(errorMsg)
                    }
                    entry.continuation.resume(throwing: RPCError.commandFailed(command: entry.command, message: errorMsg, code: code))
                }
                return
            }

            // Unsolicited failed responses surface async prompt failures only if correlated with active prompt
            if !success {
                if let id = id, let activeId = activePromptCommandId, id == activeId {
                    let errorMsg = (frame["error"] as? String) ?? "İstem hatası"
                    handlePromptFailure(errorMsg)
                    return
                }
            }

        case "agent_start", "turn_start":
            if isRunning {
                connectionStatus = "Çalışıyor..."
                ensureStreamingAssistantMessage()
            }

        case "message_start":
            if isRunning {
                ensureStreamingAssistantMessage()
            }

        case "message_update":
            if isRunning {
                handleMessageUpdate(frame)
            }

        case "message_end":
            if isRunning {
                handleMessageEnd(frame)
            }

        case "tool_execution_start":
            let toolName = (frame["toolName"] as? String) ?? "araç"
            connectionStatus = "Araç çalışıyor: \(toolName)"

        case "tool_execution_update":
            let toolName = (frame["toolName"] as? String) ?? ""
            if !toolName.isEmpty {
                connectionStatus = "Araç çalışıyor: \(toolName)"
            }

        case "tool_execution_end":
            if isRunning {
                connectionStatus = "Çalışıyor..."
            }

        case "host_tool_call":
            handleHostToolCall(frame, generation: generation)

        case "host_tool_cancel":
            let targetId = (frame["targetId"] as? String) ?? (frame["id"] as? String) ?? ""
            if let entry = pendingHostToolTasks.removeValue(forKey: targetId) {
                entry.task.cancel()
            }
            if isRunning {
                connectionStatus = "Çalışıyor..."
            }

        case "host_uri_request":
            if let id = frame["id"] as? String {
                sendFrame([
                    "type": "host_uri_result",
                    "id": id,
                    "isError": true,
                    "error": "URI şemaları bu istemcide desteklenmemektedir."
                ])
            }

        case "prompt_error":
            let frameId = frame["id"] as? String
            if let frameId = frameId, let activeId = activePromptCommandId, frameId != activeId {
                // Stale error from prior turn; drop it
                return
            }
            let errorMsg = (frame["error"] as? String)
                ?? (frame["errorMessage"] as? String)
                ?? (frame["message"] as? String)
                ?? "İstem hatası"
            handlePromptFailure(errorMsg)

        case "prompt_result":
            let frameId = frame["id"] as? String
            if let frameId = frameId, let activeId = activePromptCommandId, frameId != activeId {
                // Stale prompt_result; drop it
                return
            }
            activePromptCommandId = nil
            isRunning = false
            connectionStatus = "Hazır"
            saveHistory()

        case "agent_end":
            let isTerminal = (frame["isTerminal"] as? Bool) ?? true
            if isTerminal {
                activePromptCommandId = nil
                isRunning = false
                connectionStatus = "Hazır"
                saveHistory()
            }

        default:
            break
        }
    }

    private func handlePromptFailure(_ errorMsg: String) {
        activePromptCommandId = nil
        isRunning = false
        connectionStatus = "Hata: \(errorMsg)"
        lastError = errorMsg

        if let lastIndex = messages.indices.last, messages[lastIndex].role == "assistant", messages[lastIndex].text.isEmpty {
            messages.remove(at: lastIndex)
        }
        messages.append(ChatMessage(role: "system", text: "Model hatası: \(errorMsg)"))
        saveHistory()
    }

    // MARK: - Streaming Text Updates & Role Filtering

    private func ensureStreamingAssistantMessage() {
        if let last = messages.last, last.role == "assistant" {
            return
        }
        messages.append(ChatMessage(role: "assistant", text: ""))
    }

    private func handleMessageUpdate(_ frame: [String: Any]) {
        if let messageObj = frame["message"] as? [String: Any] {
            // Role filtering: strictly accept only assistant messages
            guard let role = messageObj["role"] as? String, role == "assistant" else {
                return
            }
            let extractedText = extractMessageText(messageObj)
            if !extractedText.isEmpty {
                updateCurrentAssistantMessage(with: extractedText)
            }
            return
        }

        if let eventObj = frame["assistantMessageEvent"] as? [String: Any],
           (eventObj["type"] as? String) == "text_delta",
           let delta = eventObj["delta"] as? String {
            appendAssistantDelta(delta)
        }
    }

    private func handleMessageEnd(_ frame: [String: Any]) {
        if let messageObj = frame["message"] as? [String: Any] {
            // Role filtering: strictly accept only assistant messages
            guard let role = messageObj["role"] as? String, role == "assistant" else {
                return
            }
            let finalText = extractMessageText(messageObj)
            if !finalText.isEmpty {
                updateCurrentAssistantMessage(with: finalText)
            }
        }
        saveHistory()
    }

    private func updateCurrentAssistantMessage(with text: String) {
        if let lastIndex = messages.indices.last, messages[lastIndex].role == "assistant" {
            messages[lastIndex].text = text
        } else {
            messages.append(ChatMessage(role: "assistant", text: text))
        }
    }

    private func appendAssistantDelta(_ delta: String) {
        if let lastIndex = messages.indices.last, messages[lastIndex].role == "assistant" {
            messages[lastIndex].text.append(delta)
        } else {
            messages.append(ChatMessage(role: "assistant", text: delta))
        }
    }

    private func extractMessageText(_ message: [String: Any]) -> String {
        if let text = message["content"] as? String {
            return text
        }
        if let text = message["text"] as? String {
            return text
        }
        if let blocks = message["content"] as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                guard let blockType = block["type"] as? String else { return nil }
                if blockType == "text", let text = block["text"] as? String {
                    return text
                }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }

    // MARK: - Host Tool Safety & Execution

    private func handleHostToolCall(_ frame: [String: Any], generation: Int) {
        guard generation == self.processGeneration else { return }
        let callId = (frame["id"] as? String) ?? ""
        let toolName = (frame["toolName"] as? String) ?? ""
        let args = (frame["arguments"] as? [String: Any]) ?? [:]

        // Strict safety boundary: onHostTool receives only registered readonly/propose names
        guard RPCHostToolRegistry.isAllowed(toolName) else {
            let errorText = "Yetkisiz veya engellenmiş araç: '\(toolName)'. execute_approved_recovery model aracı olarak çağrılamaz; yalnızca yerel kullanıcı onayıyla çalıştırılır."
            sendFrame(RPCHostToolRegistry.makeResult(id: callId, contentText: errorText, isError: true))
            return
        }

        connectionStatus = "Host aracı yürütülüyor: \(toolName)..."

        let procGen = generation
        let convGen = self.conversationGeneration
        let task = Task { @MainActor [weak self] in
            guard let self = self else { return }

            guard !Task.isCancelled,
                  self.processGeneration == procGen,
                  self.conversationGeneration == convGen,
                  self.pendingHostToolTasks[callId] != nil else {
                return
            }

            do {
                guard let callback = self.onHostTool else {
                    throw RPCError.toolForbidden("Host araç işleyicisi (onHostTool) kayıtlı değil.")
                }

                let outcome = try await callback(toolName, args)

                guard !Task.isCancelled,
                  self.processGeneration == procGen,
                  self.conversationGeneration == convGen,
                  self.pendingHostToolTasks[callId] != nil else {
                    return
                }
                self.pendingHostToolTasks.removeValue(forKey: callId)

                let outcomeData = try JSONSerialization.data(withJSONObject: outcome, options: [.sortedKeys])
                let outcomeText = String(data: outcomeData, encoding: .utf8) ?? "{}"
                self.sendFrame(RPCHostToolRegistry.makeResult(id: callId, contentText: outcomeText, isError: false))
                if self.isRunning {
                    self.connectionStatus = "Çalışıyor..."
                }
            } catch {
                guard !Task.isCancelled,
                  self.processGeneration == procGen,
                  self.conversationGeneration == convGen,
                  self.pendingHostToolTasks[callId] != nil else {
                    return
                }
                self.pendingHostToolTasks.removeValue(forKey: callId)

                let errorText = "Araç yürütme hatası: \(error.localizedDescription)"
                self.sendFrame(RPCHostToolRegistry.makeResult(id: callId, contentText: errorText, isError: true))
                if self.isRunning {
                    self.connectionStatus = "Çalışıyor..."
                }
            }
        }
        self.pendingHostToolTasks[callId] = (task: task, processGen: procGen, convGen: convGen)
    }

    // MARK: - Frame Transmission

    private func sendCommand(_ command: [String: Any], timeoutMs: Int = 0) async throws -> [String: Any] {
        guard let proc = process, proc.isRunning, let stdin = stdinPipe else {
            throw RPCError.processNotRunning
        }

        let cmdType = (command["type"] as? String) ?? "unknown"
        let id = (command["id"] as? String) ?? "c_\(nextCommandId)"

        let encodedData = try RPCCommandEncoder.encode(command)

        return try await withCheckedThrowingContinuation { [weak self] continuation in
            guard let self = self else {
                continuation.resume(throwing: RPCError.processNotRunning)
                return
            }

            var timerTask: Task<Void, Never>? = nil
            if timeoutMs > 0 {
                timerTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                        self?.handleCommandTimeout(id: id, commandType: cmdType)
                    } catch {}
                }
            }

            self.pendingCommands[id] = (continuation: continuation, command: cmdType, timer: timerTask)

            do {
                try stdin.fileHandleForWriting.write(contentsOf: encodedData)
            } catch {
                timerTask?.cancel()
                self.pendingCommands.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendFrame(_ frame: [String: Any]) {
        guard let proc = process, proc.isRunning, let stdin = stdinPipe else { return }
        do {
            let data = try RPCCommandEncoder.encode(frame)
            try stdin.fileHandleForWriting.write(contentsOf: data)
        } catch {
            // Non-critical frame write failure
        }
    }

    private func handleCommandTimeout(id: String, commandType: String) {
        guard let entry = pendingCommands.removeValue(forKey: id) else { return }
        entry.timer?.cancel()
        entry.continuation.resume(throwing: RPCError.commandTimeout(commandType))
    }

    // MARK: - Preferences & State Persistence

    private func loadPersistedPreferences() {
        guard FileManager.default.fileExists(atPath: preferencesURL.path) else {
            self.modelLabel = self.selectedModel.isEmpty ? "Model seçilmedi" : self.selectedModel
            return
        }
        do {
            let data = try Data(contentsOf: preferencesURL)
            let prefs = try JSONDecoder().decode(PersistedClientPreferences.self, from: data)
            let trimmed = prefs.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                self.selectedModel = trimmed
                self.modelLabel = trimmed
            } else {
                self.modelLabel = "Model seçilmedi"
            }
            if let cached = prefs.availableModels, !cached.isEmpty {
                self.availableModels = cached
            }
        } catch {
            self.modelLabel = self.selectedModel.isEmpty ? "Model seçilmedi" : self.selectedModel
        }
    }

    private func savePersistedPreferences() {
        do {
            try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let prefs = PersistedClientPreferences(selectedModel: selectedModel, availableModels: availableModels)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(prefs)
            try data.write(to: preferencesURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preferencesURL.path)
        } catch {
            lastError = "Ayarlar kaydedilemedi: \(error.localizedDescription)"
        }
    }

    private func loadPersistedSession() {
        guard FileManager.default.fileExists(atPath: sessionStateURL.path) else { return }
        do {
            let data = try Data(contentsOf: sessionStateURL)
            let decoded = try JSONDecoder().decode(PersistedSessionState.self, from: data)
            if !decoded.sessionFile.isEmpty && FileManager.default.fileExists(atPath: decoded.sessionFile) {
                self.currentSessionFile = decoded.sessionFile
                self.currentSessionId = decoded.sessionId
            }
        } catch {
            self.currentSessionFile = nil
            self.currentSessionId = nil
        }
    }

    private func saveSessionState() {
        guard let sFile = currentSessionFile, !sFile.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let state = PersistedSessionState(sessionFile: sFile, sessionId: currentSessionId)
            let data = try JSONEncoder().encode(state)
            try data.write(to: sessionStateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionStateURL.path)
        } catch {
            lastError = "Oturum durumu kaydedilemedi: \(error.localizedDescription)"
        }
    }

    private func loadPersistedHistory() {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return }
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: historyURL.path)
            let fileSize = (attrs[.size] as? Int) ?? 0
            guard fileSize <= RPCConstants.maxHistoryFileSize else { return }

            let data = try Data(contentsOf: historyURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let loaded = try decoder.decode([ChatMessage].self, from: data)
            self.messages = Array(loaded.suffix(RPCConstants.maxHistoryMessages))
        } catch {
            self.messages = []
        }
    }

    private func saveHistory() {
        clampMessages()
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601

            var retained = messages
            var data = try encoder.encode(retained)

            while data.count > RPCConstants.maxHistoryFileSize && retained.count > 1 {
                retained.removeFirst()
                data = try encoder.encode(retained)
            }

            if data.count > RPCConstants.maxHistoryFileSize && !retained.isEmpty {
                var single = retained[0]
                let excess = data.count - RPCConstants.maxHistoryFileSize + 1024
                if single.text.count > excess {
                    single.text = String(single.text.prefix(single.text.count - excess))
                }
                retained = [single]
                data = try encoder.encode(retained)
            }

            if data.count <= RPCConstants.maxHistoryFileSize {
                self.messages = retained
                try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try data.write(to: historyURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
            }
        } catch {
            // Non-fatal persistence error
        }
    }

    private func clampMessages() {
        if messages.count > RPCConstants.maxHistoryMessages {
            messages = Array(messages.suffix(RPCConstants.maxHistoryMessages))
        }
    }
}
