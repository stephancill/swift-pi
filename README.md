# swift pi

A Swift port of the core of [pi](https://github.com/earendil-works/pi), the coding agent by Earendil Works, for iOS and macOS apps that run an agent on the device. It has no dependencies.

| Module | What it is | pi package |
| --- | --- | --- |
| `PiAI` | Messages, models, the streaming event protocol, transcript helpers, tool argument validation, and the OpenAI-compatible Chat Completions provider | `pi-ai` |
| `PiAgent` | The agent loop and the stateful `Agent`: tool execution, hooks, steering and follow-up queues | `pi-agent-core` |
| `PiTools` | `read`, `write`, `edit`, `ls`, `find` and `grep`, confined to a workspace directory; `web_search` and `web_fetch` | `pi-coding-agent` tools |
| `PiJavaScript` | `javascript`: runs code in WebKit, with read-only access to the workspace | (new) |

There is no shell tool: iOS apps can't start other programs. `javascript` covers calculations and data processing.

## Requirements

iOS 18 or macOS 15, Swift 6.

## Install

```swift
.package(url: "https://github.com/stephancill/swift-pi.git", from: "0.1.1")
```

Then depend on `PiAI`, `PiAgent` and `PiTools` as needed.

## Use

```swift
import PiAgent
import PiAI
import PiJavaScript
import PiTools

// Any OpenAI-compatible server: OpenAI, OpenRouter, Groq, DeepSeek, Ollama, LM Studio, vLLM, llama.cpp, ...
let model = Model(id: "openai/gpt-4o-mini", provider: "openrouter", baseURL: "https://openrouter.ai/api/v1")

let workspace = Workspace(root: documentsDirectory)
let agent = Agent(
    model: model,
    systemPrompt: "You are a helpful assistant with access to files in the user's workspace.",
    tools: fileTools(workspace: workspace) + webTools() + [javaScriptTool(workspace: workspace)],
    streamOptions: StreamOptions(apiKey: apiKey)
)

let events = await agent.events()
Task {
    for await event in events {
        switch event {
        case let .messageUpdate(message, _): render(message)        // streaming assistant text
        case let .toolExecutionStart(_, name, arguments): show(name, arguments)
        case .agentEnd: break
        default: break
        }
    }
}

try await agent.prompt("Summarize notes.md")
```

- **Steering:** `agent.steer(.user("..."))` queues a message for after the current tool batch.
- **Follow-ups:** `agent.followUp(...)` runs once the agent would otherwise stop.
- **Abort:** `agent.abort()` cancels the run. The streaming response ends as `aborted`, and running tools are cancelled.
- **Permissions:** set `agent.beforeToolCall` to block a call (e.g. after asking the user). `afterToolCall` rewrites results.
- **Your own tools:** an `AgentTool` is a name, a description, a JSON Schema and an async `execute` closure. Arguments are validated and coerced against the schema before `execute` runs.
- **Saving a conversation:** `agent.state.messages` is `Codable`, in the same JSON shape as pi's transcripts.

### Web and JavaScript tools

- `web_search` asks a hosted search that needs no API key, the ones opencode uses: Exa (`https://mcp.exa.ai/mcp`, the default) or Parallel (`https://search.parallel.ai/mcp`), through their MCP servers (`webTools(searchProvider:)`).
- `web_fetch` returns a URL as Markdown (default), text or HTML, up to 5MB fetched and the usual 50KB to the model. HTTP is upgraded to HTTPS.
- `javascript` runs code as the body of an async function in a fresh offscreen `WKWebView`: `return` a value, `console.log`, and `await workspace.read(path)` / `workspace.list(path)`. It can't change files. A run stops at its timeout (default 10s, at most 60) or when the agent is aborted, which ends its web content process.

### Models

`Model` describes where a model is and what it can do. Compatibility differences between OpenAI-compatible servers are detected from the base URL. Override them with `OpenAICompletionsCompat`:

```swift
Model(
    id: "llama3.2",
    provider: "ollama",
    baseURL: "http://localhost:11434/v1",
    compat: OpenAICompletionsCompat(maxTokensField: .maxTokens)
)
```

## Differences from pi

See [docs/IMPLEMENTATION.md](docs/IMPLEMENTATION.md). In short:

- one provider API so far (OpenAI Chat Completions)
- Swift task cancellation instead of `AbortSignal`
- a JSON Schema subset for validation
- no shell, image resizing or `.gitignore` support in the tools

## License

MIT. pi is © Mario Zechner, MIT.
