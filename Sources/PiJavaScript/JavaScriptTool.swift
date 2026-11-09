import Foundation
import PiAgent
import PiAI
import PiTools
import WebKit

/// `javascript`: runs code in an offscreen web view, each run in a fresh page. WebKit runs it in its own web content
/// process, with a JIT, and a run that outlasts its timeout ends with the view. The code can read the workspace
/// (`workspace.read`, `workspace.list`) but not change it: files change only through `write` and `edit`, and so only
/// with whatever approval the app asks for.
public func javaScriptTool(workspace: Workspace?) -> AgentTool {
    AgentTool(
        name: "javascript",
        label: "JavaScript",
        description: """
        Run JavaScript for calculations, data processing, parsing and transforming text or JSON. The code is the body of \
        an async function: use await, and return a value to get it back (objects come back as JSON). console.log output \
        is returned too. Standard JavaScript and browser APIs only, no Node.js modules. \
        workspace.read(path) returns a workspace file's text and workspace.list(path) the names in a directory \
        (directories end in "/"), both as promises. The code can't change files: use write or edit for that.
        """,
        parameters: ["type": "object", "properties": [
            "code": ["type": "string", "description": "The body of an async function"],
            "timeout": ["type": "number", "description": "Seconds before the run is stopped (default 10, at most 60)"],
        ], "required": ["code"]]
    ) { _, arguments, _ in
        let code = arguments["code"]?.stringValue ?? ""
        let timeout = min(60, max(1, arguments["timeout"]?.doubleValue ?? 10))
        let run = try await JavaScriptRunner.run(code: code, timeout: timeout, workspace: workspace)
        var sections: [String] = []
        if !run.logs.isEmpty { sections.append("Console:\n" + run.logs.joined(separator: "\n")) }
        if let error = run.error {
            sections.append("Error: " + error)
        } else if let result = run.result {
            sections.append("Result: " + result)
        } else if run.logs.isEmpty {
            sections.append("Done, with no output and no return value.")
        }
        let text = sections.joined(separator: "\n\n")
        let (output, truncated) = truncateForModel(text)
        return AgentToolResult(text: truncated ? output + "\n\n[Output truncated.]" : output, isError: run.error != nil)
    }
}

/// What a run printed and returned, or how it failed.
public struct JavaScriptRun: Sendable {
    public var logs: [String]
    /// The returned value as text: strings as they are, other values as JSON. Nil when nothing was returned.
    public var result: String?
    /// The error thrown, with its stack where there is one.
    public var error: String?
}

public struct JavaScriptTimeout: Error, LocalizedError {
    public let seconds: Double
    public var errorDescription: String? { "The code ran longer than \(Int(seconds)) seconds and was stopped." }
}

@MainActor
public final class JavaScriptRunner: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    private let workspace: Workspace?
    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Void, Never>?

    private init(workspace: Workspace?) {
        self.workspace = workspace
    }

    /// Runs `code` as the body of an async function in a fresh page.
    public static func run(code: String, timeout: TimeInterval, workspace: Workspace?) async throws -> JavaScriptRun {
        let runner = JavaScriptRunner(workspace: workspace)
        defer { runner.tearDown() }
        try await runner.load()
        return try await runner.evaluate(code: code, timeout: timeout)
    }

    private func load() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "workspace")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        await withCheckedContinuation { continuation in
            loaded = continuation
            webView.loadHTMLString("<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>", baseURL: nil)
        }
        try Task.checkCancellation()
    }

    public nonisolated func webView(_: WKWebView, didFinish _: WKNavigation!) {
        MainActor.assumeIsolated { finishLoading() }
    }

    public nonisolated func webView(_: WKWebView, didFail _: WKNavigation!, withError _: Error) {
        MainActor.assumeIsolated { finishLoading() }
    }

    private func finishLoading() {
        loaded?.resume()
        loaded = nil
    }

    private static let harness = """
    const logs = [];
    const show = (value) => {
      if (typeof value === "string") return value;
      if (value === undefined) return "undefined";
      if (value instanceof Error) return String(value.stack || value);
      try { return JSON.stringify(value); } catch { return String(value); }
    };
    const record = (prefix) => (...values) => logs.push(prefix + values.map(show).join(" "));
    const console = { log: record(""), info: record(""), debug: record(""), warn: record("warning: "), error: record("error: ") };
    const workspace = {
      read: (path) => window.webkit.messageHandlers.workspace.postMessage({ op: "read", path: String(path) }),
      list: (path = ".") => window.webkit.messageHandlers.workspace.postMessage({ op: "list", path: String(path) }),
    };
    const AsyncFunction = (async () => {}).constructor;
    try {
      const value = await new AsyncFunction("console", "workspace", code)(console, workspace);
      return { logs, result: value === undefined ? null : show(value), error: null };
    } catch (error) {
      return { logs, result: null, error: String((error && error.stack) ? `${error}\\n${error.stack}` : error) };
    }
    """

    private func evaluate(code: String, timeout: TimeInterval) async throws -> JavaScriptRun {
        guard let webView else { throw CancellationError() }
        let gate = ResumeOnce<JavaScriptRun>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JavaScriptRun, Error>) in
                gate.set(continuation)
                webView.callAsyncJavaScript(Self.harness, arguments: ["code": code], in: nil, in: .page) { result in
                    switch result {
                    case let .success(value):
                        gate.resume(with: .success(Self.decode(value)))
                    case let .failure(error):
                        gate.resume(with: .failure(error))
                    }
                }
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    if gate.resume(with: .failure(JavaScriptTimeout(seconds: timeout))) {
                        self?.tearDown()
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if gate.resume(with: .failure(CancellationError())) {
                    self?.tearDown()
                }
            }
        }
    }

    private static func decode(_ value: Any?) -> JavaScriptRun {
        let dictionary = value as? [String: Any] ?? [:]
        return JavaScriptRun(
            logs: dictionary["logs"] as? [String] ?? [],
            result: dictionary["result"] as? String,
            error: dictionary["error"] as? String
        )
    }

    /// Ends the page and, with the last reference to the view, its web content process.
    private func tearDown() {
        guard let webView else { return }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        self.webView = nil
        finishLoading()
    }

    public nonisolated func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            let body = message.body as? [String: Any] ?? [:]
            let path = body["path"] as? String ?? "."
            do {
                switch body["op"] as? String {
                case "read": replyHandler(try read(path), nil)
                case "list": replyHandler(try list(path), nil)
                default: replyHandler(nil, "Unknown workspace operation")
                }
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        }
    }

    private func read(_ path: String) throws -> String {
        guard let workspace else { throw WorkspaceError("This agent has no workspace.") }
        let url = try workspace.resolve(path)
        let data = try Data(contentsOf: url)
        guard data.count <= 5 * 1024 * 1024 else { throw WorkspaceError("\(path) is over 5MB.") }
        return String(decoding: data, as: UTF8.self)
    }

    private func list(_ path: String) throws -> [String] {
        guard let workspace else { throw WorkspaceError("This agent has no workspace.") }
        let url = try workspace.resolve(path)
        return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted().map { name in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path, isDirectory: &isDirectory)
            return isDirectory.boolValue ? name + "/" : name
        }
    }
}

/// Resumes a continuation once, from whichever of the result, the timeout or a cancellation comes first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pending: Result<Value, Error>?
    private var done = false

    func set(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    /// Returns whether this call resumed it.
    @discardableResult
    func resume(with result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard !done else {
            lock.unlock()
            return false
        }
        done = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pending = result
            lock.unlock()
        }
        return true
    }
}
