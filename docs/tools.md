# Tool reference

This page covers the game target. The separate [BeamMP server tool reference](beammp.md#tools)
covers server resources and plugin-state development.

BeamNG-MCP registers **39 tools**. This page documents every one of them: what it does, when to reach
for it, its parameters, and whether it only reads or also changes the game.

The parameter tables are taken from each tool's `inputSchema`, the same schema your MCP client sees
in `tools/list`. Where the code applies a default that the schema doesn't state, the table shows the
default the code uses.

## Contents

- [Conventions shared across tools](#conventions-shared-across-tools)
- [Eval and scripting](#eval-and-scripting) —
  [`lua_eval`](#lua_eval) · [`vehicle_lua_eval`](#vehicle_lua_eval) · [`cef_eval`](#cef_eval)
- [Lua discovery](#lua-discovery) —
  [`inspect_lua`](#inspect_lua) · [`get_lua_source`](#get_lua_source)
- [Runtime observation and diagnostics](#runtime-observation-and-diagnostics) —
  [`read_lua`](#read_lua) · [`observe_lua`](#observe_lua) · [`runtime_info`](#runtime_info) ·
  [`console_logs`](#console_logs)
- [Game state and vehicle telemetry](#game-state-and-vehicle-telemetry) —
  [`get_game_state`](#get_game_state) · [`list_vehicles`](#list_vehicles) ·
  [`get_vehicle_state`](#get_vehicle_state) · [`get_vehicle_powertrain`](#get_vehicle_powertrain) ·
  [`get_vehicle_tuning`](#get_vehicle_tuning) · [`get_vehicle_config`](#get_vehicle_config)
- [Damage](#damage) —
  [`get_damage_data`](#get_damage_data) · [`trigger_damage`](#trigger_damage) ·
  [`list_damage_groups`](#list_damage_groups) · [`damage_vehicle`](#damage_vehicle) ·
  [`get_part_condition`](#get_part_condition)
- [Vehicle catalog, building and placement](#vehicle-catalog-building-and-placement) —
  [`list_spawnable_models`](#list_spawnable_models) · [`list_vehicle_configs`](#list_vehicle_configs) ·
  [`get_vehicle_parts`](#get_vehicle_parts) · [`spawn_vehicle`](#spawn_vehicle) ·
  [`set_config`](#set_config) · [`switch_vehicle`](#switch_vehicle) ·
  [`reset_vehicle`](#reset_vehicle) · [`teleport_vehicle`](#teleport_vehicle)
- [World, session and sim time](#world-session-and-sim-time) —
  [`list_levels`](#list_levels) · [`load_level`](#load_level) · [`set_ui_state`](#set_ui_state) ·
  [`set_sim_speed`](#set_sim_speed) · [`list_manipulations`](#list_manipulations)
- [Visual and UI](#visual-and-ui) —
  [`screenshot`](#screenshot) · [`screenshot_native`](#screenshot_native) ·
  [`get_ui_visibility`](#get_ui_visibility) · [`set_ui_visibility`](#set_ui_visibility) ·
  [`reload_cef`](#reload_cef)
- [Reload recovery](#reload-recovery) — [`recover_game_state`](#recover_game_state)

## Conventions shared across tools

**How each entry reads.** Every tool has a one-line **Kind**, taken from its MCP annotations:

- *Read-only*: `readOnlyHint: true`. It does not change game state.
- *Mutating*: changes game state, but you can undo it or it's mild (`destructiveHint: false`).
- *Mutating, destructive*: may discard state such as position, velocity, damage, the loaded level, or
  arbitrary state in the case of the eval tools (`destructiveHint: true`).

Some entries also have a **Requires** line for a precondition or operator gate. All arguments are
JSON. A tool with no parameter table takes no arguments, so pass `{}`.

**Vehicle `id` defaults to the player vehicle.** On every tool that acts on one vehicle, `id` is
optional. Leave it out and the tool targets the vehicle you are currently driving. Get ids from
[`list_vehicles`](#list_vehicles). An `id` that isn't a number is rejected with an error before it
reaches the engine. There are two exceptions:

- [`switch_vehicle`](#switch_vehicle) requires `id`.
- The Lua discovery and observation tools accept `id` only together with `scope: "vehicle"`, and it
  must be a non-negative integer.

**Read tools are compact by default.** List and telemetry tools return a small summary unless you
ask for more. The usual controls are:

- `detail: true` (or `full: true` on a few tools) expands the result.
- Filters such as `filter`, `type`, `brand`, `category` and `name` narrow it.
- Scope arguments such as `device`, `part` and `key` drill into one item.
- `limit` caps the length of long lists.

When a list is capped, the result reports the full `total` and includes a `note`. Ask for the
expanded output only when you need it, because the full forms of some tools are large.

**Output budget (`maxBytes`).** Nine tools return unbounded data and take a `maxBytes` budget:
`lua_eval`, `vehicle_lua_eval`, `cef_eval`, `inspect_lua`, `get_lua_source`, `read_lua`,
`observe_lua`, `runtime_info` and `console_logs`.

- The budget is an integer from **1,024 to 16,384**, default **4,096**. Values outside that range are
  rejected.
- It limits the encoded JSON of the result, escapes included. The MCP envelope comes on top.
- When data had to be dropped to fit, the result carries `truncated: true`.

Raise `maxBytes` only when a result tells you it was truncated and you need the rest. See
[runtime-observation.md](runtime-observation.md) for the details.

**Calls that wait return in one call.** Some tools need a round trip to the vehicle VM, the CEF UI,
or the renderer. The server waits for the answer within that same request, so you don't poll for
it:

| What it waits for | Tools | Timeout |
|---|---|---|
| Vehicle VM round trip | [`vehicle_lua_eval`](#vehicle_lua_eval), the [damage](#damage) tools, `scope: "vehicle"` on the discovery and observation tools, [`runtime_info`](#runtime_info) with `vehicle: true` | 5 s |
| Captured image | [`screenshot`](#screenshot) | 5 s |
| Captured image | [`screenshot_native`](#screenshot_native) | 12 s |
| CEF round trip over CDP | [`cef_eval`](#cef_eval) | 5 s, after up to 2 s to find the page |

A few tools start a process and return right away: [`load_level`](#load_level),
[`set_ui_state`](#set_ui_state) and [`reload_cef`](#reload_cef). Their entries say what to poll to
know when the process is done.

**Gated tools.** Most tools work as soon as the mod is loaded. Four need something more:

| Tool | Gate |
|---|---|
| [`cef_eval`](#cef_eval) | BeamNG launched with `-cefdev` (see [cef-cdp.md](cef-cdp.md)) |
| [`set_sim_speed`](#set_sim_speed) | Operator ticks **Allow sim-time control** in the in-game panel (off by default); refused during BeamMP sessions |
| [`load_level`](#load_level) | Refused during BeamMP sessions |
| [`screenshot_native`](#screenshot_native) | Game launched through Steam, plus a one-time folder link (see [screenshots.md](screenshots.md)) |

The BeamMP refusal is deliberately cautious. A tool refuses when the BeamMP mod is loaded and either
a session is active or the session state can't be read. [`get_game_state`](#get_game_state)'s
`multiplayer` field shows whether a session was detected.

Bearer-token authentication applies to the whole server, not to individual tools. See
[security.md](security.md). To connect a client, see [clients.md](clients.md).

> **The eval tools are full code execution** inside the game process, in the GE VM, a vehicle VM or
> the CEF UI. Read [security.md](security.md) before you expose the server beyond loopback.

---

## Eval and scripting

### `lua_eval`

Runs a Lua chunk in the GE (game engine / world) VM. It returns the chunk's first return value as
`value` and anything it `print`s as `output`. Use it for world-level work: extensions, the scene,
the camera, environment and settings. For one vehicle's physics state, use
[`vehicle_lua_eval`](#vehicle_lua_eval). If the chunk raises an error, the tool returns the error
with a traceback and any output printed before it.

**Kind:** Mutating, destructive (arbitrary code).

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `code` | string | *required* | Lua source to execute |
| `maxBytes` | integer | 4096 | 1024–16384; result budget |

The chunk runs synchronously on the game thread. An infinite loop freezes the game, and the output
budget does not interrupt it.

```json
{ "code": "return getCurrentLevelIdentifier()" }
```

### `vehicle_lua_eval`

Runs a Lua chunk in a vehicle's VE (vehicle) VM and returns `{ value, output }`, shaped like
[`lua_eval`](#lua_eval). Use it for per-vehicle physics and controller state, such as `electrics`,
`powertrain`, `controller` and `beamstate`.

**Kind:** Mutating, destructive (arbitrary code).

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `code` | string | *required* | Lua source to execute in the vehicle VM |
| `id` | number | player vehicle | Target vehicle |
| `maxBytes` | integer | 4096 | 1024–16384; result budget |

If the vehicle VM doesn't answer within 5 seconds, the tool returns an error.

```json
{ "code": "return electrics.values.rpm" }
```

### `cef_eval`

Evaluates JavaScript in one of BeamNG's CEF (web UI) pages over the Chrome DevTools Protocol and
returns the result as `value`. It is the CEF counterpart of the two Lua eval tools. Use it to
inspect or drive the HUD and menus.

**Kind:** Mutating, destructive (arbitrary code).
**Requires:** BeamNG launched with `-cefdev`. The server reaches the DevTools endpoint on
`localhost:8080` by default. If another app uses that port, change **cef port** in the in-game panel.
It only ever targets BeamNG's own `local://` pages, never another CEF app on the same port. See
[cef-cdp.md](cef-cdp.md).

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `code` | string | *required* | JavaScript to evaluate; must be non-empty |
| `target` | string | Main UI | Matches the page by a substring of its title or URL; the default matches `main/index.html` |
| `maxBytes` | integer | 4096 | 1024–16384; result budget |

```json
{ "code": "document.title" }
```

---

## Lua discovery

These tools let you explore live Lua APIs without running any of the code you inspect. They walk
raw tables and never call getters or metamethods. Both work in the GE VM (the default) or in a
vehicle VM. Unknown arguments are rejected. For the full model, including path steps, paging and
scan caps, see [lua-inspection.md](lua-inspection.md).

**Paths.** `path` is an array of raw keys, starting from `_G`. Each step is one of:

- a string of up to 256 bytes,
- a number,
- a boolean,
- `{"via":"metatable"}` or `{"via":"index"}`, which browse an object's methods.

A path can have at most 24 steps. If you leave `path` out, the tool starts at `_G` itself.

### `inspect_lua`

Lists one level of a table, compact by default. Narrow the result with `path`, `filter` or `kind`
before you turn on `detail: true`, which adds function signatures and where each function is
defined.

- Large tables are paged. Pass the returned `nextOffset` back as `offset`.
- `scanTruncated` means the table has more than 10,000 keys. Narrow the `path`.
- Keys that are opaque or too large to show are counted in `omittedKeys`.

**Kind:** Read-only.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `path` | array | `[]` (`_G`) | Raw key path; see above |
| `scope` | string | `ge` | `ge` or `vehicle` |
| `id` | integer | player vehicle | Only with `scope: "vehicle"`; 0–2147483647 |
| `filter` | string | none | Case-insensitive literal substring of the key; at most 128 bytes |
| `kind` | string | any | `table`, `function`, `string`, `number`, `boolean`, `userdata`, `cdata`, `thread` |
| `searchValues` | boolean | false | Also match `filter` against the previews of scalar values |
| `sort` | string | `key` | `key`, `type` or `value` (`value` sorts the previews as text) |
| `detail` | boolean | false | Include function parameters and source locations |
| `preview` | integer | 128 | String preview length in bytes, 0–512 |
| `limit` | integer | 20 | Entries per page, 1–100 |
| `offset` | integer | 0 | Position in the sorted matches, 0–10000; use `nextOffset` |
| `maxBytes` | integer | 4096 | 1024–16384 |

```json
{ "path": ["core_vehicles"], "kind": "function", "detail": true }
```

### `get_lua_source`

Reads the source code of a Lua function at a path, in GE or vehicle Lua. It returns the source file,
the start line, the text, and a `nextOffset` if there is more. Native, generated and missing sources
come back as unavailable. Files over 512 KiB are refused.

The tool reads the current file on disk. If the file was edited after it was loaded, the line
numbers the running code reports may no longer match.

**Kind:** Read-only.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `path` | array | `[]` | Path to a function; see above |
| `scope` | string | `ge` | `ge` or `vehicle` |
| `id` | integer | player vehicle | Only with `scope: "vehicle"` |
| `limit` | integer | 40 | Lines per page, 1–100 |
| `offset` | integer | 0 | Byte offset within the function source, 0–524288; use `nextOffset` |
| `maxBytes` | integer | 4096 | 1024–16384 |

```json
{ "path": ["core_vehicles", "spawnNewVehicle"] }
```

---

## Runtime observation and diagnostics

See [runtime-observation.md](runtime-observation.md) for the details on output budgets, sampling
and log cursors.

### `read_lua`

Reads up to 16 named Lua paths from one VM in a single call. Use it for targeted values when an
`inspect_lua` listing would be too much.

The result contains:

- `values`, keyed by the names you gave;
- `unavailable`, with an error for each path that is missing, non-finite or failed;
- `truncatedFields`, for strings that were cut short;
- `startedAt` and `completedAt` wall-clock timestamps.

Objects come back as opaque type descriptions, and no getters run. Unknown arguments are rejected.

**Kind:** Read-only.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `fields` | array | *required* | 1–16 objects of the form `{ "name": string ≤32 bytes, "path": [...] }`; names must be unique |
| `scope` | string | `ge` | `ge` or `vehicle` |
| `id` | integer | player vehicle | Only with `scope: "vehicle"` |
| `preview` | integer | 128 | String preview length in bytes, 0–512 |
| `maxBytes` | integer | 4096 | 1024–16384 |

```json
{ "scope": "vehicle",
  "fields": [ { "name": "rpm",  "path": ["electrics", "values", "rpm"] },
              { "name": "gear", "path": ["electrics", "values", "gear"] } ] }
```

### `observe_lua`

Samples the same kind of named paths repeatedly for a short window, or until a condition is met.

**Result:**

- `summary`, per field: `first`, `last`, `min`, `max` (numbers only), `changes`, `unavailable`
- `count`: how many samples were taken
- `elapsed`: how long the observation ran
- `status`:
  - `complete`: no condition was given and the window ran out
  - `matched`: the condition was met
  - `timeout`: a condition was given and the window ran out first
  - `unavailable`: a read failed

**Limits:**

- At most 201 samples per call.
- At most two observations can run at the same time.
- A vehicle observation stays on the vehicle it started with, even if you switch vehicles.
- Values are read at intervals, so a change that happens between two reads can be missed.

**Kind:** Read-only.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `fields` | array | *required* | Same shape as in [`read_lua`](#read_lua) |
| `duration` | number | 1 | Wall-clock seconds, 0.05–10 |
| `interval` | number | 0.1 | Minimum delay between reads in seconds, 0.05–2 |
| `condition` | object | none | `{ field, op, value? }`; see below |
| `samples` | boolean | false | Also return the sample history, capped at half of `maxBytes` |
| `scope` | string | `ge` | `ge` or `vehicle` |
| `id` | integer | player vehicle | Only with `scope: "vehicle"` |
| `preview` | integer | 128 | 0–512 |
| `maxBytes` | integer | 4096 | 1024–16384 |

**`condition`:**

- `field` must be one of the names in `fields`.
- `op` is one of the following:
  - `eq`, `ne`: need a scalar `value` (string, number or boolean)
  - `gt`, `ge`, `lt`, `le`: need a number
  - `changed`, `exists`, `missing`: take no `value`

```json
{ "scope": "vehicle", "duration": 5,
  "fields": [ { "name": "speed", "path": ["electrics", "values", "wheelspeed"] } ],
  "condition": { "field": "speed", "op": "gt", "value": 20 } }
```

### `runtime_info`

Reports on the server's own runtime:

- whether the GE side is available, and the player vehicle;
- where the loaded Lua code came from (origins and fingerprints) and the deployment manifest
  claims, covering up to 12 modules;
- the last cached CEF discovery result.

Use it to confirm which build of the mod is actually running, or to diagnose why CEF or vehicle
tools fail.

**Kind:** Read-only.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `probe` | boolean | false | Run a fresh CEF target discovery (runs no JavaScript) |
| `vehicle` | boolean | false | Check a round trip to a vehicle VM |
| `id` | integer | player vehicle | Vehicle for the `vehicle` check; 0–2147483647 |
| `detail` | boolean | false | List up to 16 function origins per module instead of one entry point |
| `maxBytes` | integer | 4096 | 1024–16384 |

### `console_logs`

Reads BeamNG log lines with filters and a byte limit. There are two sources:

- **`buffer`** (default): an in-memory ring of the most recent 500 log entries recorded since the mod
  loaded.
- **`file`**: the `beamng.log` file. Each call scans at most 64 KiB. A partial last line waits until
  its newline is written.

**Paging.** Without a `cursor`, you get the most recent lines (the tail). Every result returns a
`cursor`. Pass it back to page forward through lines that are new since that call. Each cursor
belongs to the source it came from.

**Missed or reset lines.** If the ring overwrote lines you hadn't read yet, the result reports them
in `dropped`. If the buffer was regenerated or the log file was replaced, it reports `reset`.

**Filters.** Filters are applied before `limit`. `level` is a *minimum* severity, in the order
`D` < `I` < `W` < `E`.

**Kind:** Read-only.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `source` | string | `buffer` | `buffer` or `file` |
| `cursor` | string | none | Opaque cursor from an earlier call on the same source; leave it out for the tail |
| `level` | string | none | `D`, `I`, `W` or `E`; returns that level and above |
| `tag` | string | none | Case-insensitive substring of the tag |
| `match` | string | none | Case-insensitive substring of the message |
| `limit` | number | 50 | Entries or groups per call; values above 200 are capped at 200 |
| `groupDuplicates` | boolean | false | Merge consecutive identical entries into one with `count`, `firstTime` and `lastTime` |
| `maxBytes` | integer | 4096 | 1024–16384 |

```json
{ "level": "W", "match": "beammcp", "groupDuplicates": true }
```

---

## Game state and vehicle telemetry

### `get_game_state`

Returns a snapshot of the game and session state in one synchronous read:

| Field | What it shows |
|---|---|
| `paused`, `simSpeed` | Simulation pause state and speed factor |
| `level`, `mission` | Loaded level and mission file |
| `playerVehicleId` | The vehicle you are driving |
| `resolution` | Display resolution setting |
| `multiplayer` | Whether an active BeamMP session was detected |
| `timeOfDay` | `{ time, dayLength, dayScale }` |
| `gameMode`, `freeroamActive` | Game mode, and whether Free Roam is running |
| `worldReadyState` | World readiness; `2` means initialized |
| `loading` | Whether a loading screen is up |
| `uiState`, `uiStateKnown` | The UI route the engine has actually committed |
| `uiTransition` | Status of the last [`set_ui_state`](#set_ui_state) request |
| `levelTransition` | Status of the last [`load_level`](#load_level) request |
| `mainMenu`, `menuOpen` | Whether the main menu or any menu is showing |
| `lastReloadRecovery` | What the automatic repair did after the last Lua reload; present only if a reload happened |

Poll this tool after [`load_level`](#load_level) or [`set_ui_state`](#set_ui_state).

**Kind:** Read-only.

### `list_vehicles`

Lists the vehicles currently spawned, each as `{ id, model, isPlayer, pos }`, together with a
`count`. For the models you *can* spawn, use [`list_spawnable_models`](#list_spawnable_models).

**Kind:** Read-only.

### `get_vehicle_state`

Returns a synchronous snapshot of one vehicle, read from the GE side:

- `model`
- `pos` and `velocity`
- `speed_ms` and `speed_kmh`
- `heading_deg`
- `damage`

If there is no player vehicle and you don't pass `id`, it returns an error.

**Kind:** Read-only.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `id` | number | player vehicle | |

### `get_vehicle_powertrain`

Returns the vehicle's live drivetrain device tree: engine, shafts, gearbox, differentials and
wheels. This is the running powertrain, not the jbeam parts you can build with; for those, see
[`get_vehicle_parts`](#get_vehicle_parts).

It has three modes:

- **Compact** (default): each device as `{ name, type, inputName }`, plus the wheel names and a
  `note`.
- **`detail: true`**: the full device rows, plus each wheel with its hub-node position relative to
  the vehicle.
- **`device: "<name>"`**: the full row for one device.

**Kind:** Read-only.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `id` | number | player vehicle | |
| `detail` | boolean | false | Full device rows and wheel hub geometry |
| `device` | string | none | One device by name; can't be combined with `detail` |

### `get_vehicle_tuning`

Reads a spawned vehicle's tuning variables, the knobs you can adjust.

- **Default:** the current tune grouped by category, as `{ Category: { name: value } }`, without
  ranges.
- **With `category` or `name`:** matching knobs as `[{ name, val, min, max, default, unit }]`.
  Read these ranges before you change a value.

To apply changes, pass them in `vars` to [`set_config`](#set_config). The engine clamps values to
`[min, max]`. An unknown `category` returns an error that lists the valid categories. An empty
string counts as not given.

**Kind:** Read-only.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `id` | number | player vehicle | |
| `category` | string | none | Return this category's knobs with their ranges |
| `name` | string | none | Case-insensitive substring of the variable name, e.g. `camber` |
| `detail` | boolean | false | Add `title`, `description` and `step` to the `category`/`name` rows |

```json
{ "name": "camber" }
```

### `get_vehicle_config`

Reads the parts installed on a spawned vehicle, that is, its current build.

- **Default:** a flat `{ slot: part }` map, the same shape as a `.pc` file, plus `model`, `mainPart`
  and `count`. You can pass the map straight back as `parts` to [`set_config`](#set_config).
- **`detail: true`:** also returns the nested part `tree`, including empty slots.

How it relates to the other vehicle-build tools:

| Tool | What it reads |
|---|---|
| `get_vehicle_config` | The parts installed now |
| [`get_vehicle_parts`](#get_vehicle_parts) | The parts available for a model |
| [`get_vehicle_tuning`](#get_vehicle_tuning) | The tuning values |

**Kind:** Read-only.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `id` | number | player vehicle | |
| `detail` | boolean | false | Also return the nested part tree |

---

## Damage

Damage comes in two layers, and each has its own tools:

| Layer | What it is | Read with | Set with |
|---|---|---|---|
| **Flags** | The damage tracker's flags and values that drive dashboard warnings and telltales | [`get_damage_data`](#get_damage_data) | [`trigger_damage`](#trigger_damage) |
| **Physical** | Real breakage and deformation of the soft body | [`get_part_condition`](#get_part_condition) | [`damage_vehicle`](#damage_vehicle) |

[`list_damage_groups`](#list_damage_groups) lists the valid targets for `damage_vehicle`.
All five tools make a round trip to the vehicle VM.

### `get_damage_data`

Reads the vehicle's damage flags from the damage tracker's `DamageData` table. This is the source
dashboard warnings and telltales use. It is grouped by area: engine, wheels, transmission and so
on. By default it returns only *active* entries, meaning flags that are set and values that aren't
zero. A `note` reports how many entries were left out.

**Kind:** Read-only.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `id` | number | player vehicle | |
| `full` | boolean | false | Return every entry, including `false` and `0` |

### `trigger_damage`

Sets one damage-tracker flag or value, which is useful for testing warnings and telltales. It
**does not** deform the vehicle. For physical breakage, use [`damage_vehicle`](#damage_vehicle).

**Kind:** Mutating, destructive.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `group` | string | *required* | Damage group, e.g. `engine` |
| `name` | string | *required* | Damage key, e.g. `headGasketDamaged` |
| `value` | boolean or number | *required* | A boolean for flags, a finite number for scalar values |
| `id` | number | player vehicle | |

```json
{ "group": "engine", "name": "headGasketDamaged", "value": true }
```

### `list_damage_groups`

Lists what you can damage on a vehicle:

- `breakGroups` and `deformGroups`: jbeam group names;
- `wheels`: the tires you can deflate, as `[{ id, name }]`.

Each list is capped at 100 entries, and a `note` reports any truncation. Use `filter` to narrow the
lists.

**Kind:** Read-only.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `id` | number | player vehicle | |
| `filter` | string | none | Case-insensitive substring of group and wheel names |

### `damage_vehicle`

Applies one physical damage operation to a vehicle. The `kind` values are:

| `kind` | What it does | Needs |
|---|---|---|
| `break_group` | Breaks one break group | `group` |
| `break_hinges` | Breaks the hinges | — |
| `deflate_tire` | Deflates one tire, or all of them | `wheel`, or leave it out for all |
| `deform_group` | Deforms one deform group | `group` |
| `destroy` | Wrecks the whole vehicle | — |

Get valid `group` and `wheel` values from [`list_damage_groups`](#list_damage_groups). The damage
shows up over the next physics steps. Check it with [`get_part_condition`](#get_part_condition) or
[`screenshot`](#screenshot). To repair the vehicle, use [`reset_vehicle`](#reset_vehicle).

**Kind:** Mutating, destructive.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `kind` | string | *required* | `break_group`, `break_hinges`, `deflate_tire`, `deform_group` or `destroy` |
| `group` | string | none | Required for `break_group` and `deform_group` |
| `wheel` | number | all tires | Wheel id for `deflate_tire` |
| `id` | number | player vehicle | |

```json
{ "kind": "deflate_tire", "wheel": 0 }
```

### `get_part_condition`

Reads the vehicle's physical damage: a damage score from 0 to 1 for each part (deformed parts
only), and the total number of deformed beams.

`detail: true` adds damage per deform group, limited to the 30 most damaged. These values build up
from gradual collision deformation. They can be empty after an instant group break from
[`damage_vehicle`](#damage_vehicle). Damage settles over the next physics steps, so read after the
sim has stepped.

**Kind:** Read-only.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `id` | number | player vehicle | |
| `detail` | boolean | false | Include damage per deform group |

---

## Vehicle catalog, building and placement

**Config arguments.** [`spawn_vehicle`](#spawn_vehicle) and [`set_config`](#set_config) both take
`config` in one of two forms:

- the name of a `.pc` config, as a string;
- an inline table `{ "parts": { slot: part }, "vars": { name: value } }`.

The inline table isn't checked against the model beforehand. If the engine rejects it, the tool
returns an error.

### `list_spawnable_models`

Lists the vehicle models you can spawn. This is the model catalog; for vehicles already in the
world, see [`list_vehicles`](#list_vehicles).

- **Default:** each model as `{ key, name, type }`, plus a `types` breakdown that counts models per
  type across the whole catalog.
- **`type` and `brand` filters:** exact matches. A filtered list also reports `total`.

**Kind:** Read-only.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `type` | string | none | Exact model type, e.g. `Car`; see the `types` breakdown |
| `brand` | string | none | Exact brand; only branded vehicles have one |
| `detail` | boolean | false | Add `default_pc`, `brand` and `country` to each model |

### `list_vehicle_configs`

Lists a model's factory `.pc` configs as `{ key, name, is_default }`, up to 50 by default. A capped
list reports `total` and includes a `note`.

**Kind:** Read-only.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `model` | string | *required* | Model key from [`list_spawnable_models`](#list_spawnable_models), e.g. `pigeon` |
| `limit` | number | 50 | Maximum configs to return; must be ≥ 1 |
| `detail` | boolean | false | Add `configuration` and a performance summary `{ power, weight, topSpeed, drivetrain }` |

```json
{ "model": "pigeon" }
```

### `get_vehicle_parts`

Shows the parts available for a model, so you can build a part config. It reads the model's files
and doesn't spawn anything. For the parts installed on a live vehicle, see
[`get_vehicle_config`](#get_vehicle_config).

Choose one mode, or none for the default scoped navigation:

| Mode | Arguments | What it returns |
|---|---|---|
| Scoped (default) | `part` (optional) | One part's slots and the candidate parts for each. Starts at the main part; pass a returned candidate as `part` to go one level down. |
| Filter | `filter` | Every reachable slot whose name, or a candidate's name, contains the text, each with its candidates |
| Summary | `summary: true` | Reachable slots with candidate counts, plus totals |
| Full | `full: true` | The whole reachable map. **Large:** often tens of thousands of tokens |

You can pass at most one of `summary`, `full` and `filter`. `part` only works in scoped mode.
Prefer filter, scoped or summary over `full`.

**Kind:** Read-only.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `model` | string | *required* | jbeam model name, e.g. `pigeon`, `us_semi` |
| `part` | string | main part | Scoped mode only |
| `filter` | string | none | Case-insensitive substring, e.g. `suspension`; an empty string counts as not given |
| `summary` | boolean | false | Overview |
| `full` | boolean | false | The whole map (large) |

```json
{ "model": "pigeon", "filter": "suspension" }
```

### `spawn_vehicle`

Spawns a vehicle by model, optionally with a part config. Both spawn paths are synchronous, so the
vehicle is ready when the call returns. The result is
`{ vehicleId, model, config, placement?, focused? }`.

- **`replace: true`** (default) swaps out the vehicle you are driving and keeps its position.
- **`replace: false`** adds a new vehicle. Only this mode accepts `pos`, `rot`, `speed` and `focus`.
  Passing any of them with `replace: true` is an error.

**Kind:** Mutating.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `model` | string | *required* | jbeam model name, e.g. `pigeon`, `us_semi` |
| `config` | string or object | model default | A `.pc` name, or an inline `{ parts, vars }` table |
| `replace` | boolean | true | `false` adds a new vehicle instead of replacing the current one |
| `pos` | object | engine default | World position `{ x, y, z }`; `replace: false` only |
| `rot` | number or object | engine default | Heading in degrees, or a quaternion `{ x, y, z, w }`; `replace: false` only |
| `speed` | number or object | none | m/s along the heading, or a world velocity `{ x, y, z }`; `replace: false` only |
| `focus` | boolean | true | `false` spawns the vehicle in the background, so camera and control stay on your current car. `replace: false` only; has no effect when no other vehicles exist |

```json
{ "model": "pigeon", "replace": false, "focus": false,
  "pos": { "x": 0, "y": 10, "z": 0.5 }, "rot": 90 }
```

### `set_config`

Applies a part config to an existing vehicle and keeps its model. The vehicle respawns where it is:
it keeps its position, but velocity and damage are reset. The result is
`{ vehicleId, model, config }`.

- **A `.pc` name** replaces the whole config.
- **An inline `{ parts, vars }` table** is merged into the current config. The installed build and
  any tuning variables you don't mention stay as they are. Use it to change tuning values or swap
  one slot.

A merge can add or override parts but can't remove one. To remove parts, pass a `.pc` name instead.

**Kind:** Mutating, destructive.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `config` | string or object | *required* | A `.pc` name (full replacement) or an inline `{ parts, vars }` (merge) |
| `id` | number | player vehicle | |

```json
{ "config": { "vars": { "$tirepressure_F": 30 } } }
```

### `switch_vehicle`

Makes a spawned vehicle the one you are driving. Returns `{ vehicleId, model }`.

**Kind:** Mutating.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `id` | number | *required* | Vehicle id from [`list_vehicles`](#list_vehicles) |

### `reset_vehicle`

Resets a vehicle and returns `{ vehicleId, mode }`. The reset settles almost immediately, so the call
returns without waiting.

- **`spawn`** (default) puts it back at its spawn point, like pressing Ctrl+R. This also repairs it.
- **`recover`** turns it upright where it is.

**Kind:** Mutating, destructive.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `mode` | string | `spawn` | `spawn` or `recover` |
| `id` | number | player vehicle | |

### `teleport_vehicle`

Moves a live vehicle to a world position, heading and velocity. It keeps the vehicle's id, part
config and damage.

- **Default:** finds a clear spot on the ground near `pos` and sets the vehicle down at rest.
- **`exact: true`:** places it at exactly those coordinates and keeps its momentum.

A velocity you set with `speed` only shows up in the vehicle's reported velocity after the next
physics step.

**Kind:** Mutating, destructive.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `pos` | object | *required* | World position `{ x, y, z }` |
| `rot` | number or object | current orientation | Heading in degrees, or a quaternion `{ x, y, z, w }` |
| `speed` | number or object | none | The new velocity, replacing the old one: m/s along the heading, or a world vector `{ x, y, z }` |
| `exact` | boolean | false | `true` places the vehicle at exactly these coordinates |
| `repair` | boolean | false | Also reset deformation; default ground-snap mode only. Combining it with `exact: true` is an error |
| `id` | number | player vehicle | |

```json
{ "pos": { "x": -820.5, "y": 120.0, "z": 105.0 }, "rot": 180, "speed": 15 }
```

---

## World, session and sim time

### `list_levels`

Lists the maps you can load. Each map has a `levelName` (pass it to [`load_level`](#load_level)), a
`title` and an `official` flag. The `official` filter also reports `total`.

**Kind:** Read-only.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `official` | boolean | none | `true` for official maps only, `false` for non-official only |
| `detail` | boolean | false | Add `size`, `biome`, `suitablefor`, `supportsTraffic` and `supportsTimeOfDay` where the map defines them |

### `load_level`

Loads a map in Free Roam. It returns right away with `{ loading: true, ... }`. The map's default
vehicle appears at the default spawn point. Use [`spawn_vehicle`](#spawn_vehicle) and
[`teleport_vehicle`](#teleport_vehicle) afterwards to set up exactly what you want.

**How the load proceeds:**

1. The level name is checked against the catalog first. An unknown name returns an error without
   starting a load.
2. The load runs in the background behind a loading screen. **The server doesn't respond to requests
   while the load runs.**
3. When the world is ready and the screen has faded in, the tool switches the UI to `play`.

**Knowing when it's done.** Poll [`get_game_state`](#get_game_state) until `levelTransition.status`
is `ready` or `failed`. A matching `level` alone doesn't mean the load has finished. A main-menu UI
state during the load is normal and not a reason to start the load again.

**Kind:** Mutating, destructive.
**Requires:** No BeamMP session. The tool refuses to load while one is active.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `level` | string | *required* | A `levelName` from `list_levels`, e.g. `gridmap_v2`, `west_coast_usa` |

```json
{ "level": "west_coast_usa" }
```

### `set_ui_state`

Asks the engine's UI router to switch to a route, for example `play` or `menu`. The result holds the
current `uiState` and a `uiTransition` with the request's id, status and the route you asked for.

- Poll [`get_game_state`](#get_game_state) until `uiTransition.status` is `ready` or `failed`.
- A request that isn't confirmed within 15 seconds fails.
- A newer request replaces an older one that is still pending.
- This tool doesn't load a level or start Free Roam. Use [`load_level`](#load_level) for that.

**Kind:** Mutating.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `uiState` | string | *required* | A UI route name, e.g. `play` or `menu`; must be non-empty |

### `set_sim_speed`

Sets the simulation speed and/or pauses physics. Returns `{ simSpeed, paused }`.

- A low `factor` such as `0.05` shows a fast event in slow motion.
- `pause: true` freezes physics. You can then make several calls and check the results without any
  sim time passing.

Always undo your changes when you're done: pass `pause: false` and `factor: 1.0`.

**Kind:** Mutating.
**Requires:**

- The operator must tick **Allow sim-time control** in the in-game panel. It is off by default, and
  the tool refuses until it's on.
- The tool refuses during a BeamMP session, because changing local sim time would desync the
  server. Never enable sim-time control for multiplayer.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `factor` | number | unchanged | Speed multiplier; must be positive and finite (1.0 is normal speed) |
| `pause` | boolean | unchanged | `true` freezes physics, `false` resumes |

Give at least one of the two.

```json
{ "pause": true }
```

### `list_manipulations`

A built-in catalog of ready-made Lua recipes for changing gameplay and physics. Each entry gives
the exact code, the tool to run it with ([`vehicle_lua_eval`](#vehicle_lua_eval) or
[`lua_eval`](#lua_eval)), caveats, and how to restore the original. Fill the `<value>` placeholder
before you run it.

The tool itself only reads the catalog. Running a recipe changes the game.

**How to browse:**

- No arguments: the category index.
- `category`: that category's entries, each with a key, title and description.
- `key`: one full recipe.

**Categories and keys:**

| Category | Keys |
|---|---|
| `physics` | `power`, `grip`, `brakes`, `mass`, `gravity_vehicle`, `gear_ratios`, `rev_limit`, `engine_brake`, `aero_drag`, `invulnerable`, `infinite_fuel`, `anti_overheat`, `awd_lock`, `no_tire_burst` |
| `world` | `time_of_day`, `weather`, `gravity_world`, `shadow_quality` |
| `visuals` | `paint_color` |
| `geometry` | `beam_strength`, `node_position`, `beam_length`, `beam_spring_damp` |

**Kind:** Read-only.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `category` | string | none | `physics`, `world`, `visuals` or `geometry` |
| `key` | string | none | One recipe, e.g. `power`; takes precedence over `category` |

```json
{ "key": "grip" }
```

---

## Visual and UI

### `screenshot`

Captures the current game view and returns it inline as a PNG image. This is an engine render
capture: it **does not include ImGui or other native overlays**. For those, use
[`screenshot_native`](#screenshot_native). The temporary file is deleted after it's read.

**Kind:** Read-only.

### `screenshot_native`

Captures the frame as it appears on screen, using Steam's overlay screenshot. It includes ImGui and
other native overlays that [`screenshot`](#screenshot) can't see, and returns the image inline as a
JPEG.

Every capture is kept in your Steam screenshot library. Deleting only the file would leave a broken
entry in Steam's records, so remove captures with `scripts/prune-steam-screenshots.ps1`, run while
Steam is closed.

**Kind:** Read-only.
**Requires:**

- The game was launched through Steam, and Steam is logged in.
- The game window isn't minimised. It doesn't need focus.
- You have run `scripts/link-steam-screenshots.ps1` once, so the game can reach Steam's screenshot
  folder.

When a requirement isn't met, the tool returns an error that names it. For setup and
troubleshooting, see [screenshots.md](screenshots.md).

### `get_ui_visibility`

Returns whether each UI layer is showing, as `{ cef, imgui }` booleans:

- `cef`: the web UI and HUD
- `imgui`: the ImGui layer

**Kind:** Read-only.

### `set_ui_visibility`

Shows or hides UI layers, for example to get a clean [`screenshot`](#screenshot). A layer you leave
out stays as it is. Returns the resulting `{ cef, imgui }` state.

**Kind:** Mutating.

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `cef` | boolean | unchanged | Show (`true`) or hide (`false`) the CEF web UI / HUD layer |
| `imgui` | boolean | unchanged | Show or hide the ImGui layer |

Give at least one of the two.

```json
{ "cef": false, "imgui": false }
```

### `reload_cef`

Reloads the CEF web UI and returns `{ reloaded: true }` right away. The UI rebuilds in the
background and gives no signal when it's done. Wait a moment before you take a screenshot or run
[`cef_eval`](#cef_eval).

**Kind:** Mutating.

---

## Reload recovery

When the game reloads its Lua, some engine state is lost. The server repairs that state
automatically after every reload: camera, HUD game state, night lights and UI layers. It also
reports extensions that didn't come back, but reloads them only when the saved state failed to
restore completely. [`get_game_state`](#get_game_state)'s `lastReloadRecovery` shows what the
repair did.

### `recover_game_state`

Checks or repairs, on demand, the engine state a Lua reload can lose. Use it when the camera, HUD or
street lights look wrong. Returns `{ report, lastReloadRecovery }`.

By default it is a dry run: it checks the state and reports problems without changing anything.
`apply: true` repairs what it finds.

The guards you can run:

| Guard | What it checks |
|---|---|
| `levelflag` | The `levelLoaded` flag |
| `camera` | The camera |
| `gamestate` | The HUD's game state |
| `nightlights` | Night and street lights |
| `ui_visibility` | UI layer visibility |
| `extensions` | Missing extensions |

`ui_visibility` and `extensions` compare against a snapshot taken before a reload. When you run the
tool on demand, no such snapshot exists, so those two report `skipped`.

**Kind:** Mutating (only with `apply: true`).

| Parameter | Type | Default | Notes |
|---|---|---|---|
| `apply` | boolean | false | `false` only checks; `true` repairs |
| `guards` | array of string | all | A non-empty subset of the guard names above |

```json
{ "apply": true, "guards": ["camera", "gamestate"] }
```
