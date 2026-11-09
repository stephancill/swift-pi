import Foundation

/// The OpenAI Chat Completions API (`POST {baseURL}/chat/completions`, streamed), which OpenAI, OpenRouter, Groq,
/// DeepSeek, Ollama, LM Studio, vLLM, llama.cpp and most other servers speak.
public enum OpenAICompletions {
    public static let api = "openai-completions"

    /// Compatibility switches with every field resolved.
    public struct ResolvedCompat: Sendable, Hashable {
        public var supportsStore: Bool
        public var supportsDeveloperRole: Bool
        public var supportsReasoningEffort: Bool
        public var supportsUsageInStreaming: Bool
        public var maxTokensField: OpenAICompletionsCompat.MaxTokensField
        public var supportsStrictMode: Bool
        public var requiresToolResultName: Bool
        public var requiresAssistantAfterToolResult: Bool
        public var thinkingFormat: OpenAICompletionsCompat.ThinkingFormat
    }

    /// Detected from the provider and base URL, then overridden by `model.compat`.
    public static func compat(for model: Model) -> ResolvedCompat {
        let baseURL = model.baseURL.lowercased()
        let provider = model.provider
        let isOpenRouter = provider == "openrouter" || baseURL.contains("openrouter.ai")
        let isDeepSeek = provider == "deepseek" || baseURL.contains("deepseek.com")
        let isGrok = provider == "xai" || baseURL.contains("api.x.ai")
        let isTogether = provider == "together" || baseURL.contains("api.together.")
        let isMoonshot = provider == "moonshotai" || baseURL.contains("api.moonshot.")
        let isZai = provider == "zai" || baseURL.contains("api.z.ai") || baseURL.contains("open.bigmodel.cn")
        let isCerebras = provider == "cerebras" || baseURL.contains("cerebras.ai")
        let isNonStandard = isDeepSeek || isGrok || isTogether || isMoonshot || isZai || isCerebras
        let useMaxTokens = isDeepSeek || isMoonshot || isTogether || isZai
        let isOpenRouterDeveloperRoleModel = isOpenRouter && (model.id.hasPrefix("anthropic/") || model.id.hasPrefix("openai/"))

        let detected = ResolvedCompat(
            supportsStore: !isNonStandard && !isOpenRouter && baseURL.contains("api.openai.com"),
            supportsDeveloperRole: isOpenRouterDeveloperRoleModel || (!isNonStandard && !isOpenRouter),
            supportsReasoningEffort: !isGrok && !isZai && !isMoonshot && !isTogether,
            supportsUsageInStreaming: true,
            maxTokensField: useMaxTokens ? .maxTokens : .maxCompletionTokens,
            supportsStrictMode: false,
            requiresToolResultName: false,
            requiresAssistantAfterToolResult: false,
            thinkingFormat: isOpenRouter ? .openrouter : .openai
        )
        guard let overrides = model.compat else { return detected }
        return ResolvedCompat(
            supportsStore: detected.supportsStore,
            supportsDeveloperRole: overrides.supportsDeveloperRole ?? detected.supportsDeveloperRole,
            supportsReasoningEffort: detected.supportsReasoningEffort,
            supportsUsageInStreaming: overrides.supportsUsageInStreaming ?? detected.supportsUsageInStreaming,
            maxTokensField: overrides.maxTokensField ?? detected.maxTokensField,
            supportsStrictMode: overrides.supportsStrictMode ?? detected.supportsStrictMode,
            requiresToolResultName: overrides.requiresToolResultName ?? detected.requiresToolResultName,
            requiresAssistantAfterToolResult: overrides.requiresAssistantAfterToolResult ?? detected.requiresAssistantAfterToolResult,
            thinkingFormat: overrides.thinkingFormat ?? detected.thinkingFormat
        )
    }

    // MARK: Request

    /// The request body for a transcript.
    public static func requestBody(model: Model, context: TranscriptContext, options: StreamOptions) -> JSONObject {
        let compat = compat(for: model)
        // Chat Completions has no mid-conversation system messages: replay them into one leading message.
        let context = collapseSystemMessages(context)
        var body: JSONObject = [
            "model": .string(model.id),
            "messages": .array(convertMessages(model: model, context: context, compat: compat)),
            "stream": true,
        ]
        if compat.supportsUsageInStreaming {
            body["stream_options"] = ["include_usage": true]
        }
        if compat.supportsStore {
            body["store"] = false
        }
        if let maxTokens = options.maxTokens {
            body[compat.maxTokensField.rawValue] = .number(Double(maxTokens))
        }
        if let temperature = options.temperature {
            body["temperature"] = .number(temperature)
        }
        let tools = getCurrentTools(context.messages)
        if !tools.isEmpty {
            body["tools"] = .array(tools.map { convertTool($0, compat: compat) })
        }
        if let toolChoice = options.toolChoice {
            body["tool_choice"] = .string(toolChoice.rawValue)
        }
        if model.reasoning {
            switch compat.thinkingFormat {
            case .openrouter:
                body["reasoning"] = ["effort": .string(options.reasoning?.rawValue ?? "none")]
            case .openai:
                if let reasoning = options.reasoning, compat.supportsReasoningEffort {
                    body["reasoning_effort"] = .string(reasoning.rawValue)
                }
            case .none:
                break
            }
        }
        return body
    }

    static func convertTool(_ tool: Tool, compat: ResolvedCompat) -> JSONValue {
        var function: JSONObject = [
            "name": .string(tool.name),
            "description": .string(tool.description),
            "parameters": tool.parameters,
        ]
        if compat.supportsStrictMode {
            function["strict"] = false
        }
        return ["type": "function", "function": .object(function)]
    }

    /// Chat Completions messages for a transcript whose system messages are already collapsed.
    public static func convertMessages(model: Model, context: TranscriptContext, compat: ResolvedCompat) -> [JSONValue] {
        var params: [JSONValue] = []
        let instructionRole = model.reasoning && compat.supportsDeveloperRole ? "developer" : "system"
        let messages = context.messages
        var lastRole: String?
        var index = 0

        while index < messages.count {
            let message = messages[index]
            if compat.requiresAssistantAfterToolResult, lastRole == "toolResult", case .user = message {
                params.append(["role": "assistant", "content": "I have processed the tool results."])
            }

            switch message {
            case let .system(system):
                let text = systemMessageText(system)
                if !text.isEmpty {
                    params.append(["role": .string(instructionRole), "content": .string(text)])
                }

            case let .user(user):
                let parts: [JSONValue] = user.content.compactMap { block in
                    switch block {
                    case let .text(text):
                        text.text.isEmpty ? nil : ["type": "text", "text": .string(text.text)]
                    case let .image(image):
                        ["type": "image_url", "image_url": ["url": .string("data:\(image.mimeType);base64,\(image.data)")]]
                    }
                }
                if parts.isEmpty { break }
                // Text alone goes as a plain string, which every server accepts.
                if parts.count == 1, case let .string(text)? = parts[0]["text"] {
                    params.append(["role": "user", "content": .string(text)])
                } else {
                    params.append(["role": "user", "content": .array(parts)])
                }

            case let .assistant(assistant):
                var param: JSONObject = ["role": "assistant", "content": .null]
                let text = assistant.content.compactMap { block -> String? in
                    if case let .text(text) = block, !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text.text }
                    return nil
                }.joined()
                if !text.isEmpty {
                    param["content"] = .string(text)
                }
                // Reasoning goes back in the field it arrived in, for servers that want it replayed (llama.cpp, gpt-oss).
                let thinking = assistant.content.compactMap { block -> ThinkingContent? in
                    if case let .thinking(thinking) = block, !thinking.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return thinking }
                    return nil
                }
                if let field = thinking.first?.thinkingSignature, reasoningFields.contains(field) {
                    param[field] = .string(thinking.map(\.thinking).joined(separator: "\n"))
                }
                let toolCalls = assistant.toolCalls
                if !toolCalls.isEmpty {
                    param["tool_calls"] = .array(toolCalls.map { call in
                        [
                            "id": .string(call.id),
                            "type": "function",
                            "function": ["name": .string(call.name), "arguments": .string(JSONValue.object(call.arguments).jsonString())],
                        ]
                    })
                }
                // Providers reject assistant messages with neither content nor tool calls, such as an aborted response.
                if param["content"] == .null, toolCalls.isEmpty { break }
                params.append(.object(param))

            case .toolResult:
                var images: [JSONValue] = []
                var cursor = index
                while cursor < messages.count, case let .toolResult(result) = messages[cursor] {
                    let text = contentText(result.content)
                    let hasImages = result.content.contains { if case .image = $0 { true } else { false } }
                    let output = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : hasImages ? "(see attached image)" : "(no tool output)"
                    var param: JSONObject = ["role": "tool", "content": .string(output), "tool_call_id": .string(result.toolCallId)]
                    if compat.requiresToolResultName {
                        param["name"] = .string(result.toolName)
                    }
                    params.append(.object(param))
                    if hasImages, model.input.contains(.image) {
                        for case let .image(image) in result.content {
                            images.append(["type": "image_url", "image_url": ["url": .string("data:\(image.mimeType);base64,\(image.data)")]])
                        }
                    }
                    cursor += 1
                }
                index = cursor - 1
                if !images.isEmpty {
                    if compat.requiresAssistantAfterToolResult {
                        params.append(["role": "assistant", "content": "I have processed the tool results."])
                    }
                    params.append(["role": "user", "content": .array([["type": "text", "text": "Attached image(s) from tool result:"]] + images)])
                    lastRole = "user"
                } else {
                    lastRole = "toolResult"
                }
                index += 1
                continue
            }
            lastRole = message.role
            index += 1
        }
        return params
    }

    static let reasoningFields = ["reasoning_content", "reasoning", "reasoning_text"]

    // MARK: Streaming

    /// Streams one assistant response. Failures end the stream with `error`; cancelling the task aborts the request.
    public static func stream(model: Model, context: TranscriptContext, options: StreamOptions = StreamOptions()) -> AssistantMessageEventStream {
        let stream = AssistantMessageEventStream()
        Task {
            var output = AssistantMessage(api: model.api, provider: model.provider, model: model.id, stopReason: .pending)
            do {
                try await run(model: model, context: context, options: options, stream: stream, output: &output)
            } catch {
                output.stopReason = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled ? .aborted : .error
                output.errorMessage = output.stopReason == .aborted ? "Request was aborted" : describe(error)
                stream.push(.error(reason: output.stopReason, error: output))
            }
            stream.end()
        }
        return stream
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? ProviderError { return error.message }
        // `localizedDescription` gives Foundation errors' message ("Could not connect to the server."), where
        // `String(describing:)` gives their whole debug description.
        return error.localizedDescription
    }

    struct ProviderError: Error {
        let message: String
        let status: Int?
        let retryAfter: TimeInterval?
    }

    private static func makeRequest(model: Model, context: TranscriptContext, options: StreamOptions) throws -> URLRequest {
        var base = model.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions"), url.scheme == "http" || url.scheme == "https" else {
            throw ProviderError(message: "Invalid base URL: \(model.baseURL)", status: nil, retryAfter: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = options.timeout ?? 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey = options.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in model.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for (name, value) in options.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let body = requestBody(model: model, context: context, options: options)
        request.httpBody = Data(JSONValue.object(body).jsonString().utf8)
        return request
    }

    /// Opens the stream, retrying rate limits and server errors (up to two retries, honoring `Retry-After` up to a minute).
    private static func open(_ request: URLRequest, session: URLSession) async throws -> URLSession.AsyncBytes {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return bytes }
            if (200 ..< 300).contains(http.statusCode) { return bytes }

            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 64 * 1024 { break }
            }
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            let error = ProviderError(message: errorMessage(status: http.statusCode, body: body), status: http.statusCode, retryAfter: retryAfter)
            let retryable = http.statusCode == 429 || http.statusCode >= 500
            guard retryable, attempt < 2 else { throw error }
            let delay = retryAfter ?? pow(2, Double(attempt))
            guard delay <= 60 else { throw error }
            attempt += 1
            try await Task.sleep(for: .seconds(delay))
        }
    }

    static func errorMessage(status: Int, body: Data) -> String {
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let json = try? JSONValue.parse(text) {
            let message = json["error"]?["message"]?.stringValue ?? json["error"]?.stringValue ?? json["message"]?.stringValue
            if let message { return "\(status) \(message)" }
        }
        let excerpt = text.count > 500 ? String(text.prefix(500)) + "…" : text
        return excerpt.isEmpty ? "HTTP \(status)" : "\(status) \(excerpt)"
    }

    private enum Block {
        case text(Int)
        case thinking(Int)
    }

    private struct ToolCallState {
        var contentIndex: Int
        var argumentsText = ""
    }

    private static func run(model: Model, context: TranscriptContext, options: StreamOptions, stream: AssistantMessageEventStream, output: inout AssistantMessage) async throws {
        let request = try makeRequest(model: model, context: context, options: options)
        let bytes = try await open(request, session: options.session ?? .shared)
        stream.push(.start(partial: output))

        var textIndex: Int?
        var thinkingIndex: Int?
        var toolCallsByStreamIndex: [Int: Int] = [:] // stream index → content index
        var toolCallsById: [String: Int] = [:]
        var toolCallStates: [Int: ToolCallState] = [:] // content index → state
        var hasFinishReason = false

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let chunk = try? JSONValue.parse(payload), chunk.objectValue != nil else { continue }

            if let error = chunk["error"], !error.isNull {
                throw ProviderError(message: error["message"]?.stringValue ?? error.jsonString(), status: nil, retryAfter: nil)
            }
            if output.responseId == nil, let id = chunk["id"]?.stringValue { output.responseId = id }
            if output.responseModel == nil, let responseModel = chunk["model"]?.stringValue, !responseModel.isEmpty, responseModel != model.id {
                output.responseModel = responseModel
            }
            if let usage = chunk["usage"]?.objectValue {
                output.usage = parseUsage(usage, model: model)
            }

            guard let choice = chunk["choices"]?.arrayValue?.first else { continue }
            if chunk["usage"] == nil || chunk["usage"]?.isNull == true, let usage = choice["usage"]?.objectValue {
                output.usage = parseUsage(usage, model: model)
            }
            if let finishReason = choice["finish_reason"]?.stringValue {
                output.rawStopReason = finishReason
                let mapped = mapStopReason(finishReason)
                output.stopReason = mapped.stopReason
                if let message = mapped.errorMessage { output.errorMessage = message }
                hasFinishReason = true
            }
            guard let delta = choice["delta"]?.objectValue else { continue }

            // Reasoning first: some proxies send reasoning and answer in one delta, and thinking must lead.
            if let field = reasoningFields.first(where: { !(delta[$0]?.stringValue ?? "").isEmpty }), let text = delta[field]?.stringValue {
                let index: Int
                if let thinkingIndex {
                    index = thinkingIndex
                } else {
                    index = output.content.count
                    thinkingIndex = index
                    output.content.append(.thinking(ThinkingContent(thinking: "", thinkingSignature: field)))
                    stream.push(.thinkingStart(contentIndex: index, partial: output))
                }
                if case var .thinking(block) = output.content[index] {
                    block.thinking += text
                    output.content[index] = .thinking(block)
                }
                stream.push(.thinkingDelta(contentIndex: index, delta: text, partial: output))
            }

            if let text = delta["content"]?.stringValue, !text.isEmpty {
                let index: Int
                if let textIndex {
                    index = textIndex
                } else {
                    index = output.content.count
                    textIndex = index
                    output.content.append(.text(TextContent(text: "")))
                    stream.push(.textStart(contentIndex: index, partial: output))
                }
                if case var .text(block) = output.content[index] {
                    block.text += text
                    output.content[index] = .text(block)
                }
                stream.push(.textDelta(contentIndex: index, delta: text, partial: output))
            }

            for toolCallDelta in delta["tool_calls"]?.arrayValue ?? [] {
                let streamIndex = toolCallDelta["index"]?.intValue
                let id = toolCallDelta["id"]?.stringValue
                let function = toolCallDelta["function"]
                let name = function?["name"]?.stringValue

                var contentIndex = streamIndex.flatMap { toolCallsByStreamIndex[$0] } ?? id.flatMap { toolCallsById[$0] }
                if contentIndex == nil {
                    let index = output.content.count
                    output.content.append(.toolCall(ToolCall(id: id ?? "", name: name ?? "", arguments: [:])))
                    toolCallStates[index] = ToolCallState(contentIndex: index)
                    stream.push(.toolCallStart(contentIndex: index, partial: output))
                    contentIndex = index
                }
                guard let index = contentIndex, case var .toolCall(call) = output.content[index] else { continue }
                if let streamIndex { toolCallsByStreamIndex[streamIndex] = index }
                if let id, !id.isEmpty {
                    toolCallsById[id] = index
                    if call.id.isEmpty { call.id = id }
                }
                if call.name.isEmpty, let name { call.name = name }
                let argumentsDelta = function?["arguments"]?.stringValue ?? ""
                if !argumentsDelta.isEmpty {
                    toolCallStates[index, default: ToolCallState(contentIndex: index)].argumentsText += argumentsDelta
                    if let partial = parsePartialJSONObject(toolCallStates[index]?.argumentsText ?? "") {
                        call.arguments = partial
                    }
                }
                output.content[index] = .toolCall(call)
                stream.push(.toolCallDelta(contentIndex: index, delta: argumentsDelta, partial: output))
            }
        }
        try Task.checkCancellation()

        // Finish blocks in content order.
        for index in output.content.indices {
            switch output.content[index] {
            case let .text(block):
                stream.push(.textEnd(contentIndex: index, content: block.text, partial: output))
            case let .thinking(block):
                stream.push(.thinkingEnd(contentIndex: index, content: block.thinking, partial: output))
            case var .toolCall(call):
                let text = toolCallStates[index]?.argumentsText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.isEmpty {
                    call.arguments = [:]
                } else if let value = try? JSONValue.parse(text), let object = value.objectValue {
                    call.arguments = object
                } else {
                    call.arguments = [:]
                    call.argumentsError = "The arguments are not a JSON object: \(text.count > 2000 ? String(text.prefix(2000)) + "…" : text)"
                }
                if call.id.isEmpty { call.id = "call_\(UUID().uuidString.prefix(8))" }
                output.content[index] = .toolCall(call)
                stream.push(.toolCallEnd(contentIndex: index, toolCall: call, partial: output))
            }
        }

        if output.stopReason == .error {
            throw ProviderError(message: output.errorMessage ?? "Provider returned an error stop reason", status: nil, retryAfter: nil)
        }
        if !hasFinishReason || output.stopReason == .pending {
            throw ProviderError(message: "Stream ended without finish_reason", status: nil, retryAfter: nil)
        }
        stream.push(.done(reason: output.stopReason, message: output))
    }

    static func mapStopReason(_ reason: String) -> (stopReason: StopReason, errorMessage: String?) {
        switch reason {
        case "stop", "end": (.stop, nil)
        case "length": (.length, nil)
        case "function_call", "tool_calls": (.toolUse, nil)
        default: (.error, "Provider finish_reason: \(reason)")
        }
    }

    static func parseUsage(_ raw: JSONObject, model: Model) -> Usage {
        let prompt = raw["prompt_tokens"]?.intValue ?? 0
        let cacheRead = raw["prompt_tokens_details"]?["cached_tokens"]?.intValue ?? raw["prompt_cache_hit_tokens"]?.intValue ?? raw["cached_tokens"]?.intValue ?? 0
        let cacheWrite = raw["prompt_tokens_details"]?["cache_write_tokens"]?.intValue ?? 0
        let input = max(0, prompt - cacheRead - cacheWrite)
        let output = raw["completion_tokens"]?.intValue ?? 0
        var usage = Usage(
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            reasoning: raw["completion_tokens_details"]?["reasoning_tokens"]?.intValue ?? 0,
            totalTokens: input + output + cacheRead + cacheWrite
        )
        usage.cost = calculateCost(model: model, usage: usage)
        // OpenRouter reports what the request was billed.
        if let billed = raw["cost"]?.doubleValue {
            usage.cost.total = billed
        }
        return usage
    }
}

/// The cost of a response at the model's per-million-token prices.
public func calculateCost(model: Model, usage: Usage) -> Cost {
    let input = model.cost.input * Double(usage.input) / 1_000_000
    let output = model.cost.output * Double(usage.output) / 1_000_000
    let cacheRead = model.cost.cacheRead * Double(usage.cacheRead) / 1_000_000
    let cacheWrite = model.cost.cacheWrite * Double(usage.cacheWrite) / 1_000_000
    return Cost(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, total: input + output + cacheRead + cacheWrite)
}
