import Foundation
import PiAgent
import PiAI

/// A hosted search the `web_search` tool asks: both are MCP servers that answer without an API key, the ones opencode
/// uses.
public enum WebSearchProvider: String, Sendable, Hashable, Codable, CaseIterable {
    /// Exa (`https://mcp.exa.ai/mcp`): results with the relevant text of each page.
    case exa
    /// Parallel (`https://search.parallel.ai/mcp`): results with excerpts.
    case parallel

    public var name: String {
        switch self {
        case .exa: "Exa"
        case .parallel: "Parallel"
        }
    }
}

/// `web_search` and `web_fetch`.
public func webTools(searchProvider: WebSearchProvider = .exa, session: URLSession = .shared) -> [AgentTool] {
    [webSearchTool(provider: searchProvider, session: session), webFetchTool(session: session)]
}

private struct WebToolError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Calls an MCP server's tool over HTTP and returns the first text it answers with. The reply is JSON or a server-sent
/// event stream of JSON.
func callMCPTool(url: URL, tool: String, arguments: JSONObject, timeout: TimeInterval, session: URLSession, headers: [String: String] = [:]) async throws -> String? {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    for (name, value) in headers {
        request.setValue(value, forHTTPHeaderField: name)
    }
    let body: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(tool), "arguments": .object(arguments)]]
    request.httpBody = Data(body.jsonString().utf8)
    let (data, response) = try await session.data(for: request)
    if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
        throw WebToolError(message: "The search service answered \(http.statusCode).")
    }
    return parseMCPReply(String(decoding: data, as: UTF8.self))
}

func parseMCPReply(_ body: String) -> String? {
    func text(_ payload: String) -> String? {
        guard let json = try? JSONValue.parse(payload.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        if let error = json["error"], !error.isNull {
            return nil
        }
        return json["result"]?["content"]?.arrayValue?.lazy.compactMap { $0["text"]?.stringValue }.first { !$0.isEmpty }
    }
    if let direct = text(body) { return direct }
    for line in body.split(separator: "\n") where line.hasPrefix("data:") {
        if let found = text(String(line.dropFirst(5))) { return found }
    }
    return nil
}

public func webSearchTool(provider: WebSearchProvider = .exa, session: URLSession = .shared) -> AgentTool {
    AgentTool(
        name: "web_search",
        label: "web search",
        description: """
        Search the web for current information: news, documentation, prices, anything past your knowledge cutoff. \
        Returns the most relevant pages with their text. Use web_fetch to read a page in full. When searching for \
        recent information, include the current year in the query.
        """,
        parameters: ["type": "object", "properties": [
            "query": ["type": "string", "description": "What to search for"],
            "numResults": ["type": "number", "description": "How many results to return (default 8, at most 20)"],
        ], "required": ["query"]]
    ) { _, arguments, _ in
        let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else { throw WebToolError(message: "The query is empty.") }
        let count = min(20, max(1, arguments["numResults"]?.intValue ?? 8))
        let reply: String?
        switch provider {
        case .exa:
            reply = try await callMCPTool(
                url: URL(string: "https://mcp.exa.ai/mcp")!,
                tool: "web_search_exa",
                arguments: ["query": .string(query), "type": "auto", "numResults": .number(Double(count)), "livecrawl": "fallback"],
                timeout: 25,
                session: session
            )
        case .parallel:
            reply = try await callMCPTool(
                url: URL(string: "https://search.parallel.ai/mcp")!,
                tool: "web_search",
                arguments: ["objective": .string(query), "search_queries": [.string(query)]],
                timeout: 25,
                session: session
            )
        }
        guard let reply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AgentToolResult(text: "No search results found. Try a different query.")
        }
        let (truncated, wasTruncated) = truncateForModel(reply)
        var output = truncated
        if wasTruncated { output += "\n\n[Results truncated to \(formatSize(ToolLimits.maxBytes)).]" }
        return AgentToolResult(text: output, details: ["provider": .string(provider.rawValue)])
    }
}

/// Larger responses are refused.
private let maxFetchBytes = 5 * 1024 * 1024

public func webFetchTool(session: URLSession = .shared) -> AgentTool {
    AgentTool(
        name: "web_fetch",
        label: "web fetch",
        description: """
        Fetch a URL and return its content: web pages as Markdown (default), plain text or raw HTML, other text as is. \
        HTTP URLs are upgraded to HTTPS. Output is truncated to \(ToolLimits.maxLines) lines or \(ToolLimits.maxBytes / 1024)KB.
        """,
        parameters: ["type": "object", "properties": [
            "url": ["type": "string", "description": "The full URL to fetch"],
            "format": ["type": "string", "enum": ["markdown", "text", "html"], "description": "How to return a web page (default markdown)"],
            "timeout": ["type": "number", "description": "Timeout in seconds (default 30, at most 120)"],
        ], "required": ["url"]]
    ) { _, arguments, _ in
        let raw = arguments["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard var components = URLComponents(string: raw), let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https", components.host != nil else {
            throw WebToolError(message: "\(raw) is not an http or https URL.")
        }
        if scheme == "http" { components.scheme = "https" }
        guard let url = components.url else { throw WebToolError(message: "\(raw) is not a valid URL.") }
        let format = arguments["format"]?.stringValue ?? "markdown"
        let timeout = min(120, max(1, arguments["timeout"]?.doubleValue ?? 30))

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(format == "html" ? "text/html,*/*;q=0.8" : "text/markdown,text/html;q=0.9,text/plain;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebToolError(message: "No HTTP response.") }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw WebToolError(message: "\(url.absoluteString) answered \(http.statusCode).")
        }
        guard data.count <= maxFetchBytes else {
            throw WebToolError(message: "The response is \(formatSize(data.count)), over the \(formatSize(maxFetchBytes)) limit.")
        }
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.hasPrefix("image/") || contentType.hasPrefix("audio/") || contentType.hasPrefix("video/") || contentType.contains("octet-stream") || contentType.contains("pdf") {
            return AgentToolResult(text: "\(url.absoluteString) is \(contentType) (\(formatSize(data.count))), which can't be shown as text.")
        }
        let body = String(decoding: data, as: UTF8.self)
        let isHTML = contentType.contains("html") || body.prefix(512).lowercased().contains("<html") || body.prefix(512).lowercased().contains("<!doctype html")
        let text = switch (isHTML, format) {
        case (true, "text"): HTMLText.text(body)
        case (true, "html"): body
        case (true, _): HTMLText.markdown(body, baseURL: http.url ?? url)
        default: body
        }
        let (truncated, wasTruncated) = truncateForModel(text)
        var output = truncated
        if wasTruncated {
            output += "\n\n[The page was truncated to \(formatSize(ToolLimits.maxBytes)).]"
        }
        return AgentToolResult(text: output.isEmpty ? "(The page has no text.)" : output, details: ["url": .string(url.absoluteString), "status": .number(Double(http.statusCode))])
    }
}
