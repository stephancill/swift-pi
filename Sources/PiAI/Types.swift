import Foundation

/// Milliseconds since 1970, the timestamp unit of every message.
public typealias Timestamp = Int64

public func nowTimestamp() -> Timestamp {
    Timestamp((Date().timeIntervalSince1970 * 1000).rounded())
}

// MARK: - Content blocks

public struct TextContent: Sendable, Hashable, Codable {
    public var text: String
    /// Provider metadata for replaying the text, such as an OpenAI Responses message id.
    public var textSignature: String?

    public init(text: String, textSignature: String? = nil) {
        self.text = text
        self.textSignature = textSignature
    }
}

public struct ThinkingContent: Sendable, Hashable, Codable {
    public var thinking: String
    /// Provider-specific replay data. For OpenAI-compatible APIs, the delta field the reasoning arrived in.
    public var thinkingSignature: String?
    /// The thinking was redacted by safety filters; `thinkingSignature` holds the opaque payload.
    public var redacted: Bool?

    public init(thinking: String, thinkingSignature: String? = nil, redacted: Bool? = nil) {
        self.thinking = thinking
        self.thinkingSignature = thinkingSignature
        self.redacted = redacted
    }
}

public struct ImageContent: Sendable, Hashable, Codable {
    /// Base64-encoded image data.
    public var data: String
    /// Such as `image/png`.
    public var mimeType: String

    public init(data: String, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

public struct ToolCall: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var arguments: JSONObject
    /// Set when the model's arguments text was not a JSON object; `arguments` is then empty and validation fails with it.
    public var argumentsError: String?

    public init(id: String, name: String, arguments: JSONObject, argumentsError: String? = nil) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.argumentsError = argumentsError
    }
}

/// A block of an assistant message.
public enum AssistantContent: Sendable, Hashable {
    case text(TextContent)
    case thinking(ThinkingContent)
    case toolCall(ToolCall)
}

/// A block of a user message or tool result.
public enum UserContent: Sendable, Hashable {
    case text(TextContent)
    case image(ImageContent)
}

// MARK: - Usage

public struct Cost: Sendable, Hashable, Codable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var total: Double

    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0, total: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.total = total
    }
}

public struct Usage: Sendable, Hashable, Codable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    /// Reasoning tokens, a subset of `output`, when the provider reports them.
    public var reasoning: Int?
    public var totalTokens: Int
    public var cost: Cost

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, reasoning: Int? = nil, totalTokens: Int = 0, cost: Cost = Cost()) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
        self.totalTokens = totalTokens
        self.cost = cost
    }

    public static let zero = Usage()
}

public enum StopReason: String, Sendable, Hashable, Codable {
    case pending
    case stop
    case length
    case toolUse
    case error
    case aborted
}

public enum ThinkingLevel: String, Sendable, Hashable, Codable, CaseIterable {
    case off
    case minimal
    case low
    case medium
    case high
}

// MARK: - Tools

/// A tool the model may call. `parameters` is the JSON Schema of its arguments.
public struct Tool: Sendable, Hashable, Codable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ToolReference: Sendable, Hashable, Codable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

// MARK: - Messages

/// A named system prompt section. A nil `text` removes the section.
public struct SystemSection: Sendable, Hashable, Codable {
    public var name: String
    public var text: String?

    public init(name: String, text: String?) {
        self.name = name
        self.text = text
    }
}

/// System instructions and tool declarations at one point in the transcript.
///
/// The leading system message is the system prompt. Later system messages change it: `content` adds
/// instructions, `sections` replace or remove named sections, and `toolsAdded`/`toolsRemoved` change the
/// tool set. Replaying every system message in order yields the current prompt and tools.
public struct SystemMessage: Sendable, Hashable, Codable {
    public var content: String
    public var sections: [SystemSection]?
    public var toolsAdded: [Tool]?
    public var toolsRemoved: [ToolReference]?
    public var timestamp: Timestamp

    public init(content: String, sections: [SystemSection]? = nil, toolsAdded: [Tool]? = nil, toolsRemoved: [ToolReference]? = nil, timestamp: Timestamp = nowTimestamp()) {
        self.content = content
        self.sections = sections
        self.toolsAdded = toolsAdded
        self.toolsRemoved = toolsRemoved
        self.timestamp = timestamp
    }
}

public struct UserMessage: Sendable, Hashable {
    public var content: [UserContent]
    public var timestamp: Timestamp

    public init(content: [UserContent], timestamp: Timestamp = nowTimestamp()) {
        self.content = content
        self.timestamp = timestamp
    }

    public init(text: String, images: [ImageContent] = [], timestamp: Timestamp = nowTimestamp()) {
        self.content = [.text(TextContent(text: text))] + images.map(UserContent.image)
        self.timestamp = timestamp
    }
}

public struct AssistantMessage: Sendable, Hashable, Codable {
    public var content: [AssistantContent]
    public var api: String
    public var provider: String
    public var model: String
    /// The concrete model the provider reports, when it differs from `model`.
    public var responseModel: String?
    public var responseId: String?
    /// The thinking level the agent loop requested for this response.
    public var thinkingLevel: ThinkingLevel?
    public var usage: Usage
    public var stopReason: StopReason
    public var errorMessage: String?
    public var rawStopReason: String?
    public var timestamp: Timestamp
    /// Milliseconds from `timestamp` until the response ended.
    public var durationMs: Int?

    public init(
        content: [AssistantContent] = [],
        api: String,
        provider: String,
        model: String,
        responseModel: String? = nil,
        responseId: String? = nil,
        thinkingLevel: ThinkingLevel? = nil,
        usage: Usage = .zero,
        stopReason: StopReason,
        errorMessage: String? = nil,
        rawStopReason: String? = nil,
        timestamp: Timestamp = nowTimestamp(),
        durationMs: Int? = nil
    ) {
        self.content = content
        self.api = api
        self.provider = provider
        self.model = model
        self.responseModel = responseModel
        self.responseId = responseId
        self.thinkingLevel = thinkingLevel
        self.usage = usage
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.rawStopReason = rawStopReason
        self.timestamp = timestamp
        self.durationMs = durationMs
    }

    public var toolCalls: [ToolCall] {
        content.compactMap { if case let .toolCall(call) = $0 { call } else { nil } }
    }

    /// The text blocks joined.
    public var text: String {
        content.compactMap { if case let .text(block) = $0 { block.text } else { nil } }.joined()
    }
}

public struct ToolResultMessage: Sendable, Hashable, Codable {
    public var toolCallId: String
    public var toolName: String
    public var content: [UserContent]
    /// Structured details for the UI and logs; not sent to the model.
    public var details: JSONValue?
    public var isError: Bool
    public var timestamp: Timestamp
    /// Milliseconds the tool's execution took.
    public var durationMs: Int?

    public init(toolCallId: String, toolName: String, content: [UserContent], details: JSONValue? = nil, isError: Bool, timestamp: Timestamp = nowTimestamp(), durationMs: Int? = nil) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.content = content
        self.details = details
        self.isError = isError
        self.timestamp = timestamp
        self.durationMs = durationMs
    }
}

public enum Message: Sendable, Hashable {
    case system(SystemMessage)
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)

    public var role: String {
        switch self {
        case .system: "system"
        case .user: "user"
        case .assistant: "assistant"
        case .toolResult: "toolResult"
        }
    }

    public var timestamp: Timestamp {
        switch self {
        case let .system(message): message.timestamp
        case let .user(message): message.timestamp
        case let .assistant(message): message.timestamp
        case let .toolResult(message): message.timestamp
        }
    }
}

// MARK: - Models

/// The kind of input a model accepts.
public enum InputModality: String, Sendable, Hashable, Codable {
    case text
    case image
}

/// Compatibility switches for OpenAI-compatible servers. Unset fields are detected from the base URL.
public struct OpenAICompletionsCompat: Sendable, Hashable, Codable {
    /// Sends `stream_options.include_usage`. Default true.
    public var supportsUsageInStreaming: Bool?
    /// `max_completion_tokens` (OpenAI) or `max_tokens` (most other servers).
    public var maxTokensField: MaxTokensField?
    /// Sends instructions as `developer` rather than `system` for reasoning models.
    public var supportsDeveloperRole: Bool?
    /// Sends `strict` on function tools.
    public var supportsStrictMode: Bool?
    /// Adds `name` to tool result messages.
    public var requiresToolResultName: Bool?
    /// Inserts an assistant message between tool results and a following user message.
    public var requiresAssistantAfterToolResult: Bool?
    /// How a thinking level is sent.
    public var thinkingFormat: ThinkingFormat?

    public enum MaxTokensField: String, Sendable, Hashable, Codable {
        case maxCompletionTokens = "max_completion_tokens"
        case maxTokens = "max_tokens"
    }

    public enum ThinkingFormat: String, Sendable, Hashable, Codable {
        /// No thinking parameter.
        case none
        /// `reasoning_effort` (OpenAI and most compatible servers).
        case openai
        /// `reasoning: { effort }` (OpenRouter).
        case openrouter
    }

    public init(
        supportsUsageInStreaming: Bool? = nil,
        maxTokensField: MaxTokensField? = nil,
        supportsDeveloperRole: Bool? = nil,
        supportsStrictMode: Bool? = nil,
        requiresToolResultName: Bool? = nil,
        requiresAssistantAfterToolResult: Bool? = nil,
        thinkingFormat: ThinkingFormat? = nil
    ) {
        self.supportsUsageInStreaming = supportsUsageInStreaming
        self.maxTokensField = maxTokensField
        self.supportsDeveloperRole = supportsDeveloperRole
        self.supportsStrictMode = supportsStrictMode
        self.requiresToolResultName = requiresToolResultName
        self.requiresAssistantAfterToolResult = requiresAssistantAfterToolResult
        self.thinkingFormat = thinkingFormat
    }
}

/// Price per million tokens, in dollars.
public struct ModelCost: Sendable, Hashable, Codable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

/// A chat model and where to reach it.
public struct Model: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    /// The wire API, such as `openai-completions`.
    public var api: String
    /// Who serves it, such as `openrouter`; used for detection and shown in messages.
    public var provider: String
    /// Such as `https://openrouter.ai/api/v1`.
    public var baseURL: String
    public var reasoning: Bool
    public var input: [InputModality]
    public var cost: ModelCost
    public var contextWindow: Int
    public var maxTokens: Int
    /// Extra HTTP headers sent with every request.
    public var headers: [String: String]?
    public var compat: OpenAICompletionsCompat?

    public init(
        id: String,
        name: String? = nil,
        api: String = OpenAICompletions.api,
        provider: String,
        baseURL: String,
        reasoning: Bool = false,
        input: [InputModality] = [.text],
        cost: ModelCost = ModelCost(),
        contextWindow: Int = 128_000,
        maxTokens: Int = 16384,
        headers: [String: String]? = nil,
        compat: OpenAICompletionsCompat? = nil
    ) {
        self.id = id
        self.name = name ?? id
        self.api = api
        self.provider = provider
        self.baseURL = baseURL
        self.reasoning = reasoning
        self.input = input
        self.cost = cost
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.headers = headers
        self.compat = compat
    }
}

// MARK: - Contexts and options

/// A request: a prompt and tools (shorthand for a leading system message) and the conversation.
public struct Context: Sendable, Hashable {
    public var systemPrompt: String?
    public var messages: [Message]
    public var tools: [Tool]?

    public init(systemPrompt: String? = nil, messages: [Message], tools: [Tool]? = nil) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }
}

/// A normalized request: the prompt and tool declarations live in the transcript's system messages.
public struct TranscriptContext: Sendable, Hashable {
    public let messages: [Message]

    /// Folds `systemPrompt` and `tools` into a leading system message.
    public init(normalizing context: Context) {
        if let initial = createInitialSystemMessage(systemPrompt: context.systemPrompt, tools: context.tools) {
            messages = [.system(initial)] + context.messages
        } else {
            messages = context.messages
        }
    }

    /// A transcript whose system messages already carry the prompt and tools.
    public init(transcript messages: [Message]) {
        self.messages = messages
    }
}

public enum ToolChoice: String, Sendable, Hashable {
    case auto
    case none
}

public struct StreamOptions: Sendable {
    public var apiKey: String?
    public var temperature: Double?
    public var maxTokens: Int?
    /// Requested reasoning; nil turns thinking off where the provider allows it.
    public var reasoning: ThinkingLevel?
    public var toolChoice: ToolChoice?
    /// Headers merged over the model's and the provider's defaults.
    public var headers: [String: String]?
    /// Request timeout in seconds.
    public var timeout: TimeInterval?
    /// The URL session requests go through; `URLSession.shared` when nil.
    public var session: URLSession?

    public init(
        apiKey: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        reasoning: ThinkingLevel? = nil,
        toolChoice: ToolChoice? = nil,
        headers: [String: String]? = nil,
        timeout: TimeInterval? = nil,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.reasoning = reasoning
        self.toolChoice = toolChoice
        self.headers = headers
        self.timeout = timeout
        self.session = session
    }
}
