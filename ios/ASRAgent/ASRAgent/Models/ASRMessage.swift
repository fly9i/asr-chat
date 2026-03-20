import Foundation

/// 从服务端接收的 WebSocket 消息
struct ASRMessage: Codable, Identifiable {
    let type: String        // partial | final | command_status | command_result | error | asr_complete
    var text: String = ""
    var sentenceId: Int = 0
    var status: String = ""
    var content: String = ""

    var id: String { "\(type)_\(sentenceId)_\(text.prefix(20))" }

    enum CodingKeys: String, CodingKey {
        case type, text, status, content
        case sentenceId = "sentence_id"
    }
}

/// 客户端发送给服务端的控制消息
struct ClientAction: Codable {
    let action: String      // stop | execute_command
    var text: String = ""
}

/// 识别出的文本段落
struct RecognizedSentence: Identifiable {
    let id: Int
    var text: String
    var isFinal: Bool
}

/// 指令执行记录
struct CommandRecord: Identifiable {
    let id = UUID()
    var commandText: String
    var steps: [CommandStep] = []
    var finalResult: String = ""
    var isComplete: Bool = false
}

struct CommandStep: Identifiable {
    let id = UUID()
    let status: String     // thinking | tool_call | skill | result
    let content: String
}

/// 历史记录
struct HistoryItem: Codable, Identifiable {
    let id: Int
    let sessionId: String
    let text: String
    let isCommand: Bool
    let commandResult: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, text
        case sessionId = "session_id"
        case isCommand = "is_command"
        case commandResult = "command_result"
        case createdAt = "created_at"
    }
}
