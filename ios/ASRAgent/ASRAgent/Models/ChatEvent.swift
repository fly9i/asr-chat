import Foundation

/// SSE 事件模型
struct ChatEvent: Codable, Identifiable {
    let type: String
    var content: String?
    var sessionId: String?
    var toolId: String?
    var tool: String?
    var status: String?
    var input: [String: AnyCodable]?
    var output: String?
    var error: String?
    var stepId: String?
    var reason: String?
    var tokens: TokenUsage?
    var confirmId: String?
    var confirmMessage: String?
    var subtaskId: String?
    var subtaskTitle: String?

    var id: String { "\(type)_\(sessionId ?? "")_\(toolId ?? stepId ?? confirmId ?? UUID().uuidString)" }
}

struct TokenUsage: Codable {
    let input: Int?
    let output: Int?
}

/// 用于解码任意 JSON 值
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { value = s }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let b = try? container.decode(Bool.self) { value = b }
        else if let dict = try? container.decode([String: AnyCodable].self) { value = dict }
        else if let arr = try? container.decode([AnyCodable].self) { value = arr }
        else { value = "" }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let s = value as? String { try container.encode(s) }
        else if let i = value as? Int { try container.encode(i) }
        else if let d = value as? Double { try container.encode(d) }
        else if let b = value as? Bool { try container.encode(b) }
        else { try container.encode(String(describing: value)) }
    }

    var stringValue: String {
        if let s = value as? String { return s }
        if let dict = value as? [String: AnyCodable] {
            let parts = dict.map { "\($0.key): \($0.value.stringValue)" }
            return parts.joined(separator: ", ")
        }
        return String(describing: value)
    }
}

/// 创建会话响应
struct SessionResponse: Codable {
    let id: String
    let title: String
}

/// 发送消息响应
struct SendMessageResponse: Codable {
    let status: String
}
