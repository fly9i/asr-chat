import Foundation
import os

private let chatLog = Logger(subsystem: "com.asragent.app", category: "Chat")

/// 管理与 Chat API 的通信（REST + SSE）
@MainActor
class ChatService: NSObject, ObservableObject, URLSessionDataDelegate {

    static let shared = ChatService()

    private let baseURL = "http://192.168.1.136:8009"

    @Published var isSSEConnected = false

    /// 当前会话收到的事件回调
    var onEvent: ((ChatEvent) -> Void)?

    private var sseTask: URLSessionDataTask?
    private var sseSession: URLSession?
    private var sseBuffer = ""

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = TimeInterval(INT_MAX)
        config.timeoutIntervalForResource = TimeInterval(INT_MAX)
        sseSession = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    // MARK: - SSE 订阅

    func connectSSE() {
        guard sseTask == nil else { return }
        guard let url = URL(string: "\(baseURL)/api/chat/events") else { return }
        chatLog.info("连接 SSE: \(url.absoluteString)")
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        sseTask = sseSession?.dataTask(with: request)
        sseTask?.resume()
    }

    func disconnectSSE() {
        sseTask?.cancel()
        sseTask = nil
        sseBuffer = ""
        isSSEConnected = false
        chatLog.info("SSE 已断开")
    }

    // MARK: - URLSessionDataDelegate

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        Task { @MainActor in
            self.handleSSEData(text)
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        Task { @MainActor in
            self.isSSEConnected = true
            chatLog.info("SSE 连接建立")
        }
        completionHandler(.allow)
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor in
            self.isSSEConnected = false
            if let error {
                chatLog.error("SSE 连接断开: \(error.localizedDescription)")
            } else {
                chatLog.info("SSE 连接关闭")
            }
            self.sseTask = nil
            // 自动重连
            try? await Task.sleep(for: .seconds(2))
            self.connectSSE()
        }
    }

    private func handleSSEData(_ text: String) {
        sseBuffer += text
        // SSE 格式: "data: {...}\n\n"
        let parts = sseBuffer.components(separatedBy: "\n\n")
        // 最后一个可能是不完整的，保留
        sseBuffer = parts.last ?? ""
        for i in 0..<(parts.count - 1) {
            let chunk = parts[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty else { continue }
            // 可能有多行 "data: ..." ，取 data: 后面的内容
            var jsonStr = ""
            for line in chunk.components(separatedBy: "\n") {
                if line.hasPrefix("data: ") {
                    jsonStr += String(line.dropFirst(6))
                } else if line.hasPrefix("data:") {
                    jsonStr += String(line.dropFirst(5))
                }
            }
            guard !jsonStr.isEmpty,
                  let jsonData = jsonStr.data(using: .utf8) else { continue }
            do {
                let event = try JSONDecoder().decode(ChatEvent.self, from: jsonData)
                chatLog.info("[SSE] type=\(event.type) session=\(event.sessionId ?? "") content=\(event.content?.prefix(50) ?? "")")
                onEvent?(event)
            } catch {
                chatLog.error("[SSE] JSON 解码失败: \(jsonStr.prefix(200)), error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - REST API

    /// 创建会话
    func createSession(title: String = "ASR 语音会话") async throws -> SessionResponse {
        let url = URL(string: "\(baseURL)/api/sessions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["title": title]
        request.httpBody = try JSONEncoder().encode(body)

        chatLog.info("创建会话: \(title)")
        let (data, _) = try await URLSession.shared.data(for: request)
        let session = try JSONDecoder().decode(SessionResponse.self, from: data)
        chatLog.info("会话已创建: id=\(session.id)")
        return session
    }

    /// 发送消息
    func sendMessage(sessionId: String, message: String) async throws {
        let url = URL(string: "\(baseURL)/api/chat/send/\(sessionId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["message": message]
        request.httpBody = try JSONEncoder().encode(body)

        chatLog.info("发送消息到会话 \(sessionId): \(message.prefix(100))")
        let (data, _) = try await URLSession.shared.data(for: request)
        let resp = try JSONDecoder().decode(SendMessageResponse.self, from: data)
        chatLog.info("消息发送结果: \(resp.status)")
    }

    /// 权限确认
    func confirmPermission(sessionId: String, confirmId: String, response: String) async throws {
        let url = URL(string: "\(baseURL)/api/chat/confirm/\(sessionId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["confirm_id": confirmId, "response": response]
        request.httpBody = try JSONEncoder().encode(body)

        chatLog.info("权限确认: session=\(sessionId) confirmId=\(confirmId) response=\(response)")
        let (_, _) = try await URLSession.shared.data(for: request)
    }
}
