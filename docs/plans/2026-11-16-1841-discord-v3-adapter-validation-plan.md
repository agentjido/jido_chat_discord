---
title: Discord adapter current Jido Chat V3 validation
type: implementation-plan
date: 2026-11-16
last_reviewed: 2026-11-16
artifact_contract: kata-plan/v1
artifact_readiness: complete
domain: software
execution: code
product_contract_source: approved-goal
---

# Discord Adapter Current Jido Chat V3 Validation

## Goal Capsule

- Objective: Make the existing Discord `release/v3` migration work with the
  current local Jido Chat V3 source and leave no retired messaging dependency
  or ownership reference.
- Means: Select the local Jido Chat path, resolve client-contract drift, keep
  native Signal and Gateway Source boundaries, update tests and documentation,
  run all offline gates, and complete an Elixir design review.
- Authority: Local Discord and Jido Chat checks and local Discord edits. No
  live Discord request, credential use, commit, push, release, or remote update.
- Stop conditions: Stop before provider I/O, a provider branch in core, a
  second process tree, or a compatibility API.
- Next executor: Elixir package engineer.

## Starting Evidence

- `release/v3` starts clean at `9623cda`. The branch keeps its existing native
  Signal, REST, Gateway, and contract migration history.
- The adapter already implements strict capabilities, `invoke/3`,
  `normalize/3`, extension Actions, event definitions, a Gateway push Source,
  contract fixtures, and offline local WebSocket tests.
- It still selects an older fixed Jido Chat Git source and calls the removed
  credential-merging client helper in operations, normalization, and the
  Gateway worker.
- Package rules and validation text still name the retired package or old core
  source.

## Product Contract

- **R1:** Every local environment selects `path: "../jido_chat"`.
- **R2:** Credentials, config, and transport stay explicit. Tokens do not enter
  public Signals or private transport option lists.
- **R3:** The adapter remains stateless. The Gateway push worker stays owned by
  the host-started `Jido.Chat.Sensor`; managed provider runtime stays in Jido
  Chat core.
- **R4:** Core and Discord extension operations use current typed request and
  result Signals. Unsupported operations stop before REST I/O.
- **R5:** Gateway event admission, normalization identity, thread mapping,
  interaction privacy, reconnect behavior, and local WebSocket protocol tests
  remain offline and deterministic.
- **R6:** A missing or empty bot token cannot create a Source identity or start
  a Gateway worker.
- **R7:** Normal tests make no live Discord request. Live tests remain tagged
  and excluded.
- **R8:** Tests, contracts, coverage, quality, docs, production compile, unused
  dependencies, compile graph, diff check, and design review pass.

## Implementation Units

1. Replace the fixed Jido Chat Git dependency with the sibling local path and
   remove the stale lock entry.
2. Replace the removed client helper with direct use of credentials, config,
   and transport. Add regression evidence for credential separation.
3. Correct obsolete Runtime ownership and dependency validation text.
4. Run all offline gates and an Elixir design review, fix supported findings,
   and repeat affected checks.

## Verification Contract

Run from `/Users/mhostetler/Source/Jido/jido_chat/jido_chat_discord`.

- The normal suite excludes `:live` and makes no provider request.
- Contract, coverage, quality, docs, production compile, unused dependency,
  xref cycle and stats, dependency tree, and diff checks pass.
- The dependency tree resolves Jido Chat from `../jido_chat`.
- Repository search finds no retired package name, removed client helper, old
  V2 constraint, or old Jido Chat Git source.
- No accepted Elixir design-review finding remains.

## Risks and Mitigations

- Risk: the Gateway worker mixes client settings with Source options.
  Mitigation: keep client config and Source options separate and test the exact
  REST and Gateway arguments.
- Risk: live Discord calls enter the normal suite. Mitigation: preserve live
  tags and use fixture transports plus the local WebSocket peer.
- Risk: local path metadata looks publishable. Mitigation: document it as local
  integration evidence and keep publication outside this unit.

## Definition of Done

- R1 through R8 have current evidence.
- Discord uses the same local Jido Chat V3 tree as Telegram and Assembly.
- No live provider check or remote change occurred.

## Execution Result

Completed in the local working tree on 2026-11-16. The branch and HEAD remain
`release/v3` at `9623cda`; no commit was created.

- Selected `../jido_chat` in every environment and removed the stale remote
  Jido Chat lock entry.
- Replaced the removed client option helper with explicit config and transport
  fields in REST operations, normalization, and Gateway discovery.
- Kept bot identity settings in client config and the provider token in
  credentials.
- Kept credentials out of REST and Gateway transport option lists and added
  direct tests for that boundary.
- Made missing and empty tokens reject Source identity and Gateway startup.
- Updated package rules, README content, the packaged operation guide, and
  validation evidence for the Jido Chat-owned Runtime boundary.
- Kept all live tests excluded. No Discord credential or provider endpoint was
  used.

## Design Review Result

The Elixir design review found and fixed three issues.

1. An empty bot token produced a valid Source identity. Missing and empty
   tokens now return no source key and reject Gateway worker startup.
2. The suite did not prove that explicit client field access keeps credentials
   out of REST and Gateway transport options. Tests now prove token and
   credentials keys are absent while normal adapter config remains.
3. The README linked to an operation guide that the package and ExDoc output
   did not include. The package files and ExDoc extras now include the guide.

No accepted finding remains.

## Verification Result

- Focused review-fix tests: 34 passed.
- Full offline suite: 67 passed; 12 live tests excluded.
- Covenant: 21 tests passed; 20 of 20 obligations hold.
- Coverage: 93.5%.
- `mix quality`: passed, including Credo, Dialyzer, and Doctor.
- Documentation: HTML and Markdown generated without a package warning.
- Production compile with warnings as errors: passed. Dependency compiler
  warnings remain outside this package.
- Unused dependencies: none.
- Compile graph: 17 files, three compile edges, zero cycles.
- Dependency tree: Jido Chat resolves from `../jido_chat` and consolidated Jido
  resolves at `ec96da60`.
- Retired-package, removed-helper, old Hex constraint, and old Git-source scan:
  no matches.
- `git diff --check`: passed.

