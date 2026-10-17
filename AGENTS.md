# AGENTS.md

## What this repo is

An implementation **package** (docs + contracts + fixtures + Python reference mock) for a native iOS/iPadOS OpenCode client. **No Swift app code exists yet.** Do not describe mock behavior or generated fixtures as verified against a real OpenCode host or device — see `docs/verification.md` for what is actually proven.

Baseline is pinned: OpenCode **v2.0.25**, commit `b44eea9e204024db2b480a136ece29d790d5f593`. The snapshot `contracts/opencode-v2.0.25.openapi.json` is authoritative; its SHA-256 and byte size (550766) are asserted in tests. Updating the baseline means replacing the snapshot, updating `contracts/mobile-scope.json`, and regenerating everything — do not do this casually.

## Commands (run from workspace root)

```sh
python3 -m mock.fixtures              # regenerate fixtures/generated/{demo.json,events.jsonl,events.sse}
python3 scripts/build_contracts.py    # regenerate contracts/{route-catalog,source-manifest}.json AND docs/api-route-catalog.md
python3 -m unittest discover -s tests -v   # full suite (26 tests)
python3 -m mock.server --port 4097    # reference mock on loopback
```

Single test: `python3 -m unittest tests.test_mock.ContractTests.test_modeled_routes_exist` (classes: `ContractTests`, `HTTPTests`).

Python 3.11+ **standard library only** — no dependencies, no lockfile, no venv needed. Keep it that way; the dependency-free contract guard in `mock/contract.py` is deliberate.

## Generated files are committed — never hand-edit

`fixtures/generated/*`, `contracts/route-catalog.json`, `contracts/source-manifest.json`, and `docs/api-route-catalog.md` are produced by the two commands above and are byte-for-byte reproducible. Tests validate the committed files against the generators, so hand edits will fail. Change generators (`mock/fixtures.py`, `scripts/build_contracts.py`) and regenerate instead.

## Test constants are load-bearing

`tests/test_mock.py` asserts fixed counts: 141 operations, 61 modeled routes, 256 schemas. Adding a modeled route or operation means updating these constants deliberately, not by loosening the assertions.

## Mock facts agents get wrong

- Unmodeled routes return mock-only **501**; unknown routes mock-only 404. Unsupported baseline operations (e.g. archive/restore) must **never** be made to succeed in the mock.
- `/__mock/*` scenario controls and the dev credentials (`opencode` / `mock-password`, control header `X-Mock-Control: mock-control`) are mock-only and must be excluded from any production adapter.
- The mock executes nothing real: no tools, shell, providers, or filesystem writes. Passing its tests proves mock properties, not real-server fidelity. Known simplifications: `docs/testing-mock.md#fidelity-and-limits`.
- `contracts/mobile-scope.json` is the machine-readable workflow → screen → operation map; route/scope work starts there.

## Conventions

- Original Python code carries `# SPDX-License-Identifier: MPL-2.0` on line 1 — keep it. The vendored upstream snapshot stays MIT (`contracts/UPSTREAM-LICENSE`).
- Route scope lives in `contracts/mobile-scope.json` with stages `initial` / `later` / outside scope; `docs/api-route-catalog.md` is generated from it — edit the JSON, not the table.

## Docs map

`README.md` lists every doc with its purpose; start with `docs/api-contract.md`, `docs/navigation-screens.md`, `docs/implementation-defaults.md`, and `docs/testing-mock.md` together before implementing features. Monetisation is decided (completely free) — `docs/monetisation.md` is inactive reference, not scope.
