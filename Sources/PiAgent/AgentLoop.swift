import Foundation
import PiAI

/// Receives a run's events in order; the loop awaits each one.
public typealias AgentEventSink = @Sendable (AgentEvent) async -> Void

/// Streams through the provider for the model's API.
public let defaultStreamFunction: StreamFunction = { model, context, options in
    streamSimple(model: model, context: context, options: options)
}

/// Runs the agent loop with new prompt messages added to the context. Returns every message the run added.
///
/// Cancel the calling task to abort: the current response ends as `aborted` and the run ends.
public func runAgentLoop(
    prompts: [AgentMessage],
    context: AgentContext,
    config: AgentLoopConfig,
    emit: @escaping AgentEventSink,
    streamFunction: StreamFunction = defaultStreamFunction
) async -> [AgentMessage] {
    let initial = declareToolChanges(context: context, pending: prompts)
    var newMessages = initial
    var current = context
    current.messages += initial

    await emit(.agentStart)
    await emit(.turnStart)
    for message in initial {
        await emit(.messageStart(message))
        await emit(.messageEnd(message))
    }
    await runLoop(context: current, newMessages: &newMessages, config: config, emit: emit, streamFunction: streamFunction)
    return newMessages
}

public enum AgentLoopError: Error, LocalizedError {
    case noMessages
    case cannotContinueFromAssistant

    public var errorDescription: String? {
        switch self {
        case .noMessages: "Cannot continue: no messages in context"
        case .cannotContinueFromAssistant: "Cannot continue from message role: assistant"
        }
    }
}

/// Continues from the current context without adding a message, such as to retry. The last message must convert to a
/// user or tool result message.
public func runAgentLoopContinue(
    context: AgentContext,
    config: AgentLoopConfig,
    emit: @escaping AgentEventSink,
    streamFunction: StreamFunction = defaultStreamFunction
) async throws -> [AgentMessage] {
    guard let last = context.messages.last else { throw AgentLoopError.noMessages }
    if last.assistant != nil { throw AgentLoopError.cannotContinueFromAssistant }

    var newMessages: [AgentMessage] = []
    await emit(.agentStart)
    await emit(.turnStart)
    await runLoop(context: context, newMessages: &newMessages, config: config, emit: emit, streamFunction: streamFunction)
    return newMessages
}

private func runLoop(
    context initialContext: AgentContext,
    newMessages: inout [AgentMessage],
    config initialConfig: AgentLoopConfig,
    emit: @escaping AgentEventSink,
    streamFunction: StreamFunction
) async {
    var context = initialContext
    var config = initialConfig
    var lastCompletedTurn: AgentTurnContext?
    var explicitContinuation = false
    // Messages the user typed while waiting.
    var pending = await config.getSteeringMessages?() ?? []

    // Outer loop: continues when follow-up messages arrive after the agent would stop.
    while true {
        var hasMoreToolCalls = true

        // Inner loop: tool calls and steering messages.
        while hasMoreToolCalls || !pending.isEmpty {
            var prepared: [AgentMessage] = []
            if let turn = lastCompletedTurn {
                if let update = await config.prepareNextTurn?(turn) {
                    context = update.context ?? context
                    prepared = update.messages ?? []
                    apply(update, to: &config)
                }
                // Preparation can take long (compaction); pick up steering queued meanwhile.
                if pending.isEmpty {
                    pending = await config.getSteeringMessages?() ?? []
                }
                await emit(.turnStart)
            }

            for message in declareToolChanges(context: context, pending: prepared + pending) {
                await emit(.messageStart(message))
                await emit(.messageEnd(message))
                context.messages.append(message)
                newMessages.append(message)
            }
            pending = []

            if let update = await config.prepareRequest?(PrepareRequestContext(context: context, model: config.model, thinkingLevel: config.reasoning ?? .off)) {
                context = update.context ?? context
                apply(update, to: &config)
            }

            let message = await streamAssistantResponse(context: &context, config: config, emit: emit, streamFunction: streamFunction)
            newMessages.append(.llm(.assistant(message)))

            if message.stopReason == .error || message.stopReason == .aborted {
                let turn = AgentTurnContext(message: message, toolResults: [], context: context, newMessages: newMessages)
                _ = await config.finishTurn?(turn)
                await emit(.turnEnd(message: .llm(.assistant(message)), toolResults: []))
                await emit(.agentEnd(messages: newMessages))
                return
            }

            let toolCalls = message.toolCalls
            var toolResults: [ToolResultMessage] = []
            hasMoreToolCalls = false
            if !toolCalls.isEmpty {
                // Output cut off by the token limit may have truncated every call's arguments: fail them all.
                let batch = message.stopReason == .length
                    ? await failTruncatedToolCalls(toolCalls, emit: emit)
                    : await executeToolCalls(context: context, assistantMessage: message, config: config, emit: emit)
                toolResults = batch.messages
                hasMoreToolCalls = !batch.terminate
                for result in toolResults {
                    context.messages.append(.llm(.toolResult(result)))
                    newMessages.append(.llm(.toolResult(result)))
                }
            }

            let turn = AgentTurnContext(message: message, toolResults: toolResults, context: context, newMessages: newMessages)
            lastCompletedTurn = turn
            let decision = await config.finishTurn?(turn)
            await emit(.turnEnd(message: .llm(.assistant(message)), toolResults: toolResults))

            if case .end = decision {
                await emit(.agentEnd(messages: newMessages))
                return
            }
            explicitContinuation = if case .continue = decision { true } else { false }
            pending = await config.getSteeringMessages?() ?? []
            if hasMoreToolCalls || !pending.isEmpty {
                explicitContinuation = false
            }
        }

        // The agent would stop here.
        let followUps = await config.getFollowUpMessages?() ?? []
        if !followUps.isEmpty {
            explicitContinuation = false
            pending = followUps
            continue
        }
        if explicitContinuation {
            // One context-only turn for a `continue` decision no request satisfied.
            explicitContinuation = false
            continue
        }
        break
    }

    await emit(.agentEnd(messages: newMessages))
}

private func apply(_ update: AgentLoopTurnUpdate, to config: inout AgentLoopConfig) {
    if let model = update.model { config.model = model }
    if let level = update.thinkingLevel { config.reasoning = level == .off ? nil : level }
}

/// Announces tool changes to the model.
///
/// `context.tools` is what the runtime can execute; the transcript's system messages declare what the model may call.
/// Before each request the difference becomes `toolsAdded`/`toolsRemoved` on a system message: the last pending system
/// message if there is one, otherwise a new one before the first non-system pending message.
func declareToolChanges(context: AgentContext, pending: [AgentMessage]) -> [AgentMessage] {
    let systemIndex = pending.lastIndex(where: \.isSystem)
    var baseline = pending
    if let systemIndex, case var .llm(.system(system)) = pending[systemIndex] {
        system.toolsAdded = nil
        system.toolsRemoved = nil
        baseline[systemIndex] = .llm(.system(system))
    }
    let transcript = (context.messages + baseline).compactMap(\.message)
    let changes = getToolStateChanges(previous: getCurrentTools(transcript), current: context.tools.map(\.declaration))

    if let systemIndex, case let .llm(.system(original)) = pending[systemIndex] {
        if changes.isEmpty, (original.toolsAdded ?? []).isEmpty, (original.toolsRemoved ?? []).isEmpty { return pending }
        var updated = original
        updated.toolsAdded = changes.toolsAdded.isEmpty ? nil : changes.toolsAdded
        updated.toolsRemoved = changes.toolsRemoved.isEmpty ? nil : changes.toolsRemoved
        var result = baseline
        result[systemIndex] = .llm(.system(updated))
        return result
    }
    if changes.isEmpty { return pending }
    let update = AgentMessage.llm(.system(SystemMessage(
        content: "",
        toolsAdded: changes.toolsAdded.isEmpty ? nil : changes.toolsAdded,
        toolsRemoved: changes.toolsRemoved.isEmpty ? nil : changes.toolsRemoved
    )))
    var result = pending
    result.insert(update, at: pending.firstIndex(where: { !$0.isSystem }) ?? pending.count)
    return result
}

/// Streams one response. Agent messages become model messages only here.
private func streamAssistantResponse(
    context: inout AgentContext,
    config: AgentLoopConfig,
    emit: @escaping AgentEventSink,
    streamFunction: StreamFunction
) async -> AssistantMessage {
    var messages = context.messages
    if let transform = config.transformContext {
        messages = await transform(messages)
    }
    let llmMessages = await config.convertToLlm(messages)

    var options = config.streamOptions
    options.reasoning = config.reasoning
    if let resolved = await config.getApiKey?(config.model.provider) {
        options.apiKey = resolved
    }
    let response = await streamFunction(config.model, TranscriptContext(transcript: llmMessages), options)

    var addedPartial = false
    func stampLevel(_ message: AssistantMessage) -> AssistantMessage {
        var message = message
        message.thinkingLevel = config.reasoning ?? .off
        return message
    }

    for await event in response {
        switch event {
        case let .start(partial):
            context.messages.append(.llm(.assistant(partial)))
            addedPartial = true
            await emit(.messageStart(.llm(.assistant(partial))))
        case .textStart, .textDelta, .textEnd, .thinkingStart, .thinkingDelta, .thinkingEnd, .toolCallStart, .toolCallDelta, .toolCallEnd:
            guard addedPartial else { continue }
            let partial = AgentMessage.llm(.assistant(event.message))
            context.messages[context.messages.count - 1] = partial
            await emit(.messageUpdate(partial, event: event))
        case .done, .error:
            let final = stampLevel(await response.result())
            if addedPartial {
                context.messages[context.messages.count - 1] = .llm(.assistant(final))
            } else {
                context.messages.append(.llm(.assistant(final)))
                await emit(.messageStart(.llm(.assistant(final))))
            }
            await emit(.messageEnd(.llm(.assistant(final))))
            return final
        }
    }

    // The stream ended without `done` or `error`.
    let final = stampLevel(await response.result())
    if addedPartial {
        context.messages[context.messages.count - 1] = .llm(.assistant(final))
    } else {
        context.messages.append(.llm(.assistant(final)))
        await emit(.messageStart(.llm(.assistant(final))))
    }
    await emit(.messageEnd(.llm(.assistant(final))))
    return final
}

private struct ToolBatch {
    var messages: [ToolResultMessage]
    var terminate: Bool
}

private struct ToolOutcome: Sendable {
    var toolCall: AgentToolCall
    var result: AgentToolResult
    var isError: Bool
    var durationMs: Int?
}

private func failTruncatedToolCalls(_ toolCalls: [AgentToolCall], emit: @escaping AgentEventSink) async -> ToolBatch {
    var messages: [ToolResultMessage] = []
    for call in toolCalls {
        await emit(.toolExecutionStart(toolCallId: call.id, toolName: call.name, arguments: call.arguments))
        let outcome = ToolOutcome(
            toolCall: call,
            result: .error("Tool call \"\(call.name)\" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments."),
            isError: true
        )
        await emit(.toolExecutionEnd(toolCallId: call.id, toolName: call.name, result: outcome.result, isError: true, durationMs: nil))
        let message = toolResultMessage(outcome)
        await emit(.messageStart(.llm(.toolResult(message))))
        await emit(.messageEnd(.llm(.toolResult(message))))
        messages.append(message)
    }
    return ToolBatch(messages: messages, terminate: false)
}

private func executeToolCalls(context: AgentContext, assistantMessage: AssistantMessage, config: AgentLoopConfig, emit: @escaping AgentEventSink) async -> ToolBatch {
    let toolCalls = assistantMessage.toolCalls
    let hasSequentialTool = toolCalls.contains { call in context.tools.first { $0.name == call.name }?.executionMode == .sequential }
    if config.toolExecution == .sequential || hasSequentialTool {
        return await executeSequentially(context: context, assistantMessage: assistantMessage, toolCalls: toolCalls, config: config, emit: emit)
    }
    return await executeInParallel(context: context, assistantMessage: assistantMessage, toolCalls: toolCalls, config: config, emit: emit)
}

private func executeSequentially(context: AgentContext, assistantMessage: AssistantMessage, toolCalls: [AgentToolCall], config: AgentLoopConfig, emit: @escaping AgentEventSink) async -> ToolBatch {
    var outcomes: [ToolOutcome] = []
    var messages: [ToolResultMessage] = []
    for call in toolCalls {
        await emit(.toolExecutionStart(toolCallId: call.id, toolName: call.name, arguments: call.arguments))
        let outcome: ToolOutcome
        switch await prepareToolCall(context: context, assistantMessage: assistantMessage, toolCall: call, hooks: config) {
        case let .immediate(result, isError):
            outcome = ToolOutcome(toolCall: call, result: result, isError: isError)
        case let .prepared(tool, arguments):
            let executed = await executePrepared(tool: tool, toolCall: call, arguments: arguments, emit: emit)
            outcome = await finalize(context: context, assistantMessage: assistantMessage, toolCall: call, arguments: arguments, executed: executed, hooks: config)
        }
        await emit(.toolExecutionEnd(toolCallId: call.id, toolName: call.name, result: outcome.result, isError: outcome.isError, durationMs: outcome.durationMs))
        let message = toolResultMessage(outcome)
        await emit(.messageStart(.llm(.toolResult(message))))
        await emit(.messageEnd(.llm(.toolResult(message))))
        outcomes.append(outcome)
        messages.append(message)
        if Task.isCancelled { break }
    }
    return ToolBatch(messages: messages, terminate: shouldTerminate(outcomes))
}

private func executeInParallel(context: AgentContext, assistantMessage: AssistantMessage, toolCalls: [AgentToolCall], config: AgentLoopConfig, emit: @escaping AgentEventSink) async -> ToolBatch {
    // Prepare in order (hooks such as permission prompts run one at a time), then run the allowed calls together.
    var outcomes: [ToolOutcome?] = Array(repeating: nil, count: toolCalls.count)
    var prepared: [(index: Int, tool: AgentTool, arguments: JSONObject)] = []
    for (index, call) in toolCalls.enumerated() {
        await emit(.toolExecutionStart(toolCallId: call.id, toolName: call.name, arguments: call.arguments))
        switch await prepareToolCall(context: context, assistantMessage: assistantMessage, toolCall: call, hooks: config) {
        case let .immediate(result, isError):
            let outcome = ToolOutcome(toolCall: call, result: result, isError: isError)
            await emit(.toolExecutionEnd(toolCallId: call.id, toolName: call.name, result: result, isError: isError, durationMs: nil))
            outcomes[index] = outcome
        case let .prepared(tool, arguments):
            prepared.append((index, tool, arguments))
        }
        if Task.isCancelled { break }
    }

    await withTaskGroup(of: (Int, ToolOutcome).self) { group in
        for entry in prepared {
            let call = toolCalls[entry.index]
            group.addTask {
                if Task.isCancelled {
                    let outcome = ToolOutcome(toolCall: call, result: .error("Operation aborted"), isError: true)
                    await emit(.toolExecutionEnd(toolCallId: call.id, toolName: call.name, result: outcome.result, isError: true, durationMs: nil))
                    return (entry.index, outcome)
                }
                let executed = await executePrepared(tool: entry.tool, toolCall: call, arguments: entry.arguments, emit: emit)
                let outcome = await finalize(context: context, assistantMessage: assistantMessage, toolCall: call, arguments: entry.arguments, executed: executed, hooks: config)
                await emit(.toolExecutionEnd(toolCallId: call.id, toolName: call.name, result: outcome.result, isError: outcome.isError, durationMs: outcome.durationMs))
                return (entry.index, outcome)
            }
        }
        for await (index, outcome) in group {
            outcomes[index] = outcome
        }
    }

    // Results in the assistant's order.
    let ordered = outcomes.compactMap(\.self)
    var messages: [ToolResultMessage] = []
    for outcome in ordered {
        let message = toolResultMessage(outcome)
        await emit(.messageStart(.llm(.toolResult(message))))
        await emit(.messageEnd(.llm(.toolResult(message))))
        messages.append(message)
    }
    return ToolBatch(messages: messages, terminate: shouldTerminate(ordered))
}

private func shouldTerminate(_ outcomes: [ToolOutcome]) -> Bool {
    !outcomes.isEmpty && outcomes.allSatisfy(\.result.terminate)
}

private enum Preparation {
    case prepared(AgentTool, JSONObject)
    case immediate(AgentToolResult, isError: Bool)
}

private func prepareToolCall(context: AgentContext, assistantMessage: AssistantMessage, toolCall: AgentToolCall, hooks: AgentLoopConfig) async -> Preparation {
    guard let tool = context.tools.first(where: { $0.name == toolCall.name }) else {
        return .immediate(.error("Tool \(toolCall.name) not found"), isError: true)
    }
    do {
        var call = toolCall
        if let prepare = tool.prepareArguments {
            call.arguments = prepare(call.arguments)
        }
        let arguments = try validateToolArguments(tool: tool.declaration, toolCall: call)
        if let before = hooks.beforeToolCall {
            let decision = await before(BeforeToolCallContext(assistantMessage: assistantMessage, toolCall: toolCall, arguments: arguments, context: context))
            if Task.isCancelled { return .immediate(.error("Operation aborted"), isError: true) }
            if let decision, decision.block {
                var result = AgentToolResult.error(decision.reason ?? "Tool execution was blocked")
                result.terminate = decision.terminate
                return .immediate(result, isError: true)
            }
        }
        if Task.isCancelled { return .immediate(.error("Operation aborted"), isError: true) }
        return .prepared(tool, arguments)
    } catch {
        return .immediate(.error(error.localizedDescription), isError: true)
    }
}

private func executePrepared(tool: AgentTool, toolCall: AgentToolCall, arguments: JSONObject, emit: @escaping AgentEventSink) async -> ToolOutcome {
    let started = ContinuousClock.now
    func elapsed() -> Int {
        let duration = ContinuousClock.now - started
        return Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
    do {
        let result = try await tool.execute(toolCall.id, arguments) { partial in
            await emit(.toolExecutionUpdate(toolCallId: toolCall.id, toolName: toolCall.name, arguments: toolCall.arguments, partialResult: partial))
        }
        return ToolOutcome(toolCall: toolCall, result: result, isError: result.isError, durationMs: elapsed())
    } catch {
        let message = error is CancellationError ? "Operation aborted" : error.localizedDescription
        return ToolOutcome(toolCall: toolCall, result: .error(message), isError: true, durationMs: elapsed())
    }
}

private func finalize(context: AgentContext, assistantMessage: AssistantMessage, toolCall: AgentToolCall, arguments: JSONObject, executed: ToolOutcome, hooks: AgentLoopConfig) async -> ToolOutcome {
    guard let after = hooks.afterToolCall else { return executed }
    var outcome = executed
    if let override = await after(AfterToolCallContext(assistantMessage: assistantMessage, toolCall: toolCall, arguments: arguments, result: executed.result, isError: executed.isError, context: context)) {
        if let content = override.content { outcome.result.content = content }
        if let details = override.details { outcome.result.details = details }
        if let terminate = override.terminate { outcome.result.terminate = terminate }
        if let isError = override.isError { outcome.isError = isError }
    }
    return outcome
}

private func toolResultMessage(_ outcome: ToolOutcome) -> ToolResultMessage {
    ToolResultMessage(
        toolCallId: outcome.toolCall.id,
        toolName: outcome.toolCall.name,
        content: outcome.result.content,
        details: outcome.result.details,
        isError: outcome.isError,
        durationMs: outcome.durationMs
    )
}

/// Runs one tool call through the same steps as a model-issued call (argument preparation, validation,
/// `beforeToolCall`, execution, `afterToolCall`), without events. Tools that call other tools use this so the hooks
/// (such as permission checks) apply to those calls too. Never throws: failures come back as `isError`.
public func runToolCall(_ toolCall: AgentToolCall, tools: [AgentTool], assistantMessage: AssistantMessage, context: AgentContext, hooks: AgentLoopConfig) async -> (result: AgentToolResult, isError: Bool) {
    var context = context
    context.tools = tools
    switch await prepareToolCall(context: context, assistantMessage: assistantMessage, toolCall: toolCall, hooks: hooks) {
    case let .immediate(result, isError):
        return (result, isError)
    case let .prepared(tool, arguments):
        let executed = await executePrepared(tool: tool, toolCall: toolCall, arguments: arguments, emit: { _ in })
        let outcome = await finalize(context: context, assistantMessage: assistantMessage, toolCall: toolCall, arguments: arguments, executed: executed, hooks: hooks)
        return (outcome.result, outcome.isError)
    }
}
