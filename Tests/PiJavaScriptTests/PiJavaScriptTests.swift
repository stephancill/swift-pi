import Foundation
import PiAgent
import PiAI
import PiJavaScript
import PiTools
import Testing

@Suite(.serialized) @MainActor struct JavaScriptTests {
    func workspace() throws -> Workspace {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("js-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
        try Data("{\"n\": 41}".utf8).write(to: root.appendingPathComponent("data/n.json"))
        return Workspace(root: root)
    }

    @Test func returnsValuesAndLogs() async throws {
        let run = try await JavaScriptRunner.run(code: "console.log('hi', 1 + 1); return { sum: [1, 2, 3].reduce((a, b) => a + b) };", timeout: 10, workspace: nil)
        #expect(run.logs == ["hi 2"])
        #expect(run.result == #"{"sum":6}"#)
        #expect(run.error == nil)
    }

    @Test func awaitsAndReadsTheWorkspace() async throws {
        let code = """
        const names = await workspace.list("data");
        const n = JSON.parse(await workspace.read("data/n.json")).n;
        return `${names.join(",")} ${n + 1}`;
        """
        let run = try await JavaScriptRunner.run(code: code, timeout: 10, workspace: workspace())
        #expect(run.result == "n.json 42")
    }

    @Test func confinesReadsToTheWorkspace() async throws {
        let run = try await JavaScriptRunner.run(code: "return await workspace.read('../../etc/hosts');", timeout: 10, workspace: workspace())
        #expect(run.error?.contains("outside the workspace") == true)
    }

    @Test func reportsErrors() async throws {
        let syntax = try await JavaScriptRunner.run(code: "return (;", timeout: 10, workspace: nil)
        #expect(syntax.error?.contains("SyntaxError") == true)
        let thrown = try await JavaScriptRunner.run(code: "throw new TypeError('nope')", timeout: 10, workspace: nil)
        #expect(thrown.error?.hasPrefix("TypeError: nope") == true)
    }

    @Test func stopsRunawayCode() async throws {
        let started = ContinuousClock.now
        await #expect(throws: JavaScriptTimeout.self) {
            try await JavaScriptRunner.run(code: "while (true) {}", timeout: 1, workspace: nil)
        }
        #expect(ContinuousClock.now - started < .seconds(5))
        // A later run still works.
        let run = try await JavaScriptRunner.run(code: "return 'ok'", timeout: 10, workspace: nil)
        #expect(run.result == "ok")
    }

    @Test func toolReportsResultsAndErrors() async throws {
        let tool = javaScriptTool(workspace: nil)
        let ok = try await tool.execute("1", ["code": "console.log('x'); return 7;"]) { _ in }
        #expect(contentText(ok.content) == "Console:\nx\n\nResult: 7")
        #expect(!ok.isError)
        let failed = try await tool.execute("1", ["code": "null.x"]) { _ in }
        #expect(failed.isError)
        #expect(contentText(failed.content).hasPrefix("Error: TypeError"))
    }
}
