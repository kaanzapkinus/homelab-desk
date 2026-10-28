import Foundation
import SwiftUI
import AppKit

/// ChatView: Native chat interface connecting to the isolated local OMP RPC session.
/// Directly observes OMPClient via subviews to guarantee real-time streaming updates.
/// Provides native keyboard/paste input, honest status, streaming cancellation,
/// and model transparency without arbitrary tool execution authority.
public struct ChatView: View {
    @ObservedObject var model: AppModel
    
    init(model: AppModel) { self.model = model
         }
    
    public var body: some View {
        // Observe model.chat directly via subview to ensure streaming updates render smoothly
        ChatContentView(
            chat: model.chat,
            remoteMode: model.remoteMode,
            onSend: { text in
                await model.send(text)
            },
            onStop: {
                await model.stop()
            },
            onNewConversation: {
                await model.newConversation()
            }
        )
    }
}

/// Subview observing OMPClient directly
private struct ChatContentView: View {
    @ObservedObject var chat: OMPClient
    let remoteMode: Bool
    let onSend: (String) async -> Void
    let onStop: () async -> Void
    let onNewConversation: () async -> Void
    
    @State private var inputText: String = ""
    @State private var inputErrorMessage: String? = nil
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar
            
            Divider()
            
            // Messages Scroll Area
            messagesScrollView
            
            Divider()
            
            // Input Area
            inputArea
        }
    }
    
    // MARK: - Header Bar
    
    private var headerBar: some View {
        HStack(spacing: 10) {
            // Model Label
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: remoteMode ? 16 : 12))
                    .foregroundStyle(.secondary)
                Text(chat.modelLabel.isEmpty ? "Model seçilmedi" : chat.modelLabel)
                    .font(.system(remoteMode ? .body : .caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, remoteMode ? 10 : 8)
            .padding(.vertical, remoteMode ? 6 : 4)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
            
            // Connection Status
            HStack(spacing: 5) {
                Circle()
                    .fill(connectionStatusColor)
                    .frame(width: remoteMode ? 10 : 7, height: remoteMode ? 10 : 7)
                Text(chat.connectionStatus.isEmpty ? "Hazır" : chat.connectionStatus)
                    .font(.system(remoteMode ? .body : .caption, design: .default))
                    .foregroundStyle(.secondary)
            }
            
            if chat.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 2)
            }
            
            Spacer()
            
            // New Conversation Button
            Button {
                Task {
                    await onNewConversation()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.bubble")
                    Text("Yeni Sohbet")
                }
                .font(.system(remoteMode ? .body : .caption, design: .default, weight: .medium))
                .frame(minHeight: remoteMode ? 44 : 26)
            }
            .buttonStyle(.bordered)
            .controlSize(remoteMode ? .large : .small)
            .disabled(chat.isRunning)
        }
        .padding(.horizontal, remoteMode ? 14 : 10)
        .padding(.vertical, remoteMode ? 10 : 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private var connectionStatusColor: Color {
        if chat.isRunning {
            return .orange
        }
        let status = chat.connectionStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        if status.hasPrefix("Hata:") || status == "Kapalı" || status == "Bağlantı Yok" || status == "Durduruldu" {
            return .red
        }
        if status == "Hazır" || status == "Bağlı" {
            return .green
        }
        if status == "Çalışıyor..." || status == "Başlatılıyor..." {
            return .orange
        }
        return .secondary
    }
    
    // MARK: - Messages Scroll Area
    
    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: remoteMode ? 16 : 12) {
                    if chat.messages.isEmpty {
                        emptyStateView
                    } else {
                        ForEach(chat.messages) { message in
                            ChatMessageBubble(message: message, remoteMode: remoteMode)
                                .id(message.id)
                        }
                    }
                }
                .padding(remoteMode ? 16 : 12)
            }
            .onChange(of: chat.messages.count) { _, _ in
                if let last = chat.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 40)
            
            Image(systemName: "bubble.left.and.exclamationmark.bubble.right.fill")
                .font(.system(size: remoteMode ? 44 : 36))
                .foregroundStyle(.secondary)
            
            Text("Homelab Kurtarma Asistanı")
                .font(.system(remoteMode ? .title2 : .headline, design: .default, weight: .bold))
            
            Text("Mac mini durumunu sorgulayabilir, arızalanan servisler hakkında tanı isteyebilir veya kontrollü kurtarma adımları planlayabilirsiniz.")
                .font(.system(remoteMode ? .body : .subheadline, design: .default))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            
            VStack(alignment: .leading, spacing: 8) {
                promptChip(text: "Servislerin genel sağlık durumunu kontrol et")
                promptChip(text: "Son sistem hatalarını ve tanı kayıtlarını listele")
                promptChip(text: "Tailscale ve ağ bağlantılarını doğrula")
            }
            .padding(.top, 10)
            
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }
    
    @ViewBuilder
    private func promptChip(text: String) -> some View {
        Button {
            inputText = text
            isInputFocused = true
        } label: {
            HStack {
                Image(systemName: "sparkle")
                    .font(.system(size: remoteMode ? 14 : 11))
                    .foregroundStyle(Color.accentColor)
                Text(text)
                    .font(.system(remoteMode ? .body : .caption, design: .default))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, remoteMode ? 10 : 6)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Input Area
    
    private var inputArea: some View {
        VStack(spacing: 8) {
            if let error = inputErrorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.system(remoteMode ? .body : .caption, design: .default))
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
            
            HStack(alignment: .bottom, spacing: 10) {
                // Multi-line TextEditor with full keyboard & paste support
                NativeChatInput(
                    text: $inputText,
                    placeholder: "Asistana mesaj yazın… (Cmd+Return ile gönder)",
                    remoteMode: remoteMode
                )
                .focused($isInputFocused)
                .frame(minHeight: remoteMode ? 56 : 42, maxHeight: 120)
                .onChange(of: inputText) { _, newValue in
                    if inputErrorMessage != nil && newValue.utf8.count <= ChatDraft.maxByteLength {
                        inputErrorMessage = nil
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                
                // Stop Button: Active ONLY when running
                if chat.isRunning {
                    Button {
                        Task {
                            await onStop()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                            Text("Durdur")
                        }
                        .font(.system(remoteMode ? .body : .subheadline, design: .default, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(minHeight: remoteMode ? 44 : 36)
                        .padding(.horizontal, remoteMode ? 14 : 10)
                    }
                    .buttonStyle(.plain)
                    .background(Color.red)
                    .cornerRadius(8)
                    .keyboardShortcut(".", modifiers: [.command])
                }
                
                // Send Button: Disabled when running OR empty text
                Button {
                    submitMessage()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                        Text("Gönder")
                    }
                    .font(.system(remoteMode ? .body : .subheadline, design: .default, weight: .bold))
                    .frame(minHeight: remoteMode ? 44 : 36)
                    .padding(.horizontal, remoteMode ? 14 : 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(remoteMode ? .large : .regular)
                .disabled(chat.isRunning || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(remoteMode ? 14 : 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private func submitMessage() {
        guard !chat.isRunning else { return }
        do {
            let message = try ChatDraft.message(from: inputText)
            inputErrorMessage = nil
            inputText = ""
            Task {
                await onSend(message)
            }
        } catch ChatDraft.ValidationError.tooLarge(let byteCount) {
            inputErrorMessage = "Mesaj boyutu sınırı aşıyor: \(byteCount) bayt (en fazla \(ChatDraft.maxByteLength) UTF-8 bayt)."
        } catch {
            // Empty message; retain text
        }
    }
}

public struct ChatDraft: Sendable {
    public static let maxByteLength = 64_000

    public enum ValidationError: LocalizedError, Equatable {
        case empty
        case tooLarge(byteCount: Int)

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "Mesaj boş olamaz."
            case .tooLarge(let byteCount):
                return "Mesaj boyutu sınırı aşıyor: \(byteCount) bayt (en fazla \(ChatDraft.maxByteLength) UTF-8 bayt)."
            }
        }
    }

    public static func message(from text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ValidationError.empty
        }
        let byteCount = trimmed.utf8.count
        guard byteCount <= maxByteLength else {
            throw ValidationError.tooLarge(byteCount: byteCount)
        }
        return trimmed
    }
}

// MARK: - Native Chat Input View Supporting Keyboard Navigation & Native Paste

private struct NativeChatInput: View {
    @Binding var text: String
    let placeholder: String
    let remoteMode: Bool
    
    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(remoteMode ? .title3 : .body, design: .default))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
            
            TextEditor(text: $text)
                .font(.system(remoteMode ? .title3 : .body, design: .default))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
    }
}

// MARK: - Message Bubble Component

private struct ChatMessageBubble: View {
    let message: ChatMessage
    let remoteMode: Bool
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser {
                Spacer(minLength: remoteMode ? 30 : 50)
            }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                // Header (Role label & timestamp)
                HStack(spacing: 6) {
                    if !isUser {
                        roleIcon
                    }
                    Text(roleTitle)
                        .font(.system(remoteMode ? .footnote : .caption2, design: .default, weight: .bold))
                        .foregroundStyle(isUser ? Color.white.opacity(0.8) : Color.secondary)
                    
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(remoteMode ? .caption2 : .caption2, design: .monospaced))
                        .foregroundStyle(isUser ? Color.white.opacity(0.6) : Color.secondary.opacity(0.8))
                }
                
                // Message Body
                Text(message.text)
                    .font(.system(remoteMode ? .body : (isTool ? .footnote : .body), design: isTool ? .monospaced : .default))
                    .foregroundStyle(isUser ? Color.white : Color.primary)
                    .textSelection(.enabled)
                    .lineSpacing(3)
            }
            .padding(remoteMode ? 14 : 10)
            .background(bubbleBackground)
            .cornerRadius(10)
            
            if !isUser {
                Spacer(minLength: remoteMode ? 30 : 50)
            }
        }
    }
    
    private var isUser: Bool {
        message.role == "user"
    }
    
    private var isTool: Bool {
        message.role == "tool" || message.role == "system"
    }
    
    private var roleTitle: String {
        switch message.role {
        case "user":
            return "Siz"
        case "assistant":
            return "Asistan"
        case "tool":
            return "Tanı Aracı Çıktısı"
        case "system":
            return "Sistem"
        default:
            return message.role.capitalized
        }
    }
    
    @ViewBuilder
    private var roleIcon: some View {
        switch message.role {
        case "assistant":
            Image(systemName: "cpu")
                .font(.system(size: remoteMode ? 14 : 11))
                .foregroundStyle(Color.accentColor)
        case "tool":
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: remoteMode ? 14 : 11))
                .foregroundStyle(Color.orange)
        default:
            Image(systemName: "info.circle")
                .font(.system(size: remoteMode ? 14 : 11))
                .foregroundStyle(Color.secondary)
        }
    }
    
    private var bubbleBackground: some View {
        Group {
            if isUser {
                Color.accentColor
            } else if isTool {
                Color(nsColor: .controlBackgroundColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            } else {
                Color(nsColor: .controlBackgroundColor)
            }
        }
    }
}
