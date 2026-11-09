import Foundation
import PiAI

/// The agent's state between and during runs.
public struct AgentState: Sendable {
    /// The transcript; its system messages carry the prompt and tool declarations.
    public var messages: [AgentMessage]
    /// Tools the agent can execute. Differences from the declared tools are announced before the next request.
    public var tools: [AgentTool]
    public var model: Model
    public var thinkingLevel: ThinkingLevel
    public internal(set) var isStreaming = false
    /// The assistant message streaming now, if any.
    public internal(set) var streamingMessage: AgentMessage?
    /// Ids of tool calls running now.
    public internal(set) var pendingToolCalls: Set<String> = []
    /// From the most recent failed or aborted response.
    public internal(set) var errorMessage: String?

    /// The current system prompt, replayed from the transcript.
    public var systemPrompt: String {
        getCurrentSystemPrompt(messages.compactMap(\.message))
    }
}

public enum AgentError: Error, LocalizedError {
    case busy
    case nothingToContinue

    public var errorDescription: String? {
        switch self {
        case .busy: "The agent is already processing. Use steer() or followUp() to queue messages, or wait for it to finish."
        case .nothingToContinue: "No messages to continue from"
        }
    }
}

/// A conversation with an agent: owns the transcript, runs the loop, executes tools and queues messages sent while it
/// works. Observe it through `events()`.
public actor Agent {
    public private(set) var state: AgentState

    /// Hooks and options for every run; see `AgentLoopConfig`.
    public var streamOptions: StreamOptions
    public var convertToLlm: @Sendable ([AgentMessage]) async -> [Message]
    public var transformContext: (@Sendable ([AgentMessage]) async -> [AgentMessage])?
    public var getApiKey: (@Sendable (String) async -> String?)?
    public var beforeToolCall: (@Sendable (BeforeToolCallContext) async -> BeforeToolCallResult?)?
    public var afterToolCall: (@Sendable (AfterToolCallContext) async -> AfterToolCallResult?)?
    public var finishTurn: (@Sendable (AgentTurnContext) async -> AgentTurnDecision?)?
    public var prepareRequest: (@Sendable (PrepareRequestContext) async -> AgentLoopTurnUpdate?)?
    public var prepareNextTurn: (@Sendable (AgentTurnContext) async -> AgentLoopTurnUpdate?)?
    public var toolExecution: ToolExecutionMode
    public var steeringMode: QueueMode
    public var followUpMode: QueueMode
    public var streamFunction: StreamFunction

    private var steeringQueue: [AgentMessage] = []
    private var followUpQueue: [AgentMessage] = []
    private var listeners: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]
    private var activeRun: Task<Void, Never>?

    /// `systemPrompt` and `tools` become the leading system message unless `messages` already starts with one.
    public init(
        model: Model,
        systemPrompt: String = "",
        tools: [AgentTool] = [],
        messages: [AgentMessage] = [],
        thinkingLevel: ThinkingLevel = .off,
        streamOptions: StreamOptions = StreamOptions(),
        toolExecution: ToolExecutionMode = .parallel,
        steeringMode: QueueMode = .oneAtATime,
        followUpMode: QueueMode = .oneAtATime,
        convertToLlm: @escaping @Sendable ([AgentMessage]) async -> [Message] = defaultConvertToLlm,
        streamFunction: @escaping StreamFunction = defaultStreamFunction
    ) {
        var transcript = messages
        if !(transcript.first?.isSystem ?? false),
           let initial = createInitialSystemMessage(systemPrompt: systemPrompt, tools: tools.map(\.declaration))
        {
            transcript.insert(.llm(.system(initial)), at: 0)
        }
        state = AgentState(messages: transcript, tools: tools, model: model, thinkingLevel: thinkingLevel)
        self.streamOptions = streamOptions
        self.toolExecution = toolExecution
        self.steeringMode = steeringMode
        self.followUpMode = followUpMode
        self.convertToLlm = convertToLlm
        self.streamFunction = streamFunction
    }

    // MARK: Configuration

    public func setModel(_ model: Model) { state.model = model }
    public func setThinkingLevel(_ level: ThinkingLevel) { state.thinkingLevel = level }
    public func setTools(_ tools: [AgentTool]) { state.tools = tools }
    public func setStreamOptions(_ options: StreamOptions) { streamOptions = options }

    /// Replaces the transcript. Not while a run is active.
    public func setMessages(_ messages: [AgentMessage]) throws {
        guard activeRun == nil else { throw AgentError.busy }
        state.messages = messages
    }

    public func configure(_ body: @Sendable (isolated Agent) -> Void) {
        body(self)
    }

    // MARK: Events

    /// Every event from now on, in order. The stream finishes when the caller stops iterating.
    public func events() -> AsyncStream<AgentEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: AgentEvent.self, bufferingPolicy: .unbounded)
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(id) }
        }
        return stream
    }

    private func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    // MARK: Queues

    /// Queues a message to inject after the current tool batch.
    public func steer(_ message: AgentMessage) { steeringQueue.append(message) }
    /// Queues a message to run once the agent would otherwise stop.
    public func followUp(_ message: AgentMessage) { followUpQueue.append(message) }
    public func clearQueues() {
        steeringQueue = []
        followUpQueue = []
    }

    public var hasQueuedMessages: Bool { !steeringQueue.isEmpty || !followUpQueue.isEmpty }

    private func drainSteering() -> [AgentMessage] { drain(&steeringQueue, mode: steeringMode) }
    private func drainFollowUps() -> [AgentMessage] { drain(&followUpQueue, mode: followUpMode) }

    private func drain(_ queue: inout [AgentMessage], mode: QueueMode) -> [AgentMessage] {
        switch mode {
        case .all:
            defer { queue = [] }
            return queue
        case .oneAtATime:
            guard !queue.isEmpty else { return [] }
            return [queue.removeFirst()]
        }
    }

    // MARK: Runs

    public var isRunning: Bool { activeRun != nil }

    /// Aborts the current run: the streaming response ends as `aborted` and running tools are cancelled.
    public func abort() {
        activeRun?.cancel()
    }

    /// Waits until the current run has finished.
    public func waitForIdle() async {
        await activeRun?.value
    }

    /// Clears the conversation and queues, keeping the replayed prompt and tool baseline.
    public func reset() throws {
        guard activeRun == nil else { throw AgentError.busy }
        let messages = state.messages.compactMap(\.message)
        state.messages = getCurrentSystemMessage(messages).map { [.llm(.system($0))] } ?? []
        state.streamingMessage = nil
        state.pendingToolCalls = []
        state.errorMessage = nil
        clearQueues()
    }

    /// Sends a user message and runs until the agent stops.
    public func prompt(_ text: String, images: [ImageContent] = []) async throws {
        try await prompt([.user(text, images: images)])
    }

    /// Runs with new messages added to the transcript.
    public func prompt(_ messages: [AgentMessage]) async throws {
        guard activeRun == nil else { throw AgentError.busy }
        await run(prompts: messages)
    }

    /// Continues from the transcript: retries after a failure, or picks up queued messages.
    public func continueRun() async throws {
        guard activeRun == nil else { throw AgentError.busy }
        guard let last = state.messages.last, !state.messages.allSatisfy(\.isSystem) else { throw AgentError.nothingToContinue }
        if last.assistant != nil {
            let steering = drainSteering()
            if !steering.isEmpty {
                await run(prompts: steering, skipInitialSteeringPoll: true)
                return
            }
            let followUps = drainFollowUps()
            if !followUps.isEmpty {
                await run(prompts: followUps)
                return
            }
            throw AgentLoopError.cannotContinueFromAssistant
        }
        await run(prompts: nil)
    }

    private func run(prompts: [AgentMessage]?, skipInitialSteeringPoll: Bool = false) async {
        state.isStreaming = true
        state.streamingMessage = nil
        state.errorMessage = nil

        let context = AgentContext(messages: state.messages, tools: state.tools)
        let config = loopConfig(skipInitialSteeringPoll: skipInitialSteeringPoll)
        let streamFunction = streamFunction
        let model = state.model
        let emit: AgentEventSink = { [weak self] event in await self?.process(event) }

        let task = Task {
            do {
                if let prompts {
                    _ = await runAgentLoop(prompts: prompts, context: context, config: config, emit: emit, streamFunction: streamFunction)
                } else {
                    _ = try await runAgentLoopContinue(context: context, config: config, emit: emit, streamFunction: streamFunction)
                }
            } catch {
                let failure = AgentMessage.llm(.assistant(AssistantMessage(
                    content: [.text(TextContent(text: ""))],
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    stopReason: Task.isCancelled ? .aborted : .error,
                    errorMessage: error.localizedDescription
                )))
                await emit(.messageStart(failure))
                await emit(.messageEnd(failure))
                await emit(.turnEnd(message: failure, toolResults: []))
                await emit(.agentEnd(messages: [failure]))
            }
        }
        activeRun = task
        await task.value
        activeRun = nil
        state.isStreaming = false
        state.streamingMessage = nil
        state.pendingToolCalls = []
    }

    private func loopConfig(skipInitialSteeringPoll: Bool) -> AgentLoopConfig {
        let skipFlag = SkipFlag(skip: skipInitialSteeringPoll)
        return AgentLoopConfig(
            model: state.model,
            reasoning: state.thinkingLevel == .off ? nil : state.thinkingLevel,
            streamOptions: streamOptions,
            convertToLlm: convertToLlm,
            transformContext: transformContext,
            getApiKey: getApiKey,
            finishTurn: finishTurn,
            prepareRequest: prepareRequest,
            prepareNextTurn: prepareNextTurn,
            getSteeringMessages: { [weak self] in
                if await skipFlag.consume() { return [] }
                return await self?.drainSteering() ?? []
            },
            getFollowUpMessages: { [weak self] in await self?.drainFollowUps() ?? [] },
            toolExecution: toolExecution,
            beforeToolCall: beforeToolCall,
            afterToolCall: afterToolCall
        )
    }

    /// Updates state for a loop event, then hands it to listeners.
    private func process(_ event: AgentEvent) {
        switch event {
        case let .messageStart(message), let .messageUpdate(message, _):
            state.streamingMessage = message
        case let .messageEnd(message):
            state.streamingMessage = nil
            state.messages.append(message)
        case let .toolExecutionStart(id, _, _):
            state.pendingToolCalls.insert(id)
        case let .toolExecutionEnd(id, _, _, _, _):
            state.pendingToolCalls.remove(id)
        case let .turnEnd(message, _):
            if let error = message.assistant?.errorMessage { state.errorMessage = error }
        case .agentEnd:
            state.streamingMessage = nil
        default:
            break
        }
        for continuation in listeners.values {
            continuation.yield(event)
        }
    }
}

/// Skips the first steering poll of a run that starts from already-drained steering messages.
private actor SkipFlag {
    private var skip: Bool

    init(skip: Bool) {
        self.skip = skip
    }

    func consume() -> Bool {
        defer { skip = false }
        return skip
    }
}
