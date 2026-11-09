import Foundation
import PiAgent
import PiAI
@testable import PiTools
import Testing

final class WebMockProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status = 200
        var body: String
        var contentType = "text/html; charset=utf-8"
    }

    nonisolated(unsafe) static var responses: [String: Response] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url?.host ?? ""
        let response = Self.lock.withLock { () -> Response in
            Self.requests.append(request)
            return Self.responses[key] ?? Response(status: 404, body: "missing")
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": response.contentType])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebMockProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@Suite struct HTMLTextTests {
    @Test func convertsPagesToMarkdown() {
        let html = """
        <html><head><title>T</title><style>p{color:red}</style><script>alert(1)</script></head>
        <body><nav>Menu</nav><h1>Title &amp; more</h1><p>Some <b>bold</b> and <a href="https://example.com/x">a link</a>.</p>
        <ul><li>One</li><li>Two</li></ul><ol><li>First</li></ol><pre><code>let x = 1
        let y = 2</code></pre><!-- hidden --><p>caf&eacute;&nbsp;&#8217;s &#x2014; end</p></body></html>
        """
        let markdown = HTMLText.markdown(html)
        #expect(markdown.hasPrefix("# Title & more"))
        #expect(markdown.contains("Some **bold** and [a link](https://example.com/x)."))
        #expect(markdown.contains("- One\n- Two"))
        #expect(markdown.contains("1. First"))
        #expect(markdown.contains("```\nlet x = 1\nlet y = 2\n```"))
        #expect(!markdown.contains("alert"))
        #expect(!markdown.contains("color:red"))
        #expect(!markdown.contains("Menu"))
        #expect(!markdown.contains("hidden"))
        #expect(markdown.contains("\u{2019}s \u{2014} end"))
        let text = HTMLText.text(html)
        #expect(text.contains("Some bold and a link."))
        #expect(!text.contains("**"))
    }

    @Test func resolvesRelativeLinksAndDropsImages() {
        let markdown = HTMLText.markdown(#"<p><a href="/docs?a=1&amp;b=2">Docs</a> <img src="/x.png" alt="Logo"></p>"#, baseURL: URL(string: "https://example.com/blog/post"))
        #expect(markdown == "[Docs](https://example.com/docs?a=1&b=2)")
    }

    @Test func decodesEntities() {
        #expect(HTMLText.decodeEntities("a &lt;b&gt; &#65;&#x42; &unknown; &") == "a <b> AB &unknown; &")
    }
}

@Suite(.serialized) struct WebToolTests {
    @Test func parsesMCPReplies() {
        #expect(parseMCPReply(#"{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"found"}]}}"#) == "found")
        #expect(parseMCPReply("event: message\ndata: {\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"streamed\"}]}}\n\n") == "streamed")
        #expect(parseMCPReply(#"{"error":{"message":"bad"}}"#) == nil)
    }

    @Test func fetchesPagesAsMarkdown() async throws {
        WebMockProtocol.lock.withLock {
            WebMockProtocol.responses["fetch.test"] = .init(body: "<html><body><h2>Hi</h2><p>Body</p></body></html>")
        }
        let tool = webFetchTool(session: WebMockProtocol.session())
        let result = try await tool.execute("1", ["url": "http://fetch.test/page"]) { _ in }
        #expect(contentText(result.content) == "## Hi\n\nBody")
        let request = WebMockProtocol.lock.withLock { WebMockProtocol.requests.last }
        #expect(request?.url?.scheme == "https")
    }

    @Test func refusesOtherSchemesAndReportsStatus() async throws {
        let tool = webFetchTool(session: WebMockProtocol.session())
        await #expect(throws: (any Error).self) { try await tool.execute("1", ["url": "file:///etc/hosts"]) { _ in } }
        await #expect { try await tool.execute("1", ["url": "https://missing.test/"]) { _ in } } throws: { error in
            error.localizedDescription.contains("404")
        }
    }

    @Test func truncatesOneHugeLine() async throws {
        WebMockProtocol.lock.withLock {
            WebMockProtocol.responses["huge.test"] = .init(body: String(repeating: "a", count: 200_000), contentType: "text/plain")
        }
        let result = try await webFetchTool(session: WebMockProtocol.session()).execute("1", ["url": "https://huge.test/"]) { _ in }
        let text = contentText(result.content)
        #expect(text.hasPrefix("aaaa"))
        #expect(text.contains("truncated"))
        #expect(text.utf8.count < 60_000)
    }

    @Test func searchesThroughMCP() async throws {
        WebMockProtocol.lock.withLock {
            WebMockProtocol.responses["mcp.exa.ai"] = .init(body: "event: message\ndata: {\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Title: Result\\nURL: https://r.test\"}]}}\n\n", contentType: "text/event-stream")
        }
        let result = try await webSearchTool(provider: .exa, session: WebMockProtocol.session()).execute("1", ["query": "swift"]) { _ in }
        #expect(contentText(result.content).contains("URL: https://r.test"))
        let request = try #require(WebMockProtocol.lock.withLock { WebMockProtocol.requests.last })
        #expect(request.url?.absoluteString == "https://mcp.exa.ai/mcp")
        let stream = request.httpBodyStream
        var body = Data()
        if let stream {
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4096)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            buffer.deallocate()
        } else if let data = request.httpBody {
            body = data
        }
        let json = try JSONValue.parse(String(decoding: body, as: UTF8.self))
        #expect(json["params"]?["name"] == "web_search_exa")
        #expect(json["params"]?["arguments"]?["query"] == "swift")
    }
}
