import Foundation
@testable import PiAI
import Testing

@Suite struct MessageCodingTests {
    @Test func messagesRoundTripInPiShape() throws {
        let messages: [Message] = [
            .system(SystemMessage(content: "Be brief", toolsAdded: [Tool(name: "read", description: "Read", parameters: ["type": "object"])], timestamp: 0)),
            .user(UserMessage(text: "hi", timestamp: 1)),
            .assistant(AssistantMessage(
                content: [.thinking(ThinkingContent(thinking: "hmm")), .text(TextContent(text: "Hello")), .toolCall(ToolCall(id: "c1", name: "read", arguments: ["path": "a.txt"]))],
                api: "openai-completions", provider: "test", model: "m", stopReason: .toolUse, timestamp: 2
            )),
            .toolResult(ToolResultMessage(toolCallId: "c1", toolName: "read", content: [.text(TextContent(text: "data"))], isError: false, timestamp: 3)),
        ]
        let data = try JSONEncoder().encode(messages)
        let decoded = try JSONDecoder().decode([Message].self, from: data)
        #expect(decoded == messages)

        let json = try JSONValue.parse(String(decoding: data, as: UTF8.self))
        #expect(json.arrayValue?[1]["role"] == "user")
        #expect(json.arrayValue?[2]["content"]?.arrayValue?[2]["type"] == "toolCall")
        #expect(json.arrayValue?[3]["role"] == "toolResult")
    }

    @Test func decodesStringUserContent() throws {
        let message = try JSONDecoder().decode(Message.self, from: Data(#"{"role":"user","content":"plain","timestamp":5}"#.utf8))
        #expect(message == .user(UserMessage(text: "plain", timestamp: 5)))
    }
}

@Suite struct ValidationTests {
    let tool = Tool(name: "t", description: "", parameters: [
        "type": "object",
        "properties": [
            "path": ["type": "string"],
            "limit": ["type": "number"],
            "flag": ["type": "boolean"],
            "tags": ["type": "array", "items": ["type": "string"]],
            "mode": ["type": "string", "enum": ["a", "b"]],
        ],
        "required": ["path"],
    ])

    @Test func coercesSloppyArguments() throws {
        let call = ToolCall(id: "1", name: "t", arguments: ["path": "x", "limit": "42", "flag": "true", "tags": "one", "mode": .null])
        let arguments = try validateToolArguments(tool: tool, toolCall: call)
        #expect(arguments["limit"] == .number(42))
        #expect(arguments["flag"] == .bool(true))
        #expect(arguments["tags"] == ["one"])
        #expect(arguments["mode"] == nil)
    }

    @Test func reportsMissingAndInvalid() {
        let call = ToolCall(id: "1", name: "t", arguments: ["limit": "lots", "mode": "c"])
        #expect {
            try validateToolArguments(tool: tool, toolCall: call)
        } throws: { error in
            let message = (error as? ToolValidationError)?.message ?? ""
            return message.contains("limit: must be number") && message.contains("mode: must be one of") && message.contains("required property 'path'")
        }
    }

    @Test func reportsArgumentsError() {
        let call = ToolCall(id: "1", name: "t", arguments: [:], argumentsError: "bad json")
        #expect(throws: ToolValidationError.self) { try validateToolArguments(tool: tool, toolCall: call) }
    }
}

@Suite struct PartialJSONTests {
    @Test func repairsStreamingObjects() {
        #expect(parsePartialJSONObject("") == [:])
        #expect(parsePartialJSONObject(#"{"path": "a.t"#) == ["path": "a.t"])
        #expect(parsePartialJSONObject(#"{"path": "a.txt", "con"#) == ["path": "a.txt"])
        #expect(parsePartialJSONObject(#"{"path": "a.txt", "content":"#) == ["path": "a.txt"])
        #expect(parsePartialJSONObject(#"{"edits": [{"oldText": "x\"#) == ["edits": [["oldText": "x"]]])
        #expect(parsePartialJSONObject(#"{"a": 1}"#) == ["a": 1])
    }
}

@Suite struct TranscriptTests {
    @Test func replaysSystemMessagesAndTools() {
        let a = Tool(name: "a", description: "A", parameters: [:])
        let b = Tool(name: "b", description: "B", parameters: [:])
        let messages: [Message] = [
            .system(SystemMessage(content: "Base", toolsAdded: [a], timestamp: 0)),
            .user(UserMessage(text: "x")),
            .system(SystemMessage(content: "More", sections: [SystemSection(name: "s", text: "Section")], toolsAdded: [b], toolsRemoved: [ToolReference(name: "a")])),
        ]
        #expect(getCurrentTools(messages).map(\.name) == ["b"])
        #expect(getCurrentSystemPrompt(messages) == "Base\n\nMore\n\nSection")
        let collapsed = collapseSystemMessages(TranscriptContext(transcript: messages))
        #expect(collapsed.messages.count == 2)
        #expect(collapsed.messages[0].role == "system")
    }

    @Test func toolStateChanges() {
        let a = Tool(name: "a", description: "A", parameters: [:])
        let a2 = Tool(name: "a", description: "A2", parameters: [:])
        let b = Tool(name: "b", description: "B", parameters: [:])
        let changes = getToolStateChanges(previous: [a, b], current: [a2])
        #expect(changes.toolsAdded == [a2])
        #expect(changes.toolsRemoved.map(\.name) == ["a", "b"])
    }
}

@Suite struct OpenAIRequestTests {
    let model = Model(id: "gpt-x", provider: "openai", baseURL: "https://api.openai.com/v1", reasoning: true)

    @Test func buildsRequestBody() {
        let tool = Tool(name: "read", description: "Read a file", parameters: ["type": "object"])
        let context = TranscriptContext(normalizing: Context(
            systemPrompt: "You help.",
            messages: [
                .user(UserMessage(text: "read a")),
                .assistant(AssistantMessage(content: [.text(TextContent(text: "Sure")), .toolCall(ToolCall(id: "c1", name: "read", arguments: ["path": "a"]))], api: "openai-completions", provider: "openai", model: "gpt-x", stopReason: .toolUse)),
                .toolResult(ToolResultMessage(toolCallId: "c1", toolName: "read", content: [.text(TextContent(text: "A"))], isError: false)),
                .assistant(AssistantMessage(api: "openai-completions", provider: "openai", model: "gpt-x", stopReason: .aborted)),
            ],
            tools: [tool]
        ))
        let body = OpenAICompletions.requestBody(model: model, context: context, options: StreamOptions(maxTokens: 100, reasoning: .low))
        let messages = body["messages"]?.arrayValue ?? []
        #expect(messages.count == 4) // the empty aborted response is dropped
        #expect(messages[0]["role"] == "developer")
        #expect(messages[1]["content"] == "read a")
        #expect(messages[2]["tool_calls"]?.arrayValue?.first?["function"]?["arguments"] == #"{"path":"a"}"#)
        #expect(messages[3]["role"] == "tool")
        #expect(body["tools"]?.arrayValue?.first?["function"]?["name"] == "read")
        #expect(body["max_completion_tokens"] == 100)
        #expect(body["reasoning_effort"] == "low")
        #expect(body["stream_options"]?["include_usage"] == true)
    }

    @Test func detectsCompat() {
        let openRouter = OpenAICompletions.compat(for: Model(id: "x/y", provider: "custom", baseURL: "https://openrouter.ai/api/v1"))
        #expect(openRouter.thinkingFormat == .openrouter)
        #expect(!openRouter.supportsDeveloperRole)
        let deepseek = OpenAICompletions.compat(for: Model(id: "deepseek-chat", provider: "custom", baseURL: "https://api.deepseek.com"))
        #expect(deepseek.maxTokensField == .maxTokens)
        let overridden = OpenAICompletions.compat(for: Model(id: "m", provider: "custom", baseURL: "http://localhost:11434/v1", compat: OpenAICompletionsCompat(maxTokensField: .maxTokens)))
        #expect(overridden.maxTokensField == .maxTokens)
    }
}

// MARK: - Streaming against a mock server

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    nonisolated(unsafe) static var responses: [String: [Response]] = [:]
    nonisolated(unsafe) static var requests: [String: [URLRequest]] = [:]
    static let lock = NSLock()

    static func enqueue(_ responses: [Response], for host: String) {
        lock.withLock { self.responses[host] = responses }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4096)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            buffer.deallocate()
            stream.close()
            request.httpBody = data
        }
        let response = Self.lock.withLock { () -> Response? in
            Self.requests[host, default: []].append(request)
            guard var queue = Self.responses[host], !queue.isEmpty else { return nil }
            let next = queue.removeFirst()
            Self.responses[host] = queue
            return next
        } ?? Response(status: 500, body: "no response queued")
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

func sse(_ chunks: [JSONValue]) -> String {
    chunks.map { "data: \($0.jsonString())\n\n" }.joined() + "data: [DONE]\n\n"
}

@Suite(.serialized) struct OpenAIStreamingTests {
    @Test func streamsTextReasoningToolCallsAndUsage() async throws {
        let host = "stream-ok.test"
        MockURLProtocol.enqueue([.init(status: 200, body: sse([
            ["id": "r1", "model": "served-model", "choices": [["delta": ["reasoning_content": "Think"]]]],
            ["choices": [["delta": ["content": "Hel"]]]],
            ["choices": [["delta": ["content": "lo"]]]],
            ["choices": [["delta": ["tool_calls": [["index": 0, "id": "call_1", "function": ["name": "read", "arguments": "{\"pa"]]]]]]],
            ["choices": [["delta": ["tool_calls": [["index": 0, "function": ["arguments": "th\": \"a.txt\"}"]]]]]]],
            ["choices": [["delta": [:], "finish_reason": "tool_calls"]]],
            ["choices": [], "usage": ["prompt_tokens": 100, "completion_tokens": 20, "prompt_tokens_details": ["cached_tokens": 40]]],
        ]))], for: host)

        let model = Model(id: "m", provider: "test", baseURL: "https://\(host)/v1", cost: ModelCost(input: 1, output: 2))
        let stream = OpenAICompletions.stream(model: model, context: TranscriptContext(normalizing: Context(messages: [.user(UserMessage(text: "hi"))])), options: StreamOptions(apiKey: "sk-test", session: MockURLProtocol.session()))
        var kinds: [String] = []
        for await event in stream {
            switch event {
            case .start: kinds.append("start")
            case .thinkingDelta: kinds.append("thinking")
            case .textDelta: kinds.append("text")
            case let .toolCallDelta(_, _, partial):
                kinds.append("toolcall")
                if case let .toolCall(call)? = partial.content.last, call.arguments["path"] != nil {
                    kinds.append("partial-args")
                }
            case .toolCallEnd: kinds.append("toolcall_end")
            case .done: kinds.append("done")
            default: break
            }
        }
        let message = await stream.result()
        #expect(kinds.first == "start")
        #expect(kinds.last == "done")
        #expect(kinds.contains("partial-args"))
        #expect(message.stopReason == .toolUse)
        #expect(message.text == "Hello")
        #expect(message.responseModel == "served-model")
        #expect(message.toolCalls == [ToolCall(id: "call_1", name: "read", arguments: ["path": "a.txt"])])
        #expect(message.usage.input == 60)
        #expect(message.usage.cacheRead == 40)
        #expect(abs(message.usage.cost.output - 40.0 / 1_000_000) < 1e-12)
        if case let .thinking(thinking) = message.content.first {
            #expect(thinking.thinking == "Think")
            #expect(thinking.thinkingSignature == "reasoning_content")
        } else {
            Issue.record("Expected a thinking block first")
        }

        let request = try #require(MockURLProtocol.requests[host]?.first)
        #expect(request.url?.path == "/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try JSONValue.parse(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        #expect(body["model"] == "m")
        #expect(body["stream"] == true)
    }

    @Test func reportsHTTPErrors() async {
        let host = "stream-error.test"
        MockURLProtocol.enqueue([.init(status: 401, body: #"{"error":{"message":"Invalid API key"}}"#)], for: host)
        let model = Model(id: "m", provider: "test", baseURL: "https://\(host)/v1")
        let message = await OpenAICompletions.stream(model: model, context: TranscriptContext(normalizing: Context(messages: [.user(UserMessage(text: "hi"))])), options: StreamOptions(session: MockURLProtocol.session())).result()
        #expect(message.stopReason == .error)
        #expect(message.errorMessage == "401 Invalid API key")
    }

    @Test func retriesServerErrors() async {
        let host = "stream-retry.test"
        MockURLProtocol.enqueue([
            .init(status: 503, body: "busy", headers: ["Retry-After": "0"]),
            .init(status: 200, body: sse([["choices": [["delta": ["content": "ok"], "finish_reason": "stop"]]]])),
        ], for: host)
        let model = Model(id: "m", provider: "test", baseURL: "https://\(host)/v1")
        let message = await OpenAICompletions.stream(model: model, context: TranscriptContext(normalizing: Context(messages: [.user(UserMessage(text: "hi"))])), options: StreamOptions(session: MockURLProtocol.session())).result()
        #expect(message.stopReason == .stop)
        #expect(message.text == "ok")
    }

    @Test func invalidToolArgumentsBecomeArgumentsError() async {
        let host = "stream-badargs.test"
        MockURLProtocol.enqueue([.init(status: 200, body: sse([
            ["choices": [["delta": ["tool_calls": [["index": 0, "id": "c", "function": ["name": "read", "arguments": "not json"]]]], "finish_reason": "tool_calls"]]],
        ]))], for: host)
        let model = Model(id: "m", provider: "test", baseURL: "https://\(host)/v1")
        let message = await OpenAICompletions.stream(model: model, context: TranscriptContext(normalizing: Context(messages: [.user(UserMessage(text: "hi"))])), options: StreamOptions(session: MockURLProtocol.session())).result()
        #expect(message.toolCalls.first?.argumentsError?.contains("not json") == true)
    }

    @Test func unsupportedAPIFailsInStream() async {
        let model = Model(id: "m", api: "nope", provider: "test", baseURL: "https://x")
        let message = await streamSimple(model: model, context: TranscriptContext(transcript: [])).result()
        #expect(message.stopReason == .error)
    }
}
