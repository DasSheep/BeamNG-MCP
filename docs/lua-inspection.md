# Lua discovery and source inspection

`inspect_lua` browses live Lua tables in the game-engine (GE) VM or a vehicle VM, one level at a
time. `get_lua_source` reads the source of one function. Neither executes the code it inspects.

## Usage

Start with a scoped, filtered `inspect_lua` call, then ask for metadata or source of the function you
need:

```json
{"path":["core_vehicle_manager"],"kind":"function","filter":"vehicle"}
{"path":["core_vehicle_manager","getVehicleData"],"detail":true}
```

Pass the second path to `get_lua_source` to read its definition.

- **Paths** start at `_G` and are arrays of literal string, number or boolean keys, so names that
  contain dots need no escaping. Up to 24 steps.
- **Methods:** step through a metatable with `{"via":"metatable"}` or an `__index` table with
  `{"via":"index"}`, for example `["obj",{"via":"metatable"}]`. A function-valued `__index` is
  reported but never called; inspect it through a path ending in `"__index"`.
- **Scope:** `scope: "vehicle"` inspects a vehicle VM, using the player vehicle unless `id` is
  given. Vehicle requests go through the same callback route as `vehicle_lua_eval`, with its
  timeout and late-reply handling.

| Control | Default / limit |
|---------|-----------------|
| `maxBytes` | 4,096 encoded result bytes; 1,024–16,384 (excludes the MCP envelope) |
| `limit` | 20 discovery entries or 40 source lines; maximum 100 |
| `preview` | 128 string bytes; 0–512; UTF-8 boundaries preserved |
| `detail` | Off; turn on for parameters, source file and defining lines |
| `filter`, `kind`, `searchValues` | Filter by key substring and value type before paging; `searchValues` also searches bounded scalar previews |
| `sort` | `key` (default), `type`, or `value`; value sorting compares bounded previews as text |
| `offset` | Use the returned `nextOffset`: a match offset for discovery, a byte offset within the function for source |

## How it works

Both tools use one engine-independent helper, `lua/common/beammcp/inspect.lua`, loaded in both VMs.
The GE tool validates each request before routing it. For vehicle requests the arguments are
encoded as JSON inside a quoted Lua string, so paths are always data and never evaluated as Lua
expressions.

Inspection uses raw access, respects protected metatables, and never invokes inspected functions,
`__index`, `__pairs` or `__tostring`.

## Discovery results

- Discovery scans at most 10,000 keys of one table and never recurses into or counts child tables.
- Keys that cannot be addressed in a path (object keys, non-finite numbers, non-UTF-8 strings or
  strings over 256 bytes) are counted as `omittedKeys`.
- `matched` counts addressable matches in the scanned portion. `scanTruncated` marks an incomplete
  scan: narrow the path rather than paging, because a truncated scan does not offer continuation and
  offset requests against it fail. Filters reduce output, not the scan ceiling.
- Pages are deterministic for an unchanged table; live mutations can shift later pages.
- An oversized first-row preview is shortened to fit; `truncated` or `detailOmitted` marks omitted
  detail.
- Filters run before per-row metadata is extracted.
- Native functions have unknown parameter lists; stripped Lua parameter names show as `?`.

## Source results

- Source is read on demand through BeamNG's virtual file system with bounded reads, and files over
  512 KiB are refused.
- `line` is the first line of the returned page; byte continuation (`nextOffset`) handles very long
  lines.
- Native functions, generated chunks and missing files report `unavailable`.
- Source comes from the current file on disk, while line numbers come from the loaded function's
  debug info. After editing a file without reloading, they can disagree.

## Output budget

The result budget is measured on the JSON encoding, including string escapes. It bounds bytes, not
model tokens, and excludes the transport envelope. As a rough guide, listing every function in GE
`core_vehicle_manager` (23 functions) is about 1 KB compact versus about 3.8 KB with `detail`, and
the vehicle `powertrain` table (40 functions) is about 1.8 KB versus 5.8 KB. Default pages are
smaller.

## Scope compared with the Lua Globals Explorer

The design is inspired by E32k's MIT-licensed Lua Globals Explorer, and attribution is kept in the
source. The useful features are covered by structured browsing, GE/vehicle scope, function
metadata, source excerpts, filtering, sorting and metatable navigation. Its ImGui window, clipboard
operations, global scratch variables and refresh loop are not needed over MCP: a client can keep
paths and repeat bounded reads, and code execution has its own tools. The MCP implementation is
independent and does not reuse its UI rows, full-table counting or callback protocol.

## Tests

The off-engine suite (`scripts/run-tests.ps1`) covers raw access without metamethod execution,
protected-table sentinels, cyclic values, boolean and numeric keys, non-finite numbers, invalid
arguments, JSON budgets, gap-free pagination, UTF-8 and binary previews, long-line source
continuation, native/generated/missing/oversized sources, MCP result shaping, and the vehicle route.
