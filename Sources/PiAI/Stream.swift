import Foundation

/// Streams one assistant response for a normalized transcript.
///
/// Must not throw: request, model and runtime failures end the returned stream with an `error` event whose message
/// has `stopReason` `error` or `aborted` and an `errorMessage`.
public typealias StreamFunction = @Sendable (Model, TranscriptContext, StreamOptions) async -> AssistantMessageEventStream

/// Streams a response through the provider for `model.api`.
public func streamSimple(model: Model, context: TranscriptContext, options: StreamOptions = StreamOptions()) -> AssistantMessageEventStream {
    switch model.api {
    case OpenAICompletions.api:
        return OpenAICompletions.stream(model: model, context: context, options: options)
    default:
        let stream = AssistantMessageEventStream()
        stream.push(.error(reason: .error, error: AssistantMessage(
            api: model.api,
            provider: model.provider,
            model: model.id,
            stopReason: .error,
            errorMessage: "Unsupported API \"\(model.api)\". Supported: \(OpenAICompletions.api)."
        )))
        stream.end()
        return stream
    }
}

/// Streams a response and returns the final message.
public func complete(model: Model, context: Context, options: StreamOptions = StreamOptions()) async -> AssistantMessage {
    await streamSimple(model: model, context: TranscriptContext(normalizing: context), options: options).result()
}
