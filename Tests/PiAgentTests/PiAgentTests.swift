import Foundation
import PiAgent
import PiAI
import Synchronization
import Testing

let testModel = Model(id: "faux", provider: "faux", baseURL: "https://faux.test")

/// A stream function that replays scripted responses and records what it was asked.
final class FauxProvider: Sendable {
    private let state: Mutex<(responses: [AssistantMessage], contexts: [TranscriptContext])>

    init(_ responses: [AssistantMessage]) {
        state = Mutex((responses, []))
    }

    var contexts: [TranscriptContext] { state.withLock { $0.contexts } }

    var streamFunction: StreamFunction {
        { [self] model, context, _ in
            let next = state.withLock { state -> AssistantMessage in
                state.contexts.append(context)
                return state.responses.isEmpty ? reply("(no more responses)") : state.responses.removeFirst()
            }
            let stream = AssistantMessageEventStream()
            var partial = AssistantMessage(api: model.api, provider: model.provider, model: model.id, stopReason: .pending)
            stream.push(.start(partial: partial))
            for (index, block) in next.content.enumerated() {
                partial.content.append(block)
                switch block {
                case let .text(text): stream.push(.textDelta(contentIndex: index, delta: text.text, partial: partial))
                case let .toolCall(call): stream.push(.toolCallEnd(contentIndex: index, toolCall: call, partial: partial))
                case .thinking: break
                }
            }
            if next.stopReason == .error || next.stopReason == .aborted {
                stream.push(.error(reason: next.stopReason, error: next))
            } else {
                stream.push(.done(reason: next.stopReason, message: next))
            }
            stream.end()
            return stream
        }
    }
}

func resultText(_ result: ToolResultMessage?) -> String {
    contentText(result?.content ?? [])
}

func reply(_ text: String) -> AssistantMessage {
    AssistantMessage(content: [.text(TextContent(text: text))], api: "faux", provider: "faux", model: "faux", stopReason: .stop)
}

func callTools(_ calls: [ToolCall]) -> AssistantMessage {
    AssistantMessage(content: calls.map(AssistantContent.toolCall), api: "faux", provider: "faux", model: "faux", stopReason: .toolUse)
}

func echoTool(delay: Duration = .zero) -> AgentTool {
    AgentTool(name: "echo", description: "Echo text", parameters: ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]) { _, arguments, onUpdate in
        let text = arguments["text"]?.stringValue ?? ""
        await onUpdate(AgentToolResult(text: "working"))
        if delay > .zero { try await Task.sleep(for: delay) }
        return AgentToolResult(text: "echo: \(text)")
    }
}

final class EventLog: Sendable {
    let events = Mutex<[String]>([])

    var sink: AgentEventSink {
        { [self] event in
            let name = switch event {
            case .agentStart: "agent_start"
            case .agentEnd: "agent_end"
            case .turnStart: "turn_start"
            case .turnEnd: "turn_end"
            case let .messageStart(message): "message_start:\(message.role)"
            case .messageUpdate: "message_update"
            case let .messageEnd(message): "message_end:\(message.role)"
            case .toolExecutionStart: "tool_start"
            case .toolExecutionUpdate: "tool_update"
            case .toolExecutionEnd: "tool_end"
            }
            events.withLock { $0.append(name) }
        }
    }
}

@Suite struct AgentLoopTests {
    @Test func runsToolsAndFinishes() async {
        let provider = FauxProvider([
            callTools([ToolCall(id: "1", name: "echo", arguments: ["text": "a"]), ToolCall(id: "2", name: "echo", arguments: ["text": "b"])]),
            reply("done"),
        ])
        let log = EventLog()
        let messages = await runAgentLoop(
            prompts: [.user("go")],
            context: AgentContext(messages: [], tools: [echoTool()]),
            config: AgentLoopConfig(model: testModel),
            emit: log.sink,
            streamFunction: provider.streamFunction
        )
        // system (tool declaration) + user + assistant + 2 results + assistant
        #expect(messages.map(\.role) == ["system", "user", "assistant", "toolResult", "toolResult", "assistant"])
        if case let .llm(.toolResult(result)) = messages[3] {
            #expect(contentText(result.content) == "echo: a")
            #expect(result.toolCallId == "1")
        }
        let events = log.events.withLock { $0 }
        #expect(events.first == "agent_start")
        #expect(events.last == "agent_end")
        #expect(events.filter { $0 == "tool_end" }.count == 2)
        #expect(events.contains("tool_update"))
        // The second request carries the tool results.
        #expect(provider.contexts.count == 2)
        #expect(provider.contexts[1].messages.map(\.role) == ["system", "user", "assistant", "toolResult", "toolResult"])
        // The tool was declared to the model.
        #expect(getCurrentTools(provider.contexts[0].messages).map(\.name) == ["echo"])
    }

    @Test func runsToolCallsInParallel() async {
        let log = Mutex<[String]>([])
        let provider = FauxProvider([
            callTools([ToolCall(id: "1", name: "echo", arguments: ["text": "slow"]), ToolCall(id: "2", name: "echo", arguments: ["text": "fast"])]),
            reply("done"),
        ])
        let slowFirst = AgentTool(name: "echo", description: "", parameters: ["type": "object"]) { _, arguments, _ in
            let text = arguments["text"]?.stringValue ?? ""
            log.withLock { $0.append("start \(text)") }
            if text == "slow" { try await Task.sleep(for: .milliseconds(100)) }
            log.withLock { $0.append("end \(text)") }
            return AgentToolResult(text: text)
        }
        let messages = await runAgentLoop(prompts: [.user("go")], context: AgentContext(messages: [], tools: [slowFirst]), config: AgentLoopConfig(model: testModel), emit: { _ in }, streamFunction: provider.streamFunction)
        let order = log.withLock { $0 }
        #expect(order.firstIndex(of: "end fast")! < order.firstIndex(of: "end slow")!)
        // Results keep the assistant's order.
        let results = messages.compactMap { if case let .llm(.toolResult(result)) = $0 { result.toolCallId } else { nil } }
        #expect(results == ["1", "2"])
    }

    @Test func reportsUnknownToolsAndValidationErrors() async {
        let provider = FauxProvider([
            callTools([ToolCall(id: "1", name: "missing", arguments: [:]), ToolCall(id: "2", name: "echo", arguments: [:])]),
            reply("ok"),
        ])
        let messages = await runAgentLoop(prompts: [.user("go")], context: AgentContext(messages: [], tools: [echoTool()]), config: AgentLoopConfig(model: testModel), emit: { _ in }, streamFunction: provider.streamFunction)
        let results = messages.compactMap { if case let .llm(.toolResult(result)) = $0 { result } else { nil } }
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.isError })
        #expect(contentText(results[0].content) == "Tool missing not found")
        #expect(contentText(results[1].content).contains("required property 'text'"))
    }

    @Test func beforeToolCallCanBlock() async {
        let provider = FauxProvider([callTools([ToolCall(id: "1", name: "echo", arguments: ["text": "x"])]), reply("ok")])
        let config = AgentLoopConfig(model: testModel, beforeToolCall: { _ in BeforeToolCallResult(block: true, reason: "Denied by user") })
        let messages = await runAgentLoop(prompts: [.user("go")], context: AgentContext(messages: [], tools: [echoTool()]), config: config, emit: { _ in }, streamFunction: provider.streamFunction)
        let result = messages.compactMap { if case let .llm(.toolResult(result)) = $0 { result } else { nil } }.first
        #expect(result?.isError == true)
        #expect(resultText(result) == "Denied by user")
    }

    @Test func failsTruncatedToolCalls() async {
        var truncated = callTools([ToolCall(id: "1", name: "echo", arguments: ["text": "x"])])
        truncated.stopReason = .length
        let provider = FauxProvider([truncated, reply("ok")])
        let messages = await runAgentLoop(prompts: [.user("go")], context: AgentContext(messages: [], tools: [echoTool()]), config: AgentLoopConfig(model: testModel), emit: { _ in }, streamFunction: provider.streamFunction)
        let result = messages.compactMap { if case let .llm(.toolResult(result)) = $0 { result } else { nil } }.first
        #expect(resultText(result).contains("output token limit"))
    }

    @Test func stopsOnProviderError() async {
        var failure = reply("")
        failure.stopReason = .error
        failure.errorMessage = "boom"
        let provider = FauxProvider([failure])
        let log = EventLog()
        let messages = await runAgentLoop(prompts: [.user("go")], context: AgentContext(messages: []), config: AgentLoopConfig(model: testModel), emit: log.sink, streamFunction: provider.streamFunction)
        #expect(messages.last?.assistant?.errorMessage == "boom")
        #expect(log.events.withLock { $0.last } == "agent_end")
    }

    @Test func announcesToolChangesMidConversation() async {
        let provider = FauxProvider([reply("ok")])
        let previous: [AgentMessage] = [
            .llm(.system(SystemMessage(content: "Prompt", toolsAdded: [Tool(name: "old", description: "", parameters: [:])], timestamp: 0))),
        ]
        let messages = await runAgentLoop(prompts: [.user("go")], context: AgentContext(messages: previous, tools: [echoTool()]), config: AgentLoopConfig(model: testModel), emit: { _ in }, streamFunction: provider.streamFunction)
        guard case let .llm(.system(update)) = messages.first else {
            Issue.record("Expected a tool update first")
            return
        }
        #expect(update.toolsAdded?.map(\.name) == ["echo"])
        #expect(update.toolsRemoved?.map(\.name) == ["old"])
        #expect(messages[1].role == "user")
    }
}

@Suite struct AgentTests {
    @Test func promptUpdatesStateAndEvents() async throws {
        let provider = FauxProvider([callTools([ToolCall(id: "1", name: "echo", arguments: ["text": "x"])]), reply("all done")])
        let agent = Agent(model: testModel, systemPrompt: "Be helpful", tools: [echoTool()], streamFunction: provider.streamFunction)
        let events = await agent.events()
        let collector = Task {
            var names: [String] = []
            for await event in events {
                if case .agentEnd = event {
                    names.append("end")
                    break
                }
                if case .toolExecutionEnd = event { names.append("tool") }
            }
            return names
        }
        try await agent.prompt("hello")
        let state = await agent.state
        #expect(state.messages.map(\.role) == ["system", "user", "assistant", "toolResult", "assistant"])
        #expect(state.messages.last?.assistant?.text == "all done")
        #expect(state.systemPrompt == "Be helpful")
        #expect(!state.isStreaming)
        #expect(await collector.value == ["tool", "end"])
    }

    @Test func steeringMessagesJoinTheRun() async throws {
        let provider = FauxProvider([callTools([ToolCall(id: "1", name: "echo", arguments: ["text": "x"])]), reply("first"), reply("second")])
        let agent = Agent(model: testModel, tools: [echoTool(delay: .milliseconds(100))], streamFunction: provider.streamFunction)
        let run = Task { try await agent.prompt("start") }
        try await Task.sleep(for: .milliseconds(30))
        await agent.steer(.user("also this"))
        try await run.value
        let roles = await agent.state.messages.map(\.role)
        // The steering message lands after the tool result, before the next request.
        #expect(roles == ["system", "user", "assistant", "toolResult", "user", "assistant"])
        #expect(provider.contexts.count == 2)
    }

    @Test func followUpsRunAfterTheAgentStops() async throws {
        let provider = FauxProvider([reply("first"), reply("second")])
        let agent = Agent(model: testModel, streamFunction: provider.streamFunction)
        await agent.followUp(.user("then this"))
        try await agent.prompt("start")
        let texts = await agent.state.messages.compactMap { $0.assistant?.text }
        #expect(texts == ["first", "second"])
    }

    @Test func abortStopsRunningTools() async throws {
        let provider = FauxProvider([callTools([ToolCall(id: "1", name: "echo", arguments: ["text": "x"])]), reply("never")])
        let agent = Agent(model: testModel, tools: [echoTool(delay: .seconds(5))], streamFunction: provider.streamFunction)
        let run = Task { try await agent.prompt("start") }
        try await Task.sleep(for: .milliseconds(50))
        await agent.abort()
        try await run.value
        let messages = await agent.state.messages
        let result = messages.compactMap { if case let .llm(.toolResult(result)) = $0 { result } else { nil } }.first
        #expect(result?.isError == true)
        #expect(resultText(result) == "Operation aborted")
        #expect(await !agent.isRunning)
    }

    @Test func rejectsConcurrentPrompts() async throws {
        let provider = FauxProvider([callTools([ToolCall(id: "1", name: "echo", arguments: ["text": "x"])]), reply("ok")])
        let agent = Agent(model: testModel, tools: [echoTool(delay: .milliseconds(100))], streamFunction: provider.streamFunction)
        let run = Task { try await agent.prompt("one") }
        try await Task.sleep(for: .milliseconds(20))
        await #expect(throws: AgentError.self) { try await agent.prompt("two") }
        try await run.value
    }

    @Test func transcriptRoundTrips() async throws {
        let provider = FauxProvider([reply("hi")])
        let agent = Agent(model: testModel, systemPrompt: "P", streamFunction: provider.streamFunction)
        try await agent.prompt("hello")
        let messages = await agent.state.messages + [.custom(CustomAgentMessage(kind: "note", payload: ["x": 1]))]
        let data = try JSONEncoder().encode(messages)
        let decoded = try JSONDecoder().decode([AgentMessage].self, from: data)
        #expect(decoded == messages)
    }
}
