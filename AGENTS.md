# AGENTS.md - Jido Chat Discord Development Guide

`jido_chat_discord` is the Discord adapter for `Jido.Chat`.

## Commands

- `mix setup` - Fetch dependencies.
- `mix test` - Run the default non-live test suite.
- `mix test --include live` - Run explicitly enabled live Discord tests.
- `mix quality` - Run the Jido package quality gate.
- `mix coveralls` - Run coverage.
- `mix install_hooks` - Explicitly install local git hooks.

## Rules

- Keep live Discord tests excluded by default with the `:live` tag.
- Do not commit `.env` or credentials.
- Prefer `Jido.Chat.Adapter` callbacks for shared behavior.
- Preserve the adapter boundary; supervised runtime concerns belong in `jido_messaging`.
