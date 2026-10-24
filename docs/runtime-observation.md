# Runtime observation and bounded output

How the read, observation, eval, log and diagnostic tools bound their output, and what their results
do and do not prove. For browsing tables and reading source, see [lua-inspection.md](lua-inspection.md).

## Choosing a tool

| Need | Tool and default |
|------|------------------|
| Discover available APIs | `inspect_lua`: shallow, filtered pages |
| Read named values | `read_lua`: 1–16 aliases with typed paths |
| Wait or sample briefly | `observe_lua`: 1 second, 0.1 second interval, summary only |
| Identify running code | `runtime_info`: cached status and one function origin per module |
| Read new logs | `console_logs`: retain and resend the returned cursor |
| Execute code | GE/VE/CEF eval: 4 KiB output by default |

All these tools accept `maxBytes` from 1,024 to 16,384, default 4,096. The limit covers encoded result
JSON, including escapes; MCP transport envelopes are additional. These are byte budgets, not token
counts. Schemas and descriptions remain available through normal MCP discovery.

## Selected values and observations

`fields` is an array of `{name,path}` objects. Names are unique identifiers up to 32 bytes. Paths
use the same raw keys and explicit metatable/index steps as inspection. Strings have bounded previews
(128 bytes by default, at most 512), objects return opaque type descriptions, and missing paths or
non-finite numbers appear under `unavailable`. `truncatedFields` identifies shortened strings.
No getters or inspected functions execute. Use narrower requests when a result says `truncated`.

One request reads one VM. Vehicle requests resolve the player ID once; switching player vehicles
does not redirect an active observation. Destroyed vehicles or failed roundtrips return an
unavailable outcome. Read timestamps are GE wall-clock start/completion times, not an atomic
cross-VM snapshot or physics-step timestamp.

`observe_lua` accepts `duration` 0.05–10 seconds and `interval` 0.05–2 seconds. Intervals are minimum
delays after each read, so callback latency and frame scheduling reduce sample frequency. A request
has at most 201 samples; at most two observations run concurrently. Timeouts use subsecond wall time
and discard abandoned vehicle correlation slots. Scheduling can delay the final response beyond
the requested deadline; already queued reads cannot be cancelled inside the vehicle VM.

The result includes `status` (`complete`, `matched`, `timeout`, or `unavailable`), `count`, `elapsed`,
and a per-field summary: first/last values, numeric min/max, observed changes and unavailable count.
Changes compare sampled previews and availability; changes between samples or beyond a shortened
preview can be missed. `previewTruncated` makes that limitation explicit. `samples:true` adds history
within half the byte budget; history is removed before summary data to fit the final response.

Conditions use `{field,op,value}`. Supported operators: `eq`, `ne`, `gt`, `ge`, `lt`, `le`, `changed`,
`exists`, `missing`. Ordered comparisons require finite numbers. Equality is typed; opaque objects
and truncated previews cannot satisfy value comparisons. `changed` requires a complete scalar in
the first sample. `exists`/`missing` test whether a path is available; non-finite values are unavailable.

## Eval and log limits

GE/VE eval limits print capture before serialization, bounds result traversal (depth 8, 2,048 nodes,
512 entries per table), reports cycles/opaque values, and preserves valid UTF-8 boundaries. It does
not bound the execution time or allocations of arbitrary user code. Internal vehicle reads retain
a separate 256 KiB transport ceiling and fail explicitly if shortened; public eval limits cannot
silently corrupt another tool's source page or continuation metadata.

CEF output is fitted after receiving its reply. CDP caps each reassembled message at 1 MiB, the
exchange at 256 wire frames/50 messages and five seconds, and upgrade headers at 8 KiB. Fragmented
TEXT messages tolerate interleaved PING/PONG; outgoing controls are masked. Invalid framing,
oversized declared lengths and early closure fail explicitly. JSON-RPC batch arrays (including
empty arrays) receive `-32600`; real notifications still receive no JSON-RPC reply.

`console_logs` reads either the in-memory ring of the last 500 log entries (`source: "buffer"`, the
default) or `beamng.log` on disk (`source: "file"`). Filters are `level` (a minimum severity: `D`, `I`, `W`
or `E`), `tag` and `match` (case-insensitive substrings); `limit` defaults to 50 entries and is capped at 200.
A cursor belongs to the source that issued it.

Log cursors are opaque and caller-owned. Without a cursor the tool returns a recent tail; with a
cursor it consumes forward pages after filters. Keep filters stable while following a cursor:
filtered-out entries are consumed too. Byte limits preserve cursor/status metadata, shorten an
oversized first row, and leave the next unreturned row for the next call. Ring overflow reports
`dropped`; generation changes report `reset`. Ingested messages/tags/levels are capped at
2,048/256/16 bytes, so filtering cannot find text beyond those previews.

File reads scan at most 64 KiB plus small fingerprint samples per call. Partial EOF lines wait for
a newline; oversized lines progress through bounded chunks. File cursors detect truncation and
changes to sampled prefix/preceding bytes, not physical file identity: replacement with identical
sampled bytes can go undetected. `hasMore`, `pendingPartial`, `windowTruncated`, and `reset` expose
these states. Duplicate grouping combines consecutive matching, untruncated entries within a page;
it returns `count`, `firstTime`, and `lastTime`.

## Build identity and availability

`scripts/build-manifest.ps1` hashes sorted shipped Lua paths/content plus the loader and records the
Git commit, dirty flag, content SHA-256 and file count. `link-mod.ps1` creates this manifest in both
ZIP and development staging. Regenerate it after development edits; a junction does not update it.
Loose installations must copy `scripts/beammcp/build.json` together with the Lua files and loader.

`runtime_info` compares the manifest captured when the server loaded with the currently readable
manifest. Stamped modules retain their own load claims. Missing manifests or unstamped modules
remain unknown. Actual loaded function origins and noncryptographic bytecode fingerprints are
separate evidence: fingerprints exclude upvalues, and neither they nor matching manifests prove
current disk contents. The tool never claims disk verification.

The default uses cached CEF discovery with its age; no completed probe means unknown. Changing
the configured port invalidates that cache. `probe:true` performs fresh target discovery, which
does not prove JavaScript execution. `vehicle:true` performs a selected vehicle roundtrip and
checks the responding ID. Module rows are removed before essential availability/build data when
a small budget requires it; `modulesTruncated` reports omission. `detail:true` and a larger budget
expose up to 16 function origins per module, for up to 12 modules.

## Tests

The off-engine suite (`scripts/run-tests.ps1`) covers encoded budgets, execution of the generated
vehicle callback code, short deadlines and cleanup, typed condition matching, pinned vehicle IDs,
sampling summaries, log cursor continuation/overflow/reset, bounded file reads, module identity
changes, and the WebSocket codec. `test/build-manifest_test.ps1` builds manifests in a temporary
repository to check that hashes are deterministic and change with content and commits.
