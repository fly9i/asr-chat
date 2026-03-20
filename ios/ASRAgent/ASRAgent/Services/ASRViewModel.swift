import Foundation
import SwiftUI
import os

private let vmLog = Logger(subsystem: "com.asragent.app", category: "ViewModel")

/// 核心 ViewModel，串联录音、WebSocket、Chat、UI 状态
@MainActor
class ASRViewModel: ObservableObject {

    enum AppState {
        case idle           // 初始状态 / 录音结束
        case recording      // 录音中
    }

    @Published var appState: AppState = .idle
    @Published var sentences: [RecognizedSentence] = []
    @Published var isCommandMode = false
    @Published var currentCommand: CommandRecord?
    @Published var history: [HistoryItem] = []

    // Chat 相关
    @Published var chatSessionId: String?
    @Published var chatEvents: [ChatDisplayItem] = []
    @Published var isChatBusy = false
    @Published var pendingConfirm: ChatEvent?

    // 指令模式下收集的文本
    private var commandSentenceStartId = 0

    let recorder = AudioRecorder()
    let wsManager = WebSocketManager()
    let chatService = ChatService.shared

    init() {
        setupBindings()
        chatService.connectSSE()
    }

    private func setupBindings() {
        // 录音数据 → WebSocket
        recorder.onAudioData = { [weak self] data in
            self?.wsManager.sendAudio(data)
        }

        // WebSocket 消息 → UI 更新
        wsManager.onMessage = { [weak self] msg in
            vmLog.info("[消息] type=\(msg.type) text=\(msg.text.prefix(50)) sentenceId=\(msg.sentenceId)")
            self?.handleASRMessage(msg)
        }

        // SSE 事件 → Chat UI 更新
        chatService.onEvent = { [weak self] event in
            self?.handleChatEvent(event)
        }
    }

    // MARK: - 录音控制

    func startRecording(resume: Bool = false) {
        vmLog.info("开始录音流程, resume=\(resume)")
        if !resume {
            sentences = []
            currentCommand = nil
            isCommandMode = false
            chatEvents = []
        }
        wsManager.connect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            vmLog.info("WebSocket isConnected=\(self.wsManager.isConnected), 开始录音")
            self.recorder.startRecording()
            self.appState = .recording
        }
    }

    func stopRecording() {
        vmLog.info("停止录音, sentences=\(self.sentences.count)")
        recorder.stopRecording()
        if isCommandMode {
            endCommand()
        }
        wsManager.sendAction(ClientAction(action: "stop"))
        wsManager.disconnect()
        appState = .idle
    }

    /// 结束本次任务，保存历史并重置状态
    func finishSession() {
        vmLog.info("结束任务, sentences=\(self.sentences.count)")
        saveToHistory()
        sentences = []
        currentCommand = nil
        isCommandMode = false
        chatSessionId = nil
        chatEvents = []
        isChatBusy = false
        pendingConfirm = nil
    }

    // MARK: - 指令模式

    func startCommand() {
        isCommandMode = true
        commandSentenceStartId = (sentences.last?.id ?? 0) + 1
        currentCommand = CommandRecord(commandText: "")
        vmLog.info("进入指令模式, startId=\(self.commandSentenceStartId)")
    }

    func endCommand() {
        guard isCommandMode else { return }
        isCommandMode = false

        // 收集指令期间的所有文本
        let commandText = sentences
            .filter { $0.id >= commandSentenceStartId }
            .map { $0.text }
            .joined()

        vmLog.info("开始执行指令, commandText=\(commandText.prefix(100))")

        guard !commandText.isEmpty else {
            vmLog.warning("指令文本为空，跳过")
            return
        }

        currentCommand?.commandText = commandText

        // 构建完整录音内容
        let allText = sentences.map { $0.text }.joined()

        let message = """
        ## 录音内容
        \(allText)

        ## 用户指令
        \(commandText)
        """

        // 发送到 Chat API
        Task {
            await sendToChat(message: message)
        }
    }

    // MARK: - Chat 集成

    private func sendToChat(message: String) async {
        do {
            // 复用或创建会话
            if chatSessionId == nil {
                let session = try await chatService.createSession(title: "ASR 语音会话")
                chatSessionId = session.id
                vmLog.info("创建 Chat 会话: \(session.id)")
            }

            guard let sessionId = chatSessionId else { return }

            isChatBusy = true
            chatEvents = []
            let step = CommandStep(status: "thinking", content: "正在发送指令...")
            currentCommand?.steps.append(step)

            try await chatService.sendMessage(sessionId: sessionId, message: message)
            vmLog.info("消息已发送到会话 \(sessionId)")
        } catch {
            vmLog.error("发送 Chat 消息失败: \(error.localizedDescription)")
            let step = CommandStep(status: "result", content: "发送失败: \(error.localizedDescription)")
            currentCommand?.steps.append(step)
            currentCommand?.isComplete = true
            isChatBusy = false
        }
    }

    /// 权限确认响应
    func respondToConfirm(response: String) {
        guard let confirm = pendingConfirm,
              let sessionId = chatSessionId,
              let confirmId = confirm.confirmId else { return }
        pendingConfirm = nil
        Task {
            do {
                try await chatService.confirmPermission(
                    sessionId: sessionId, confirmId: confirmId, response: response)
            } catch {
                vmLog.error("权限确认失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Chat 事件处理

    private func handleChatEvent(_ event: ChatEvent) {
        // 只处理当前会话的事件
        guard let sessionId = chatSessionId,
              event.sessionId == sessionId || event.type == "connected" else { return }

        switch event.type {
        case "connected":
            vmLog.info("SSE 已连接")

        case "text":
            appendOrUpdateDisplay(type: .text, content: event.content ?? "")

        case "thinking":
            appendOrUpdateDisplay(type: .thinking, content: event.content ?? "")
            let step = CommandStep(status: "thinking", content: event.content ?? "")
            currentCommand?.steps.append(step)

        case "tool":
            let toolInfo = "[\(event.tool ?? "tool")] \(event.status ?? "")"
            let detail = event.input?.map { "\($0.key): \($0.value.stringValue)" }.joined(separator: ", ") ?? ""
            let output = event.output ?? ""
            let content = detail.isEmpty ? (output.isEmpty ? toolInfo : "\(toolInfo)\n\(output)") : "\(toolInfo): \(detail)"

            if event.status == "running" {
                chatEvents.append(ChatDisplayItem(type: .tool, content: content, toolId: event.toolId))
            } else if let toolId = event.toolId,
                      let idx = chatEvents.lastIndex(where: { $0.toolId == toolId }) {
                let resultContent = output.isEmpty ? "\(toolInfo)" : "\(toolInfo)\n\(output)"
                chatEvents[idx] = ChatDisplayItem(type: .tool, content: resultContent, toolId: toolId)
            }

            let step = CommandStep(status: "tool_call", content: content)
            currentCommand?.steps.append(step)

        case "step-start":
            break

        case "step-finish":
            break

        case "confirm":
            pendingConfirm = event
            let step = CommandStep(status: "skill", content: event.confirmMessage ?? "需要权限确认")
            currentCommand?.steps.append(step)

        case "session-status":
            isChatBusy = event.status == "busy"

        case "done":
            isChatBusy = false
            currentCommand?.isComplete = true
            let step = CommandStep(status: "result", content: "执行完成")
            currentCommand?.steps.append(step)

        case "error":
            let step = CommandStep(status: "result", content: "错误: \(event.content ?? "")")
            currentCommand?.steps.append(step)
            currentCommand?.isComplete = true
            isChatBusy = false

        default:
            // 子任务事件等
            if event.type.hasPrefix("subtask-") {
                let content = event.content ?? event.subtaskTitle ?? ""
                if !content.isEmpty {
                    appendOrUpdateDisplay(type: .subtask, content: "[\(event.subtaskTitle ?? "子任务")] \(content)")
                }
            }
        }
    }

    private func appendOrUpdateDisplay(type: ChatDisplayItem.DisplayType, content: String) {
        // text 和 thinking 是增量追加，合并到最后一个同类型的 item
        if let lastIdx = chatEvents.indices.last, chatEvents[lastIdx].type == type {
            chatEvents[lastIdx].content += content
        } else {
            chatEvents.append(ChatDisplayItem(type: type, content: content))
        }
    }

    // MARK: - ASR 消息处理

    private func handleASRMessage(_ msg: ASRMessage) {
        switch msg.type {
        case "partial":
            updateSentence(id: msg.sentenceId, text: msg.text, isFinal: false)
        case "final":
            vmLog.info("[Final] sentenceId=\(msg.sentenceId) text=\(msg.text.prefix(80))")
            updateSentence(id: msg.sentenceId, text: msg.text, isFinal: true)
        case "error":
            vmLog.error("ASR 错误: \(msg.text)")
        case "asr_complete":
            vmLog.info("ASR 识别完成")
        default:
            vmLog.warning("未知消息类型: \(msg.type)")
        }
    }

    private func updateSentence(id: Int, text: String, isFinal: Bool) {
        if let index = sentences.firstIndex(where: { $0.id == id }) {
            sentences[index].text = text
            sentences[index].isFinal = isFinal
        } else {
            sentences.append(RecognizedSentence(id: id, text: text, isFinal: isFinal))
        }
    }

    // MARK: - 历史

    private func saveToHistory() {
        let finalText = sentences.filter { $0.isFinal }.map { $0.text }.joined()
        if finalText.isEmpty { return }
        let item = HistoryItem(
            id: Int(Date().timeIntervalSince1970),
            sessionId: chatSessionId ?? UUID().uuidString,
            text: finalText,
            isCommand: currentCommand != nil,
            commandResult: currentCommand?.finalResult,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        history.insert(item, at: 0)
        vmLog.info("保存历史记录, text=\(finalText.prefix(50))")
    }

    func loadHistory() {
        // TODO: 从后端 API 加载历史记录
    }
}

// MARK: - Chat 展示模型

struct ChatDisplayItem: Identifiable {
    enum DisplayType {
        case text
        case thinking
        case tool
        case subtask
    }

    let id = UUID()
    let type: DisplayType
    var content: String
    var toolId: String?
}
