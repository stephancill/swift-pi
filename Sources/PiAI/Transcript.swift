import Foundation

// Replaying system messages: the leading system message is the prompt, later ones change it.

/// The leading system message for a prompt and tool set; nil when both are empty, so an empty transcript stays empty.
public func createInitialSystemMessage(systemPrompt: String?, tools: [Tool]?) -> SystemMessage? {
    let hasPrompt = !(systemPrompt ?? "").isEmpty
    let hasTools = !(tools ?? []).isEmpty
    guard hasPrompt || hasTools else { return nil }
    return SystemMessage(content: systemPrompt ?? "", toolsAdded: hasTools ? tools : nil, timestamp: 0)
}

/// The tools available after applying every system message's changes in order.
public func getCurrentTools(_ messages: [Message]) -> [Tool] {
    var order: [String] = []
    var tools: [String: Tool] = [:]
    for case let .system(message) in messages {
        for removed in message.toolsRemoved ?? [] {
            tools[removed.name] = nil
            order.removeAll { $0 == removed.name }
        }
        for added in message.toolsAdded ?? [] {
            if tools[added.name] == nil { order.append(added.name) }
            tools[added.name] = added
        }
    }
    return order.compactMap { tools[$0] }
}

/// Every system message replayed into one: the current prompt, sections and tools.
public func getCurrentSystemMessage(_ messages: [Message]) -> SystemMessage? {
    var content: [String] = []
    var sectionOrder: [String] = []
    var sections: [String: String] = [:]
    var timestamp: Timestamp?
    for case let .system(message) in messages {
        timestamp = timestamp ?? message.timestamp
        if !message.content.isEmpty { content.append(message.content) }
        for section in message.sections ?? [] {
            if let text = section.text {
                if sections[section.name] == nil { sectionOrder.append(section.name) }
                sections[section.name] = text
            } else {
                sections[section.name] = nil
                sectionOrder.removeAll { $0 == section.name }
            }
        }
    }
    let tools = getCurrentTools(messages)
    guard timestamp != nil || !tools.isEmpty else { return nil }
    let replayedSections = sectionOrder.map { SystemSection(name: $0, text: sections[$0]) }
    return SystemMessage(
        content: content.joined(separator: "\n\n"),
        sections: replayedSections.isEmpty ? nil : replayedSections,
        toolsAdded: tools.isEmpty ? nil : tools,
        timestamp: timestamp ?? 0
    )
}

/// A system message as a complete prompt: its content followed by its sections.
public func systemMessageText(_ message: SystemMessage) -> String {
    ([message.content] + (message.sections ?? []).compactMap(\.text)).filter { !$0.isEmpty }.joined(separator: "\n\n")
}

/// A later system message for APIs that accept system messages mid-conversation, with section changes framed by name.
public func renderSystemMessageUpdate(_ message: SystemMessage) -> String {
    var parts: [String] = []
    if !message.content.isEmpty { parts.append(message.content) }
    for section in message.sections ?? [] {
        if let text = section.text {
            parts.append("Updated system prompt section \"\(section.name)\":\n\n\(text)")
        } else {
            parts.append("Removed system prompt section \"\(section.name)\".")
        }
    }
    return parts.joined(separator: "\n\n")
}

/// The current system prompt text after replaying every system message.
public func getCurrentSystemPrompt(_ messages: [Message]) -> String {
    getCurrentSystemMessage(messages).map(systemMessageText) ?? ""
}

/// The transcript for APIs without mid-conversation system messages: the replayed system message leads, and every
/// later system message is dropped.
public func collapseSystemMessages(_ context: TranscriptContext) -> TranscriptContext {
    let head = getCurrentSystemMessage(context.messages)
    let rest = context.messages.filter { if case .system = $0 { false } else { true } }
    return TranscriptContext(transcript: (head.map { [Message.system($0)] } ?? []) + rest)
}

/// Tools added and removed between two complete tool states. A changed definition is a removal and an addition.
public struct ToolStateChanges: Sendable, Hashable {
    public var toolsAdded: [Tool]
    public var toolsRemoved: [ToolReference]

    public var isEmpty: Bool { toolsAdded.isEmpty && toolsRemoved.isEmpty }
}

public func getToolStateChanges(previous: [Tool], current: [Tool]) -> ToolStateChanges {
    let previousByName = Dictionary(previous.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
    let currentByName = Dictionary(current.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
    return ToolStateChanges(
        toolsAdded: current.filter { previousByName[$0.name] != $0 },
        toolsRemoved: previous.filter { currentByName[$0.name] != $0 }.map { ToolReference(name: $0.name) }
    )
}

/// The text blocks of user content, joined.
public func contentText(_ content: [UserContent], separator: String = "\n") -> String {
    content.compactMap { if case let .text(block) = $0 { block.text } else { nil } }.joined(separator: separator)
}
