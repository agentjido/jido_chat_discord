# Jido Chat Discord usage rules

- Build immutable `Jido.Chat.Client` values with explicit private credentials.
- Use request Signals and core Chat Actions. Use `Jido.ChatAction` for extensions.
- Discover native operations with `Jido.Chat.Discord.operations/0`.
- Normalize private provider input with `Jido.Chat.normalize/2`.
- Use the shared `Jido.Chat.Sensor` with `Jido.Chat.Discord.Source` for Gateway input.
- Let the host own supervision, credentials, retries, reply logic, and protocol ACKs.
- Keep tokens and signed attachment URLs out of public Signals.
- Supply the Inspect-redacted `Interaction` through private `:interaction` execution options. Do not pass bare token options.
- Use an explicit host Source `:interaction_sink` for fresh Gateway interaction controls.
- Keep the host store bounded. Enforce room checks, atomic use, expiry, and cleanup.
- Do not assume the standard Agent Plugin supplies per-interaction private options.
- Run `mix test.contracts` and `mix covenant.check --static` for contract changes.
- Do not restore Binding, resource registries, option structs, or direct adapter send APIs.
- Keep live tests tagged `:live` and excluded by default. Never commit `.env`.
- Use only local Jido V3 code for integration work. Do not change `CHANGELOG.md`.
