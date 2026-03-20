import Foundation
import SwiftUI
import os

private let vmLog = Logger(subsystem: "com.asragent.app", category: "ViewModel")

/// 核心 ViewModel，串联录音、WebSocket、UI 状态
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

    // 指令模式下收集的文本
    private var commandSentenceStartId = 0

    let recorder = AudioRecorder()
    let wsManager = WebSocketManager()

    init() {
        setupBindings()
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
    }

    // MARK: - 录音控制

    func startRecording(resume: Bool = false) {
        vmLog.info("开始录音流程, resume=\(resume)")
        if !resume {
            sentences = []
            currentCommand = nil
            isCommandMode = false
        }
        wsManager.connect()
        // 等连接建立后再开始录音
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

        let commandText = sentences
            .filter { $0.id >= commandSentenceStartId && $0.isFinal }
            .map { $0.text }
            .joined()

        vmLog.info("结束指令模式, commandText=\(commandText.prefix(100))")

        if !commandText.isEmpty {
            currentCommand?.commandText = commandText
            wsManager.sendAction(ClientAction(action: "execute_command", text: commandText))
        }
    }

    // MARK: - 消息处理

    private func handleASRMessage(_ msg: ASRMessage) {
        switch msg.type {
        case "partial":
            updateSentence(id: msg.sentenceId, text: msg.text, isFinal: false)
        case "final":
            vmLog.info("[Final] sentenceId=\(msg.sentenceId) text=\(msg.text.prefix(80))")
            updateSentence(id: msg.sentenceId, text: msg.text, isFinal: true)
        case "command_status":
            let step = CommandStep(status: msg.status, content: msg.content)
            currentCommand?.steps.append(step)
        case "command_result":
            let step = CommandStep(status: msg.status, content: msg.content)
            currentCommand?.steps.append(step)
            currentCommand?.finalResult = msg.content
            currentCommand?.isComplete = true
        case "error":
            vmLog.error("ASR 错误: \(msg.text)")
        case "asr_complete":
            vmLog.info("ASR 识别完成")
        default:
            vmLog.warning("未知消息类型: \(msg.type)")
        }
    }

    /// 更新或新增识别句子 — 支持滑动窗口实时修正
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
            sessionId: UUID().uuidString,
            text: finalText,
            isCommand: false,
            commandResult: nil,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        history.insert(item, at: 0)
        vmLog.info("保存历史记录, text=\(finalText.prefix(50))")
    }

    func loadHistory() {
        // TODO: 从后端 API 加载历史记录
    }
}
