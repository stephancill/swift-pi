import Foundation

public struct WorkspaceError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }

    public init(_ message: String) {
        self.message = message
    }
}

/// The directory the file tools work in. Every path resolves inside it: relative paths from its root, absolute paths
/// only when they point inside it, and symlinks only when their targets stay inside it.
public struct Workspace: Sendable, Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// The URL for a path the model gave, or an error when it leaves the workspace.
    public func resolve(_ path: String) throws -> URL {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        // Models sometimes write `@file` the way users mention files.
        if path.hasPrefix("@") { path.removeFirst() }
        if path == "~" || path.hasPrefix("~/") { path = String(path.dropFirst(min(2, path.count))) }

        let url: URL
        if path.hasPrefix("/") {
            url = URL(fileURLWithPath: path)
        } else {
            url = path.isEmpty || path == "." ? root : root.appendingPathComponent(path)
        }
        let resolved = Self.resolvingExistingAncestor(url.standardizedFileURL)
        guard contains(resolved) else {
            throw WorkspaceError("Path \(path) is outside the workspace. Use a path relative to the workspace root.")
        }
        return resolved
    }

    /// Resolves symlinks in the deepest part of the path that exists and appends the rest, so a file about to be
    /// created resolves the same way as its existing parent (`/var` → `/private/var`).
    static func resolvingExistingAncestor(_ url: URL) -> URL {
        var existing = url
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in missing {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    public func contains(_ url: URL) -> Bool {
        let rootPath = root.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    /// The path relative to the root, for output.
    public func relativePath(_ url: URL) -> String {
        let rootPath = root.path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path == rootPath { return "." }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

/// Serializes changes to one file, so parallel edits of the same file don't overwrite each other.
actor FileMutationQueue {
    static let shared = FileMutationQueue()

    private var tails: [String: Task<Void, Never>] = [:]

    func run<T: Sendable>(_ path: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tails[path]
        let task = Task<Result<T, Error>, Never> {
            await previous?.value
            do { return try .success(await operation()) } catch { return .failure(error) }
        }
        tails[path] = Task { _ = await task.value }
        return try await task.value.get()
    }
}
