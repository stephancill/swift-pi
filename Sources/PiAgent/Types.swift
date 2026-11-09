import Foundation
import PiAI

/// A message the app keeps in its transcript that the model never sees as is, such as a UI notice.
/// `convertToLlm` decides what (if anything) the model sees for it.
public struct CustomAgentMessage: Sendable, Hashable, Codable {
    /// The app's name for the kind of message.
    public var kind: String
    public var payload: JSONValue
    public var timestamp: Timestamp

    public init(kind: String, payload: JSONValue, timestamp: Timestamp = nowTimestamp()) {
        self.kind = kind
        self.payload = payload
        self.timestamp = timestamp
    }
}

/// A transcript entry: a model message, or one of the app's own.
public enum AgentMessage: Sendable, Hashable {
    case llm(Message)
    case custom(CustomAgentMessage)

    public static func user(_ text: String, images: [ImageContent] = []) -> AgentMessage {
        .llm(.user(UserMessage(text: text, images: images)))
    }

    public var message: Message? {
        if case let .llm(message) = self { return message }
        return nil
    }

    public var role: String {
        switch self {
        case let .llm(message): message.role
        case .custom: "custom"
        }
    }

    public var assistant: AssistantMessage? {
        if case let .llm(.assistant(message)) = self { return message }
        return nil
    }

    public var isSystem: Bool {
        if case .llm(.system) = self { return true }
        return false
    }
}

extension AgentMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case role
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(String.self, forKey: .role) == "custom" {
            self = try .custom(CustomAgentMessage(from: decoder))
        } else {
            self = try .llm(Message(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .llm(message):
            try message.encode(to: encoder)
        case let .custom(message):
            try message.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("custom", forKey: .role)
        }
    }
}

/// A tool call from an assistant message.
public typealias AgentToolCall = ToolCall

public enum ToolExecutionMode: String, Sendable, Hashable, Codable {
    /// Each call is prepared, run and finalized before the next starts.
    case sequential
    /// Calls are prepared one by one, then allowed calls run concurrently.
    case parallel
}

/// How many queued messages are injected at a drain point.
public enum QueueMode: String, Sendable, Hashable, Codable {
    case all
    case oneAtATime
}

/// What a tool returns, finally or as a partial update.
public struct AgentToolResult: Sendable, Hashable {
    /// Text or images returned to the model.
    public var content: [UserContent]
    /// Structured details for the UI and logs.
    public var details: JSONValue?
    /// Reports a failure without throwing: the model sees `content` as an error, `details` stay for the UI.
    public var isError: Bool
    /// Asks the agent to stop after this tool batch; only honored when every result in the batch asks.
    public var terminate: Bool

    public init(content: [UserContent], details: JSONValue? = nil, isError: Bool = false, terminate: Bool = false) {
        self.content = content
        self.details = details
        self.isError = isError
        self.terminate = terminate
    }

    public init(text: String, details: JSONValue? = nil, isError: Bool = false) {
        self.init(content: [.text(TextContent(text: text))], details: details, isError: isError)
    }

    static func error(_ message: String) -> AgentToolResult {
        AgentToolResult(text: message)
    }
}

/// Receives a tool's partial results while it runs.
public typealias AgentToolUpdate = @Sendable (AgentToolResult) async -> Void

/// A tool the agent can run.
public struct AgentTool: Sendable {
    public var name: String
    /// A human-readable name for the UI.
    public var label: String
    public var description: String
    /// JSON Schema of the arguments.
    public var parameters: JSONValue
    /// Overrides the loop's execution mode for calls of this tool.
    public var executionMode: ToolExecutionMode?
    /// Rewrites raw arguments before validation, such as an older argument shape.
    public var prepareArguments: (@Sendable (JSONObject) -> JSONObject)?
    /// Runs the call with validated arguments. Throw on failure, or return a result with `isError`. The task is
    /// cancelled when the run is aborted.
    public var execute: @Sendable (_ toolCallId: String, _ arguments: JSONObject, _ onUpdate: @escaping AgentToolUpdate) async throws -> AgentToolResult

    public init(
        name: String,
        label: String? = nil,
        description: String,
        parameters: JSONValue,
        executionMode: ToolExecutionMode? = nil,
        prepareArguments: (@Sendable (JSONObject) -> JSONObject)? = nil,
        execute: @escaping @Sendable (_ toolCallId: String, _ arguments: JSONObject, _ onUpdate: @escaping AgentToolUpdate) async throws -> AgentToolResult
    ) {
        self.name = name
        self.label = label ?? name
        self.description = description
        self.parameters = parameters
        self.executionMode = executionMode
        self.prepareArguments = prepareArguments
        self.execute = execute
    }

    /// What the model sees of the tool.
    public var declaration: Tool {
        Tool(name: name, description: description, parameters: parameters)
    }
}

/// The context a run works on.
public struct AgentContext: Sendable {
    /// The transcript the model sees (after `convertToLlm`).
    public var messages: [AgentMessage]
    /// Tools the run can execute.
    public var tools: [AgentTool]

    public init(messages: [AgentMessage], tools: [AgentTool] = []) {
        self.messages = messages
        self.tools = tools
    }
}

public struct BeforeToolCallContext: Sendable {
    public var assistantMessage: AssistantMessage
    public var toolCall: AgentToolCall
    /// Validated arguments.
    public var arguments: JSONObject
    public var context: AgentContext
}

/// Returned from `beforeToolCall`: `block` prevents the call and reports `reason` to the model as an error.
public struct BeforeToolCallResult: Sendable {
    public var block: Bool
    public var reason: String?
    public var terminate: Bool

    public init(block: Bool, reason: String? = nil, terminate: Bool = false) {
        self.block = block
        self.reason = reason
        self.terminate = terminate
    }
}

public struct AfterToolCallContext: Sendable {
    public var assistantMessage: AssistantMessage
    public var toolCall: AgentToolCall
    public var arguments: JSONObject
    public var result: AgentToolResult
    public var isError: Bool
    public var context: AgentContext
}

/// Returned from `afterToolCall`: each set field replaces the executed result's.
public struct AfterToolCallResult: Sendable {
    public var content: [UserContent]?
    public var details: JSONValue?
    public var isError: Bool?
    public var terminate: Bool?

    public init(content: [UserContent]? = nil, details: JSONValue? = nil, isError: Bool? = nil, terminate: Bool? = nil) {
        self.content = content
        self.details = details
        self.isError = isError
        self.terminate = terminate
    }
}

/// A completed turn: one assistant response and its tool results.
public struct AgentTurnContext: Sendable {
    public var message: AssistantMessage
    public var toolResults: [ToolResultMessage]
    public var context: AgentContext
    /// What the run would return if it ended now.
    public var newMessages: [AgentMessage]
}

/// Returned from `finishTurn`: `continue` ensures one more request, `end` ends the run.
public enum AgentTurnDecision: Sendable {
    case `continue`
    case end
}

/// Replacement state for the next request.
public struct AgentLoopTurnUpdate: Sendable {
    public var context: AgentContext?
    /// Messages appended before the next request.
    public var messages: [AgentMessage]?
    public var model: Model?
    public var thinkingLevel: ThinkingLevel?

    public init(context: AgentContext? = nil, messages: [AgentMessage]? = nil, model: Model? = nil, thinkingLevel: ThinkingLevel? = nil) {
        self.context = context
        self.messages = messages
        self.model = model
        self.thinkingLevel = thinkingLevel
    }
}

public struct PrepareRequestContext: Sendable {
    public var context: AgentContext
    public var model: Model
    public var thinkingLevel: ThinkingLevel
}

/// What a run needs beyond its context. Every hook is optional except `convertToLlm`.
public struct AgentLoopConfig: Sendable {
    public var model: Model
    /// Requested reasoning; nil is off.
    public var reasoning: ThinkingLevel?
    public var streamOptions: StreamOptions
    /// Agent messages to model messages before each request; drop what the model shouldn't see.
    public var convertToLlm: @Sendable ([AgentMessage]) async -> [Message]
    /// Rewrites the transcript before `convertToLlm`, such as to prune it to fit the context window.
    public var transformContext: (@Sendable ([AgentMessage]) async -> [AgentMessage])?
    /// Resolves the API key for each request, for keys that expire.
    public var getApiKey: (@Sendable (_ provider: String) async -> String?)?
    public var finishTurn: (@Sendable (AgentTurnContext) async -> AgentTurnDecision?)?
    public var prepareRequest: (@Sendable (PrepareRequestContext) async -> AgentLoopTurnUpdate?)?
    public var prepareNextTurn: (@Sendable (AgentTurnContext) async -> AgentLoopTurnUpdate?)?
    /// Messages to inject after the current tool batch, before the next request.
    public var getSteeringMessages: (@Sendable () async -> [AgentMessage])?
    /// Messages to process when the agent would otherwise stop.
    public var getFollowUpMessages: (@Sendable () async -> [AgentMessage])?
    public var toolExecution: ToolExecutionMode
    public var beforeToolCall: (@Sendable (BeforeToolCallContext) async -> BeforeToolCallResult?)?
    public var afterToolCall: (@Sendable (AfterToolCallContext) async -> AfterToolCallResult?)?

    public init(
        model: Model,
        reasoning: ThinkingLevel? = nil,
        streamOptions: StreamOptions = StreamOptions(),
        convertToLlm: @escaping @Sendable ([AgentMessage]) async -> [Message] = defaultConvertToLlm,
        transformContext: (@Sendable ([AgentMessage]) async -> [AgentMessage])? = nil,
        getApiKey: (@Sendable (_ provider: String) async -> String?)? = nil,
        finishTurn: (@Sendable (AgentTurnContext) async -> AgentTurnDecision?)? = nil,
        prepareRequest: (@Sendable (PrepareRequestContext) async -> AgentLoopTurnUpdate?)? = nil,
        prepareNextTurn: (@Sendable (AgentTurnContext) async -> AgentLoopTurnUpdate?)? = nil,
        getSteeringMessages: (@Sendable () async -> [AgentMessage])? = nil,
        getFollowUpMessages: (@Sendable () async -> [AgentMessage])? = nil,
        toolExecution: ToolExecutionMode = .parallel,
        beforeToolCall: (@Sendable (BeforeToolCallContext) async -> BeforeToolCallResult?)? = nil,
        afterToolCall: (@Sendable (AfterToolCallContext) async -> AfterToolCallResult?)? = nil
    ) {
        self.model = model
        self.reasoning = reasoning
        self.streamOptions = streamOptions
        self.convertToLlm = convertToLlm
        self.transformContext = transformContext
        self.getApiKey = getApiKey
        self.finishTurn = finishTurn
        self.prepareRequest = prepareRequest
        self.prepareNextTurn = prepareNextTurn
        self.getSteeringMessages = getSteeringMessages
        self.getFollowUpMessages = getFollowUpMessages
        self.toolExecution = toolExecution
        self.beforeToolCall = beforeToolCall
        self.afterToolCall = afterToolCall
    }
}

/// Keeps model messages and drops the app's own.
@Sendable public func defaultConvertToLlm(_ messages: [AgentMessage]) async -> [Message] {
    messages.compactMap(\.message)
}

/// What a run reports, for the UI.
public enum AgentEvent: Sendable {
    case agentStart
    /// The last event of a run, with every message the run added.
    case agentEnd(messages: [AgentMessage])
    /// A turn is one assistant response and its tool calls.
    case turnStart
    case turnEnd(message: AgentMessage, toolResults: [ToolResultMessage])
    /// Emitted for every message the run adds.
    case messageStart(AgentMessage)
    /// Only for an assistant message while it streams.
    case messageUpdate(AgentMessage, event: AssistantMessageEvent)
    case messageEnd(AgentMessage)
    case toolExecutionStart(toolCallId: String, toolName: String, arguments: JSONObject)
    case toolExecutionUpdate(toolCallId: String, toolName: String, arguments: JSONObject, partialResult: AgentToolResult)
    case toolExecutionEnd(toolCallId: String, toolName: String, result: AgentToolResult, isError: Bool, durationMs: Int?)
}
