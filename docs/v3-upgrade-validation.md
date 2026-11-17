# Jido Chat V3 validation: Discord

Date: 2026-11-16 (America/Chicago).

## Scope

The Discord `release/v3` branch is validated against the current sibling
`../jido_chat` working tree. The core uses consolidated Jido V3. This is local
integration evidence. It is not Hex publication or live provider evidence.

The adapter keeps these V3 boundaries:

- one stateless `Jido.Chat.Adapter` for REST operations;
- strict native or unsupported capability values;
- typed core and Discord extension Actions and Signals;
- one `Jido.Chat.Sensor.Source` for host-started Gateway input;
- a linked Gateway worker for connection state, heartbeats, and resume;
- provider credentials in `Client.credentials`;
- adapter settings in `Client.config`;
- provider transport in `Client.transport`;
- managed Room and provider runtime in Jido Chat core.

## Current migration changes

- Replaced the fixed remote Jido Chat source with `path: "../jido_chat"` for
  every local environment.
- Removed the stale Jido Chat lock entry and selected the consolidated Jido V3
  commit required by the local core.
- Replaced the removed credential-merging client helper with explicit field
  access in REST operations, normalization, and Gateway discovery.
- Kept bot identity settings in `Client.config` and the bot token in
  `Client.credentials`.
- Made a missing or empty bot token return no Source key and reject Gateway
  worker startup.
- Added direct evidence that REST and Gateway transport options contain adapter
  config but no token or credentials key.
- Updated package rules and README content for the Jido Chat-owned managed
  Runtime boundary.

## Offline evidence

Normal tests use fixed fixtures, recording transports, and a local WebSocket
peer. They make no Discord request. Live tests keep the `:live` tag and remain
excluded by default.

The current offline result is 67 tests passed and 12 live tests excluded.
Covenant passes 21 tests and all 20 contract obligations. Coverage is 93.5%.
Quality, HTML and Markdown documentation, production compile, unused
dependency, compile-graph, dependency-tree, retired-reference, diff, and
design-review checks pass. The compile graph has 17 files, three compile
edges, and no cycles. Production compilation reports dependency compiler
warnings only.

## Dependency boundary

```text
jido_chat_discord
└── jido_chat (path: ../jido_chat)
    └── jido (consolidated V3 source selected by Jido Chat)
```

The adapter lock contains no Jido Chat remote source. Package publication must
later replace the local path with the released Jido Chat V3 Hex constraint and
repeat the same gates.

## Live evidence

No live or paid provider call ran. Discord credentials, permissions, remote
REST delivery, webhooks, the production Gateway, and external service behavior
are not verified by this local unit.
