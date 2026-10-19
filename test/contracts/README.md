# Discord contracts

Run `mix test.contracts` for runtime obligation coverage. Run
`mix covenant.check --static` for static obligation references. CI requires both.
Every active obligation must have a passing test. Production coverage is a
separate gate: `mix coveralls.json` must remain above 90%.

The five components cover adapter discovery and capabilities, native Actions,
Signal construction, normalization, and the receive Source. Literal obligation
IDs in test tags are stable. The capability and request-schema JSON files are
reviewed fixed expectations. Route cases and public result expectations are
literal test data. Tests must not regenerate expected data from implementation.

Live provider and UI tests stay outside Covenant. This keeps contract checks
repeatable without credentials or provider access. See
[the operation matrix](../../guides/operation-matrix.md) for live evidence,
provider restrictions, and the explicit private interaction host path.
