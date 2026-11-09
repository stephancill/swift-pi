import Foundation
import Synchronization

/// What a provider reports while it streams one assistant response.
///
/// A successful stream emits `start` before any update and ends with `done`. A stream may end directly with
/// `error` when the request fails before generation starts; after `start`, failures also end with `error`.
/// `partial` is the response so far at the time of the event.
public enum AssistantMessageEvent: Sendable {
    case start(partial: AssistantMessage)
    case textStart(contentIndex: Int, partial: AssistantMessage)
    case textDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case textEnd(contentIndex: Int, content: String, partial: AssistantMessage)
    case thinkingStart(contentIndex: Int, partial: AssistantMessage)
    case thinkingDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case thinkingEnd(contentIndex: Int, content: String, partial: AssistantMessage)
    case toolCallStart(contentIndex: Int, partial: AssistantMessage)
    case toolCallDelta(contentIndex: Int, delta: String, partial: AssistantMessage)
    case toolCallEnd(contentIndex: Int, toolCall: ToolCall, partial: AssistantMessage)
    /// `reason` is `stop`, `length` or `toolUse`.
    case done(reason: StopReason, message: AssistantMessage)
    /// `reason` is `aborted` or `error`; the message carries `errorMessage`.
    case error(reason: StopReason, error: AssistantMessage)

    /// The response as of this event.
    public var message: AssistantMessage {
        switch self {
        case let .start(partial), let .textStart(_, partial), let .textDelta(_, _, partial), let .textEnd(_, _, partial),
             let .thinkingStart(_, partial), let .thinkingDelta(_, _, partial), let .thinkingEnd(_, _, partial),
             let .toolCallStart(_, partial), let .toolCallDelta(_, _, partial), let .toolCallEnd(_, _, partial):
            partial
        case let .done(_, message): message
        case let .error(_, message): message
        }
    }
}

/// One assistant response as it streams: iterate it for events (once), or await `result()` for the final message.
public final class AssistantMessageEventStream: AsyncSequence, Sendable {
    public typealias Element = AssistantMessageEvent

    private struct State {
        var final: AssistantMessage?
        var waiters: [CheckedContinuation<AssistantMessage, Never>] = []
        var startedAt: ContinuousClock.Instant?
    }

    private let stream: AsyncStream<AssistantMessageEvent>
    private let continuation: AsyncStream<AssistantMessageEvent>.Continuation
    private let state = Mutex(State())

    public init() {
        (stream, continuation) = AsyncStream.makeStream(of: AssistantMessageEvent.self, bufferingPolicy: .unbounded)
    }

    /// Adds an event. `done` and `error` also settle `result()`, stamped with the response's duration.
    public func push(_ event: AssistantMessageEvent) {
        var event = event
        switch event {
        case .start:
            state.withLock { $0.startedAt = $0.startedAt ?? .now }
        case let .done(reason, message):
            let message = stamped(message)
            event = .done(reason: reason, message: message)
            settle(message)
        case let .error(reason, message):
            let message = stamped(message)
            event = .error(reason: reason, error: message)
            settle(message)
        default:
            break
        }
        continuation.yield(event)
    }

    /// Ends the stream. A stream that ends without `done` or `error` settles as an error.
    public func end() {
        continuation.finish()
        let unsettled = state.withLock { $0.final == nil }
        if unsettled {
            settle(AssistantMessage(api: "unknown", provider: "unknown", model: "unknown", stopReason: .error, errorMessage: "Stream ended without a result"))
        }
    }

    /// The final message: the one `done` or `error` carried.
    public func result() async -> AssistantMessage {
        await withCheckedContinuation { waiter in
            let final = state.withLock { state -> AssistantMessage? in
                if let final = state.final { return final }
                state.waiters.append(waiter)
                return nil
            }
            if let final { waiter.resume(returning: final) }
        }
    }

    public func makeAsyncIterator() -> AsyncStream<AssistantMessageEvent>.Iterator {
        stream.makeAsyncIterator()
    }

    private func stamped(_ message: AssistantMessage) -> AssistantMessage {
        guard message.durationMs == nil, let startedAt = state.withLock({ $0.startedAt }) else { return message }
        var message = message
        let elapsed = ContinuousClock.now - startedAt
        message.durationMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return message
    }

    private func settle(_ message: AssistantMessage) {
        let waiters = state.withLock { state -> [CheckedContinuation<AssistantMessage, Never>] in
            guard state.final == nil else { return [] }
            state.final = message
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume(returning: message)
        }
    }
}
