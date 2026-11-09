import Foundation

// Messages and content blocks encode with a discriminator field (`role` for messages, `type` for blocks), in
// the same shape as pi's JSON transcripts.

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue _: Int) { nil }
}

/// Encodes `value` and then adds a discriminator, so every block keeps its own fields flat.
private func encodeTagged(_ value: some Encodable, key: String, tag: String, to encoder: Encoder) throws {
    try value.encode(to: encoder)
    var container = encoder.container(keyedBy: DynamicKey.self)
    try container.encode(tag, forKey: DynamicKey(key))
}

private func decodeTag(_ key: String, from decoder: Decoder) throws -> String {
    let container = try decoder.container(keyedBy: DynamicKey.self)
    return try container.decode(String.self, forKey: DynamicKey(key))
}

extension AssistantContent: Codable {
    public init(from decoder: Decoder) throws {
        switch try decodeTag("type", from: decoder) {
        case "text": self = try .text(TextContent(from: decoder))
        case "thinking": self = try .thinking(ThinkingContent(from: decoder))
        case "toolCall": self = try .toolCall(ToolCall(from: decoder))
        case let type:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown assistant content type \(type)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .text(block): try encodeTagged(block, key: "type", tag: "text", to: encoder)
        case let .thinking(block): try encodeTagged(block, key: "type", tag: "thinking", to: encoder)
        case let .toolCall(block): try encodeTagged(block, key: "type", tag: "toolCall", to: encoder)
        }
    }
}

extension UserContent: Codable {
    public init(from decoder: Decoder) throws {
        switch try decodeTag("type", from: decoder) {
        case "text": self = try .text(TextContent(from: decoder))
        case "image": self = try .image(ImageContent(from: decoder))
        case let type:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown user content type \(type)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .text(block): try encodeTagged(block, key: "type", tag: "text", to: encoder)
        case let .image(block): try encodeTagged(block, key: "type", tag: "image", to: encoder)
        }
    }
}

extension UserMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case content, timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // pi writes plain-text user messages as a string.
        if let text = try? container.decode(String.self, forKey: .content) {
            content = [.text(TextContent(text: text))]
        } else {
            content = try container.decode([UserContent].self, forKey: .content)
        }
        timestamp = try container.decode(Timestamp.self, forKey: .timestamp)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
    }
}


extension Message: Codable {
    public init(from decoder: Decoder) throws {
        switch try decodeTag("role", from: decoder) {
        case "system": self = try .system(SystemMessage(from: decoder))
        case "user": self = try .user(UserMessage(from: decoder))
        case "assistant": self = try .assistant(AssistantMessage(from: decoder))
        case "toolResult": self = try .toolResult(ToolResultMessage(from: decoder))
        case let role:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown message role \(role)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .system(message): try encodeTagged(message, key: "role", tag: "system", to: encoder)
        case let .user(message): try encodeTagged(message, key: "role", tag: "user", to: encoder)
        case let .assistant(message): try encodeTagged(message, key: "role", tag: "assistant", to: encoder)
        case let .toolResult(message): try encodeTagged(message, key: "role", tag: "toolResult", to: encoder)
        }
    }
}
