# LLM Usage Rules for Jido Chat Discord

`jido_chat_discord` adapts Discord behavior to the `Jido.Chat.Adapter` contract.

## Working Rules

- Keep shared chat behavior in `Jido.Chat.Adapter` callbacks.
- Keep live API tests tagged `:live` and excluded by default.
- Do not commit `.env` or token values.
- Treat Discord threads as channel targets unless core adapter APIs explicitly add a richer abstraction.
- Preserve the adapter boundary; runtime supervision belongs in `jido_messaging`.
- Run `mix test`, `mix quality`, and `mix coveralls` before release work.
