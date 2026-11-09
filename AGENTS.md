# swift pi

A Swift port of pi (github.com/earendil-works/pi) for apps that run an agent on the device. Consumers: stupid agent (`../stupid-agent`), which vendors tagged releases.

## Before changing anything

- Read `docs/IMPLEMENTATION.md`: the layout, and every deliberate difference from pi.
- When porting or changing behavior pi has, read pi's TypeScript first and keep its semantics, error messages and event order. Record any deviation in `docs/IMPLEMENTATION.md` § Differences from pi.

## Stack and style

- Swift 6 with strict concurrency, Swift Package Manager, no dependencies. iOS 18 / macOS 15.
- Modules: `PiAI` (provider-facing types and providers), `PiAgent` (loop and `Agent`), `PiTools` (tools). Keep `PiAI` free of agent concepts and `PiAgent` free of tool implementations.
- Value types and `Sendable` everywhere. Use structs and enums; classes only where identity is needed (the event stream). Use actors for mutable shared state.
- Named parameters. No force unwraps outside tests.
- Doc comments on public API say what something is or does, briefly.
- Format with `swift format` if configured; otherwise match the surrounding code.

## Testing

- `swift test` must pass. Add tests with every behavior change:
  - provider tests use `MockURLProtocol`
  - loop tests use `FauxProvider`
  - tool tests use temporary workspaces
- Check the iOS build: `xcodebuild -scheme SwiftPi-Package -destination 'generic/platform=iOS Simulator' build | xcpretty`.

## Before committing

- Update `docs/IMPLEMENTATION.md` to describe the current state. Never include personal information: assume it is public.
- Use conventional commits (`feat:`, `fix:`, `chore:`, ...).
- Releases are tags `vX.Y.Z`. Consumers vendor a tag, so tag after changes they need.
