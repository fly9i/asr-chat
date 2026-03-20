import Foundation

/// 管理与后端的 WebSocket 通信
class WebSocketManager: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    @Published var isConnected = false

    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private let serverURL: URL

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
        webSocket = session?.webSocketTask(with: serverURL)
        webSocket?.resume()
    }

    func disconnect() {
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        DispatchQueue.main.async { self.isConnected = false }
    }

    /// 发送二进制音频数据
    func sendAudio(_ data: Data) {
        webSocket?.send(.data(data)) { error in
            if let error {
                print("发送音频数据失败: \(error)")
            }
        }
    }

    /// 发送控制消息（如停止、执行指令）
    func sendAction(_ action: ClientAction) {
        guard let data = try? JSONEncoder().encode(action) else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(text)) { error in
            if let error {
                print("发送控制消息失败: \(error)")
            }
        }
    }

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let msg = try? JSONDecoder().decode(ASRMessage.self, from: data) {
                        DispatchQueue.main.async {
                            self?.onMessage?(msg)
                        }
                    }
                case .data(let data):
                    if let msg = try? JSONDecoder().decode(ASRMessage.self, from: data) {
                        DispatchQueue.main.async {
                            self?.onMessage?(msg)
                        }
                    }
                @unknown default:
                    break
                }
                // 继续监听
                self?.receiveMessage()
            case .failure(let error):
                print("WebSocket 接收错误: \(error)")
                DispatchQueue.main.async {
                    self?.isConnected = false
                }
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { self.isConnected = true }
        receiveMessage()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async { self.isConnected = false }
    }
}
