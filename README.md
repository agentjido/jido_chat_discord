# Jido Chat Discord

`jido_chat_discord` is the Discord adapter package for `jido_chat`.

## Experimental Status

This package is experimental and pre-1.0. APIs and behavior will change.
It is part of the Elixir implementation aligned to the Vercel Chat SDK
([chat-sdk.dev/docs](https://www.chat-sdk.dev/docs)).

`Jido.Chat.Discord.Adapter` is the canonical adapter module and uses `Nostrum` as the Discord client.

## Installation

```elixir
def deps do
  [
    {:jido_chat, github: "agentjido/jido_chat", branch: "main"},
    {:jido_chat_discord, github: "agentjido/jido_chat_discord", branch: "main"}
  ]
end
```

## Usage

```elixir
alias Jido.Chat.Discord.Adapter

{:ok, incoming} =
  Adapter.transform_incoming(%{
    channel_id: 123,
    id: 456,
    content: "hello",
    guild_id: 999,
    author: %{id: 321, username: "alice", global_name: "Alice"}
  })

{:ok, sent} = Adapter.send_message(123, "hi")
```

## Live Integration Test

There is a live test module at:

- `test/jido/chat/discord/live_integration_test.exs`

It is skipped by default. To run it:

1. Copy and fill local env file:

```bash
cp .env.example .env
```

2. Run:

```bash
mix test test/jido/chat/discord/live_integration_test.exs --include live
```

Current live coverage includes:

- send, edit, fetch, and delete
- typing and metadata
- stream fallback through core `Jido.Chat.Adapter.stream/4`
- reply continuity through Discord `message_reference`
- reaction add/remove
- canonical single-file upload through `send_file/3`
- canonical single-file post through core `post_message/4`
- optional DM open when `DISCORD_TEST_USER_ID` is set

## Ingress Modes (`listener_child_specs/2`)

`Jido.Chat.Discord.Adapter.listener_child_specs/2` supports:

- `ingress.mode = "webhook"`: no listener workers (`{:ok, []}`), host HTTP handles ingress.
- `ingress.mode = "gateway"`:
  - default `ingress.source = "nostrum"`: starts
    - `NostrumGatewayBuffer`
    - `NostrumGatewayListener` (subscribes to `Nostrum.ConsumerGroup`)
    - `GatewayWorker` (consumes buffered events and emits via `sink_mfa`)
  - optional `ingress.source = "mfa"` with `ingress.event_source_mfa`.

Example:

```elixir
{:ok, specs} =
  Jido.Chat.Discord.Adapter.listener_child_specs("bridge_dc",
    ingress: %{mode: "gateway", source: "nostrum"},
    sink_mfa: {Jido.Messaging.IngressSink, :emit, [MyApp.Messaging, "bridge_dc"]}
  )
```
