import Foundation
import os

private let wsLog = Logger(subsystem: "com.asragent.app", category: "WebSocket")

/// 管理与后端的 WebSocket 通信
class WebSocketManager: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    @Published var isConnected = false

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private let serverURL: URL
    private var audioFrameCount = 0
    private var audioByteCount = 0

    var onMessage: ((ASRMessage) -> Void)?

    init(serverURL: URL = URL(string: "ws://localhost:8000/ws/asr")!) {
        self.serverURL = serverURL
        super.init()
        self.session = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: OperationQueue()
        )
    }

    func connect() {
        disconnect()
        audioFrameCount = 0
        audioByteCount = 0
        wsLog.info("正在连接 WebSocket: \(self.serverURL.absoluteString)")
        webSocket = session?.webSocketTask(with: serverURL)
        webSocket?.resume()
    }

    func disconnect() {
        wsLog.info("断开 WebSocket 连接, 已发送 \(self.audioFrameCount) 帧, \(self.audioByteCount) 字节")
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        DispatchQueue.main.async { self.isConnected = false }
    }

    /// 发送二进制音频数据
    func sendAudio(_ data: Data) {
        guard isConnected else {
            wsLog.warning("WebSocket 未连接，丢弃音频数据 \(data.count) 字节")
            return
        }
        audioFrameCount += 1
        audioByteCount += data.count
        if audioFrameCount % 50 == 1 {
            wsLog.info("[Audio] 发送帧 #\(self.audioFrameCount), 本次=\(data.count)字节, 累计=\(self.audioByteCount)字节")
        }
        webSocket?.send(.data(data)) { error in
            if let error {
                wsLog.error("发送音频数据失败: \(error.localizedDescription)")
            }
        }
    }

    /// 发送控制消息（如停止、执行指令）
    func sendAction(_ action: ClientAction) {
        guard let data = try? JSONEncoder().encode(action) else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        wsLog.info("[Action] 发送控制消息: \(text)")
        webSocket?.send(.string(text)) { error in
            if let error {
                wsLog.error("发送控制消息失败: \(error.localizedDescription)")
            }
        }
    }

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    wsLog.info("[Recv] 收到文本: \(text.prefix(200))")
                    if let data = text.data(using: .utf8),
                       let msg = try? JSONDecoder().decode(ASRMessage.self, from: data) {
                        DispatchQueue.main.async {
                            self?.onMessage?(msg)
                        }
                    } else {
                        wsLog.error("[Recv] JSON 解码失败: \(text.prefix(200))")
                    }
                case .data(let data):
                    wsLog.info("[Recv] 收到二进制数据: \(data.count) 字节")
                    if let msg = try? JSONDecoder().decode(ASRMessage.self, from: data) {
                        DispatchQueue.main.async {
                            self?.onMessage?(msg)
                        }
                    }
                @unknown default:
                    break
                }
                self?.receiveMessage()
            case .failure(let error):
                wsLog.error("WebSocket 接收错误: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.isConnected = false
                }
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        wsLog.info("WebSocket 已连接")
        DispatchQueue.main.async { self.isConnected = true }
        receiveMessage()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        wsLog.info("WebSocket 已关闭, code=\(closeCode.rawValue)")
        DispatchQueue.main.async { self.isConnected = false }
    }
}
