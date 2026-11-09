# Implementation notes

A Swift port of pi's `pi-ai`, `pi-agent-core` and the file tools of `pi-coding-agent`. Ported from pi at commit `2cac4f1a934cdc4a80b05a7d8ff2543cf5ee623c` (pi 1.5.0). Behavior follows pi unless listed below. When porting more of pi, read the TypeScript first and keep its semantics, error texts and event order.

## Layout

- `Sources/PiAI`
  - `JSONValue.swift`: JSON for arguments, schemas and details. Serialized with sorted keys, so the same value always produces the same bytes (stable prompt caching).
  - `Types.swift`: content blocks, messages, `Usage`, `Model`, `OpenAICompletionsCompat`, `Context`/`TranscriptContext`, `StreamOptions`.
  - `Coding.swift`: `Codable` with pi's discriminators (`role` on messages, `type` on blocks). It reads a plain-string user `content` the way pi writes it.
  - `EventStream.swift`: `AssistantMessageEvent` and `AssistantMessageEventStream`. The stream is iterable once; `result()` settles on `done`/`error` and stamps `durationMs`.
  - `Transcript.swift`: system message replay, `collapseSystemMessages`, `getToolStateChanges`.
  - `Validation.swift`: argument validation with coercion.
  - `PartialJSON.swift`: parses streamed tool arguments.
  - `OpenAICompletions.swift`: the provider.
  - `Stream.swift`: `StreamFunction`, `streamSimple` (dispatch on `model.api`), `complete`.
- `Sources/PiAgent`
  - `Types.swift`: `AgentMessage` (a model message or a `CustomAgentMessage`), `AgentTool`, hook contexts, `AgentLoopConfig`, `AgentEvent`.
  - `AgentLoop.swift`: `runAgentLoop`, `runAgentLoopContinue`, `runToolCall`, tool change declarations.
  - `Agent.swift`: the stateful `Agent` actor.
- `Sources/PiTools`
  - `Workspace.swift`: path confinement and the per-file mutation queue.
  - `Truncation.swift`: pi's 2000-line / 50KB limits.
  - `FileTools.swift`: `read`, `write`, `edit`, `ls`, `find`, `grep`.

## Differences from pi

- **Providers.** Only `openai-completions` is ported. Compatibility detection covers OpenAI, OpenRouter, DeepSeek, xAI, Together, Moonshot, Z.ai and Cerebras. These are left out:
  - pi's per-provider thinking formats (zai, qwen, chat templates, deepseek `thinking`)
  - Anthropic cache control through OpenRouter
  - `reasoning_details` replay
  - grammar tools
  - session affinity headers

  Reasoning text goes back in the delta field it arrived in (`thinkingSignature`), as pi does.
- **Mid-conversation system messages.** These are always collapsed into the leading message, matching pi's default for `openai-completions`.
- **Retries.** 429 and 5xx responses are retried up to twice before the stream starts, honoring `Retry-After` up to 60s (pi's `retryProviderRequest`).
- **Cancellation.** Cancelling the task replaces pi's `AbortSignal`. `Agent.abort()` cancels the run task:
  - the provider's request is cancelled and the response ends as `aborted`
  - running tools see cancellation
  - parallel tool calls not yet started report "Operation aborted"
- **Events.** Each event carries a copy of the partial message (Swift value types) instead of pi's shared mutable object. `Agent.events()` is an `AsyncStream` per subscriber; the loop awaits emission into the actor, not the subscribers' handling (pi awaits listeners).
- **Custom messages.** pi extends `AgentMessage` through TypeScript declaration merging. Here it is `.custom(CustomAgentMessage)` with a `kind` and a JSON `payload`, encoded with `role: "custom"`.
- **System sections.** `sections` is an ordered array instead of a JSON object, so order is explicit.
- **Validation.** This is a JSON Schema subset, not pi-schema:
  - keywords: `type`, `properties`, `required`, `items`, `enum`, `const`, `anyOf`/`oneOf`, numeric/length/item bounds, `additionalProperties: false`
  - coercions as pi-schema: strings to numbers/booleans, a single value to an array, `null` for an omitted optional property
  - also: a JSON string to an array or object
- **Tools.**
  - **Paths:** confined to the workspace root. Absolute paths outside it, `..` escapes and symlinks pointing out are rejected; pi resolves any path.
  - **read:** attaches images as they are (no resizing), up to 5MB. Binary files are described rather than dumped.
  - **edit:** when it needs fuzzy matching, it writes the whole file in normalized form; pi keeps unchanged lines' original bytes. CRLF and a BOM are preserved.
  - **find/grep:** walk the directory in Swift instead of running `fd`/`ripgrep`. They skip `.git`, `node_modules`, `.build` and `DerivedData` but don't read `.gitignore`. A `find` pattern without `/` matches file names at any depth (fd's behavior).
  - **Not ported:** bash, PowerShell, codemode, MCP.
- **Not ported:** compaction, sessions, extensions, skills, OAuth, model catalogs, cost catalogs. Apps add these on top through the hooks.

## Testing

`swift test` runs everything on macOS:

- **Providers:** tested against `MockURLProtocol`, which serves canned SSE.
- **Loop:** tested with a scripted `FauxProvider`.
- **Tools:** tested in temporary directories.

To check the iOS build: `xcodebuild -scheme StupidPi-Package -destination 'generic/platform=iOS Simulator' build | xcpretty`.
