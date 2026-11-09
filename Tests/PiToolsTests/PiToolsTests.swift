import Foundation
import PiAgent
import PiAI
@testable import PiTools
import Testing

struct TempWorkspace {
    let workspace: Workspace
    let tools: [String: AgentTool]

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pi-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workspace = Workspace(root: root)
        tools = Dictionary(uniqueKeysWithValues: fileTools(workspace: workspace).map { ($0.name, $0) })
    }

    func write(_ path: String, _ content: String) throws {
        let url = workspace.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    func contents(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: workspace.root.appendingPathComponent(path)), as: UTF8.self)
    }

    func run(_ name: String, _ arguments: JSONObject) async throws -> String {
        let tool = try #require(tools[name])
        let validated = try validateToolArguments(tool: tool.declaration, toolCall: ToolCall(id: "t", name: name, arguments: tool.prepareArguments?(arguments) ?? arguments))
        let result = try await tool.execute("t", validated) { _ in }
        return contentText(result.content)
    }
}

@Suite struct WorkspaceTests {
    @Test func confinesPaths() throws {
        let temp = try TempWorkspace()
        #expect(try temp.workspace.resolve("a/b.txt").path.hasSuffix("/a/b.txt"))
        #expect(try temp.workspace.resolve("@notes.md").lastPathComponent == "notes.md")
        #expect(try temp.workspace.resolve(temp.workspace.root.path + "/x").lastPathComponent == "x")
        #expect(throws: WorkspaceError.self) { try temp.workspace.resolve("../escape.txt") }
        #expect(throws: WorkspaceError.self) { try temp.workspace.resolve("/etc/hosts") }
    }

    @Test func rejectsSymlinksOutOfTheWorkspace() throws {
        let temp = try TempWorkspace()
        try FileManager.default.createSymbolicLink(at: temp.workspace.root.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        #expect(throws: WorkspaceError.self) { try temp.workspace.resolve("link/hosts") }
    }
}

@Suite struct FileToolTests {
    @Test func writeThenRead() async throws {
        let temp = try TempWorkspace()
        let written = try await temp.run("write", ["path": "dir/note.txt", "content": "one\ntwo\nthree\n"])
        #expect(written.contains("Successfully wrote"))
        #expect(try await temp.run("read", ["path": "dir/note.txt"]) == "one\ntwo\nthree")
        #expect(try await temp.run("read", ["path": "dir/note.txt", "offset": 2, "limit": 1]) == "two\n\n[1 more lines in file. Use offset=3 to continue.]")
    }

    @Test func readTruncatesLongFiles() async throws {
        let temp = try TempWorkspace()
        try temp.write("big.txt", (1 ... 2500).map { "line \($0)" }.joined(separator: "\n"))
        let output = try await temp.run("read", ["path": "big.txt"])
        #expect(output.hasSuffix("[Showing lines 1-2000 of 2500. Use offset=2001 to continue.]"))
    }

    @Test func readsImagesAsAttachments() async throws {
        let temp = try TempWorkspace()
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: temp.workspace.root.appendingPathComponent("pic.png"))
        let tool = try #require(temp.tools["read"])
        let result = try await tool.execute("t", ["path": "pic.png"]) { _ in }
        #expect(result.content.contains { if case .image = $0 { true } else { false } })
    }

    @Test func editsWithExactAndFuzzyMatching() async throws {
        let temp = try TempWorkspace()
        try temp.write("code.swift", "let a = 1\nlet b = 2\nlet c = 3\n")
        _ = try await temp.run("edit", ["path": "code.swift", "edits": [["oldText": "let a = 1", "newText": "let a = 10"], ["oldText": "let c = 3", "newText": "let c = 30"]]])
        #expect(try temp.contents("code.swift") == "let a = 10\nlet b = 2\nlet c = 30\n")

        // The older single-edit shape.
        _ = try await temp.run("edit", ["path": "code.swift", "oldText": "let b = 2", "newText": "let b = 20"])
        #expect(try temp.contents("code.swift").contains("let b = 20"))

        // Smart quotes in the model's copy still match.
        try temp.write("quote.txt", "say \"hi\"\n")
        _ = try await temp.run("edit", ["path": "quote.txt", "edits": [["oldText": "say \u{201C}hi\u{201D}", "newText": "say \"bye\""]]])
        #expect(try temp.contents("quote.txt") == "say \"bye\"\n")
    }

    @Test func editErrorsMatchPi() async throws {
        let temp = try TempWorkspace()
        try temp.write("dup.txt", "x\nx\n")
        await #expect { try await temp.run("edit", ["path": "dup.txt", "edits": [["oldText": "x", "newText": "y"]]]) } throws: { error in
            error.localizedDescription.contains("Found 2 occurrences")
        }
        await #expect { try await temp.run("edit", ["path": "dup.txt", "edits": [["oldText": "zzz", "newText": "y"]]]) } throws: { error in
            error.localizedDescription.contains("Could not find the exact text")
        }
    }

    @Test func editKeepsCRLF() throws {
        let result = try applyEdits([TextEdit(oldText: "b", newText: "B")], to: "a\r\nb\r\n", path: "f")
        #expect(result.content == "a\r\nB\r\n")
        #expect(result.firstChangedLine == 2)
    }

    @Test func listsDirectories() async throws {
        let temp = try TempWorkspace()
        try temp.write("b.txt", "")
        try temp.write("a/inner.txt", "")
        try temp.write(".hidden", "")
        #expect(try await temp.run("ls", [:]) == ".hidden\na/\nb.txt")
    }

    @Test func findsFilesByGlob() async throws {
        let temp = try TempWorkspace()
        try temp.write("src/a.swift", "")
        try temp.write("src/deep/b.swift", "")
        try temp.write("readme.md", "")
        try temp.write(".git/config", "")
        #expect(try await temp.run("find", ["pattern": "*.swift"]) == "src/a.swift\nsrc/deep/b.swift")
        #expect(try await temp.run("find", ["pattern": "src/*.swift"]) == "src/a.swift")
        #expect(try await temp.run("find", ["pattern": "*.{md,swift}", "path": "src/deep"]) == "b.swift")
        #expect(try await temp.run("find", ["pattern": "config"]) == "No files found matching pattern")
    }

    @Test func grepsContents() async throws {
        let temp = try TempWorkspace()
        try temp.write("one.txt", "alpha\nbeta\ngamma\n")
        try temp.write("two.md", "Beta release\n")
        try Data([0, 1, 2, 0x62, 0x65, 0x74, 0x61]).write(to: temp.workspace.root.appendingPathComponent("bin.dat"))
        #expect(try await temp.run("grep", ["pattern": "beta"]) == "one.txt:2: beta")
        #expect(try await temp.run("grep", ["pattern": "beta", "ignoreCase": true]).components(separatedBy: "\n").sorted() == ["one.txt:2: beta", "two.md:1: Beta release"])
        #expect(try await temp.run("grep", ["pattern": "beta", "context": 1]) == "one.txt-1- alpha\none.txt:2: beta\none.txt-3- gamma")
        #expect(try await temp.run("grep", ["pattern": "a.p", "literal": true]) == "No matches found")
        #expect(try await temp.run("grep", ["pattern": "Beta", "glob": "*.md"]) == "two.md:1: Beta release")
    }
}
