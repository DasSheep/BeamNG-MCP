# Architecture

This document explains how BeamNG-MCP works inside the game. It is for contributors and for anyone curious
about what runs when the mod is loaded. For the tool catalog see [tools.md](tools.md); for the security model
see [security.md](security.md).

## The short version

BeamNG-MCP is a [Model Context Protocol](https://modelcontextprotocol.io) server written in pure Lua. It runs
**inside BeamNG.drive's game-engine (GE) Lua VM** as an auto-loaded mod extension. There is no external process,
proxy, or launch flag. The extension opens a small HTTP/1.1 listener (default `http://127.0.0.1:23512/mcp`) on
BeamNG's bundled `copas` + `luasocket`, and services it once per frame from the GE `onUpdate` hook.

```
  MCP client (Claude Code, other MCP clients, a tunnel)
        |
        |  HTTP POST /mcp   (JSON-RPC 2.0 body, application/json response)
        v
+----------------------------- BeamNG.drive process ------------------------------+
|                                                                                  |
|  GE Lua VM                                                                       |
|                                                                                  |
|   beammcp.lua  onUpdate (every frame)                                            |
|      |                                                                           |
|      +-- copas.step(0) --> http/server --> http/exchange --> http/mcp            |
|                            (sockets,       (read limits,     (routing, auth,     |
|                             timeouts)      precheck, body)   Origin/Host gate)   |
|                                                                 |                |
|                                    rpc:handle(jsonString)  <----+   the seam     |
|                                                                 v                |
|                            core/jsonrpc --> core/methods --> core/registry       |
|                                                                 |                |
|                                                                 v                |
|                                                              tools/*             |
|                       +-------------------+--------------------+                 |
|                       |                   |                    |                 |
|                       v                   v                    v                 |
|               GE engine APIs        Vehicle (VE) VMs      CEF UI (Chromium)      |
|               be, core_*, FS,       queueLuaCommand  /    CDP WebSocket on the   |
|               screenshots ...       queueGameEngineLua    -cefdev port (8080)    |
|                                                                                  |
|   panel.lua (ImGui status window)       settings/beammcp.json (persisted)        |
+----------------------------------------------------------------------------------+
```

## Hosting: a GE extension that loads itself

BeamNG's mod manager runs every `scripts/**/modScript.lua` it finds at startup. Ours,
`scripts/beammcp/modScript.lua`, makes a single call:

```lua
setExtensionUnloadMode("beammcp", "manual")
```

Marking the extension `manual` does two things. The engine's `loadManualUnloadExtensions()` loads
`lua/ge/extensions/beammcp.lua` without anyone typing a console command. The extension also survives level
changes, and after a GE Lua reload (Ctrl+L) it is loaded again in the fresh VM. `beammcp.lua` also sets its own
unload mode to `manual` in `onExtensionLoaded`.

`beammcp.lua` is the composition root. In `onExtensionLoaded` it:

1. installs the console-log ring buffer (`logcapture.lua`);
2. loads persisted settings from `settings/beammcp.json` in the BeamNG user folder (`store.lua`);
3. arms Lua-reload recovery from the previous VM's snapshot, if there is one (`reload/autoheal.lua`);
4. resolves the bind address against the auth setting (`bind.lua`, see [security.md](security.md));
5. builds the JSON-RPC dispatcher, the tool registry, and the MCP methods, then registers every tool module;
6. starts the HTTP listener and creates the status panel.

`onUpdate` pumps the server and the other per-frame work. `onExtensionUnloaded` stops the listener and unhooks
the log wrapper. `onSerialize` / `onDeserialized` take part in Lua-reload recovery (described below).

### Source layout

| Path | Responsibility |
|------|----------------|
| `scripts/beammcp/modScript.lua` | Auto-load: marks the extension `manual`. |
| `lua/ge/extensions/beammcp.lua` | Extension entry point: wiring, lifecycle hooks, per-frame pump. |
| `lua/ge/extensions/beammcp/http/` | HTTP edge: `server` (sockets), `exchange` (one request/response), `message` (pure parse/frame), `mcp` (Streamable HTTP + auth gate). |
| `lua/ge/extensions/beammcp/core/` | Transport-agnostic core: `jsonrpc` (envelope), `methods` (MCP methods), `registry` (tools). |
| `lua/ge/extensions/beammcp/tools/` | One module per tool or tool family; `tools/lib/` holds shared helpers. |
| `lua/ge/extensions/beammcp/async/` | The await seam (`await`, `sleep`) and the GE-to-vehicle bridge (`ve_bridge`). |
| `lua/ge/extensions/beammcp/cdp/` | CEF DevTools target discovery and a minimal WebSocket CDP client. |
| `lua/ge/extensions/beammcp/reload/` | Lua-reload snapshot, detection, readiness gate, guards, and runner. |
| `lua/ge/extensions/beammcp/` (top level) | `bind`, `store`, `status`, `panel`, `instructions`, `logcapture`. |
| `lua/common/beammcp/` | Code shared by the GE VM and vehicle VMs: output budgeting, Lua inspection/observation, runtime identity. |

Most modules keep engine calls behind small, replaceable functions, so the logic runs under plain LuaJIT in the
off-engine test suite (`test/`, run with `scripts/run-tests.ps1`). See [CONTRIBUTING.md](../CONTRIBUTING.md).

## The HTTP edge

### copas and luasocket, pumped from the frame

BeamNG ships `copas` (coroutine-based socket scheduling) and `luasocket` in its Lua tree. `http/server.lua` binds
a TCP listener with `socket.bind(host, port)` and registers it with `copas.addserver`. Each accepted connection
runs in its own copas coroutine.

Nothing calls `copas.loop()`. Instead, `onUpdate` calls `server.update()`, which is `copas.step(0)`: one
`select()` with a zero timeout, then resume whichever coroutines have socket activity or a finished sleep. The
pump never waits on the network, so an idle or slow client does not hold up the frame.

The pump does not move tool work off the main thread, though. A tool handler runs inside the frame that resumed
it. A heavy synchronous tool costs frame time, and an infinite loop in `lua_eval` freezes the game. Tools that
must wait for the engine (screenshots, vehicle VM calls) yield instead; see the async section below.

One loading detail: `copas.lua` refuses to load if `socket.http` is already in `package.loaded`, and BeamNG
preloads it. The server hides `socket.http` while it requires copas, then puts it back. `async/sleep.lua`, the CDP
client, and `beammcp.lua` repeat the same shim.

### One request per connection

`http/exchange.lua` reads one request (request line, headers, then exactly `Content-Length` body bytes), sends
one response, and the connection closes. Every response carries `Connection: close`. There is no keep-alive and
no chunked request-body support.

### Limits at the edge

| Limit | Value | Where | Result when exceeded |
|-------|-------|-------|----------------------|
| Header lines per request | 100 | `http/exchange.lua` `MAX_HEADER_LINES` | `431 Request Header Fields Too Large` |
| Request body (`Content-Length`) | 4 MiB | `http/exchange.lua` `MAX_BODY_BYTES` | `413 Payload Too Large` (checked before reading the body) |
| Socket idle timeout | 10 s per receive/send operation | `http/server.lua` `REQUEST_TIMEOUT_SEC` | connection dropped |

Order of checks on each request:

1. Read the request line and headers (header-line cap applies).
2. Reject an oversized `Content-Length` with `413`.
3. Run the **precheck** on the head alone: routing, then bearer auth or Origin/Host validation (see
   [security.md](security.md)). Any rejection is sent at this point, **before the body is read**, so an
   unauthorized peer cannot make the server buffer its payload.
4. Read the body, dispatch it, and send the response. A handler that throws becomes a `500`.

The 10 s timeout is copas's per-operation user timeout. Without it, a peer that connects and stalls would hold a
coroutine and a `select` slot forever. Tool work is not socket I/O, so the timeout never fires while a tool runs.

## MCP transport: Streamable HTTP, JSON-only

`http/mcp.lua` implements the server side of the MCP **Streamable HTTP** transport, without Server-Sent Events.

| Request | Response |
|---------|----------|
| `POST /mcp` with a JSON-RPC request | `200`, `Content-Type: application/json`, one JSON-RPC response |
| `POST /mcp` with a notification (no `id`) | `202 Accepted`, empty body |
| `GET /mcp` and any non-POST method on `/mcp` | `405 Method Not Allowed`, `Allow: POST` |
| `GET /.well-known/oauth-protected-resource[/mcp]`, `GET /.well-known/oauth-authorization-server` | static discovery metadata (see [security.md](security.md#oauth-discovery-metadata)) |
| anything else | `404` |

**Why JSON-only is spec-legal.** The Streamable HTTP transport lets the server choose how to answer a POST that
carries a request: it may open an SSE stream (`text/event-stream`), or it may return a single JSON object
(`application/json`). Clients must support both. Likewise, a server that does not offer a server-to-client
stream answers `GET` on the endpoint with `405`. Answering every request with one `application/json` body is
therefore a complete, conforming transport for request/response use. It is also what makes a pure-Lua server
practical: no long-lived streams, no event IDs, no resumability.

Other transport properties:

- `initialize` always answers `protocolVersion: "2025-06-18"` and advertises only the `tools` capability.
- There is no session management: the server never issues an `Mcp-Session-Id`, and request headers such as
  `MCP-Protocol-Version` are not inspected.
- The server never sends requests or notifications to the client: no progress updates, no
  `notifications/tools/list_changed`, no sampling. A client sees new or changed tools only when it reconnects.

## The core seam

The HTTP layer hands the core one thing: the raw request body string, via `rpc:handle(jsonString)`. It gets back
a JSON string, or `nil` for a notification. Nothing in `core/` knows about sockets, headers, or HTTP status codes,
so the protocol logic is tested without any transport.

- **`core/jsonrpc.lua`**: the JSON-RPC 2.0 envelope. Decodes with BeamNG's `jsonDecode`, dispatches by method
  name, and maps failures to standard error codes (`-32700` parse error, `-32600` invalid request, `-32601`
  method not found, `-32602` invalid params, `-32603` internal error). Handlers run under `pcall`, so a throwing
  handler becomes a `-32603` error rather than a dead connection. Notifications never produce a response.
- **`core/methods.lua`**: the MCP methods: `initialize` (with server `instructions`), `notifications/initialized`,
  `ping`, `tools/list`, `tools/call`. Each call to one of these methods is counted in the status panel, labelled
  with the tool name for `tools/call`.
- **`core/registry.lua`**: an ordered map of tool name to definition. `list()` produces the descriptors for
  `tools/list`; `invoke()` calls a handler under `pcall`.

`instructions.lua` builds the text returned in `initialize.instructions`: usage guidance for the model. Part of
it depends on settings (whether sim-time control and auth are enabled), and it is built when the extension
loads.

## Tools

### Module convention

Each tool lives in `lua/ge/extensions/beammcp/tools/`. A module exposes a definition and a `register` function:

```lua
M.def = {
  description = "...",
  annotations = { readOnlyHint = true, openWorldHint = false, destructiveHint = false },
  inputSchema = { type = "object", properties = { ... }, required = { ... } },
  handler = handler,
}

function M.register(registry)
  registry:add("tool_name", M.def)
end
```

Every tool module is required and registered explicitly in `beammcp.lua`'s `onExtensionLoaded`. There is no
directory scanning. A module may register several related tools (for example `levels.lua` registers
`list_levels` and `load_level`).

A handler receives the `arguments` object and returns one of:

| Handler returns | `tools/call` result |
|-----------------|---------------------|
| a table | one text content block holding the table's JSON |
| a string or number | one text content block |
| `nil, "message"` | a text block with `isError: true` (a tool-level error the model can read) |
| `{ __mcpContent = { ... } }` | the given content blocks, verbatim (used for inline images) |

A handler that throws is caught by the registry and also reported as an `isError` result. An unknown tool name is
a JSON-RPC `-32602` error.

### Output discipline

Responses are kept small by default, because they end up in a model's context window:

- Read tools are **compact by default**, with opt-in `detail` / `full` flags and filters. Shared helpers live in
  `tools/lib/shape.lua`.
- Eval, inspection, observation, and log tools share `lua/common/beammcp/output.lua`. It applies an encoded-result
  budget (`maxBytes`, default 4,096, allowed 1,024 to 16,384), clips strings at valid UTF-8 boundaries, limits
  depth and node counts, replaces cycles and non-serializable values with markers, and sets `truncated: true` when
  something was left out. The budget limits the size of the response. It does not limit how long user code runs.

## Async tools: the single-call await seam

Some tools have to wait for the engine: a screenshot file appears a few frames after the request, and a vehicle VM
answers on a later frame. These tools still return their result in **one** MCP call, without a "start" call
followed by a "poll" call.

`async/await.lua` is a small loop: check a readiness predicate, and if it is not ready, sleep and check again,
until a timeout. The sleep it receives is `copas.sleep` (via `async/sleep.lua`). Because the HTTP request is
already running inside a copas coroutine, `copas.sleep` **yields that coroutine** back to the scheduler. The
frame continues, the engine does its work, and a later `copas.step(0)` resumes the request once the sleep expires.
The HTTP connection simply stays open meanwhile.

| Tool | Waits for | Timeout |
|------|-----------|---------|
| `screenshot` | the PNG written by `createScreenshot2` | 5 s |
| `screenshot_native` | the JPEG written by Steam's screenshot hook | 12 s |
| `vehicle_lua_eval`, and vehicle-scoped `inspect_lua`, `read_lua`, `observe_lua`, and other vehicle reads | the vehicle VM's callback | 5 s by default |

The poll interval is 30 ms by default. While one request is waiting, other connections are served normally, so
requests can overlap. `await.lua` takes its sleep and clock functions as parameters, which keeps it testable
without copas.

## GE to vehicle (VE) bridging

Each spawned vehicle has its own Lua VM. The GE VM can send it code with `vehicle:queueLuaCommand(source)`, but
that call returns nothing. The result has to come back on its own. `async/ve_bridge.lua` adds correlation:

1. `begin()` allocates a numeric id and an empty pending slot.
2. `wrapVE(id, code, ...)` builds the vehicle-side source. It runs the user code through
   `lua/common/beammcp/output.lua`'s `execute` (`loadstring` + `xpcall` with a traceback, `print` capture, output
   budget), JSON-encodes the payload, and calls
   `obj:queueGameEngineLua("require('beammcp/async/ve_bridge').resolve(<id>, <json>)")`. The user code is
   embedded as a serialized string literal, so a compile error comes back as a normal error payload instead of
   silently breaking the queued command.
3. The tool awaits `isReady(id)`. On a later frame the engine runs the queued GE command, which calls `resolve`
   and fills the slot.
4. `take(id)` returns the JSON and clears the slot. On timeout, the slot is abandoned; a late answer is dropped.

Because `lua/common/` is on the package path of both VMs, the vehicle side reuses the same output and inspection
code as the GE side.

## CEF access over CDP

BeamNG's UI is Chromium Embedded Framework (CEF). When the game is started with `-cefdev`, CEF exposes a Chrome
DevTools Protocol (CDP) endpoint, by default on port 8080. `cef_eval` uses it to run JavaScript in a UI page.

- **Discovery** (`cdp/targets.lua`): an HTTP `GET /json` to `localhost:<cefPort>` (2 s timeout) lists debuggable
  targets. Only `page` targets whose URL starts with `local://` count as BeamNG pages. This matters because Steam's
  own CEF can use the same default port, and the filter keeps the server from ever evaluating code in a Steam
  page. The default target is the main UI page (`main/index.html`); a `target` argument selects another page by
  title or URL substring.
- **Evaluation** (`cdp/client.lua`): one `Runtime.evaluate` (with `returnByValue` and `awaitPromise`) over a
  WebSocket. The bundled WebSocket client hangs under the `copas.step(0)` pump, so the client does its own
  RFC 6455 upgrade on a raw copas socket and uses the bundled frame encoder/decoder. The whole exchange is bounded:
  5 s total, 8,192 bytes of upgrade headers, 1 MiB per reassembled message, 256 wire frames, and at most 50
  messages read while looking for the matching response id.
- **Status probe**: every 2.5 s, `onUpdate` starts a background coroutine that runs discovery and updates the
  panel's "CEF DevTools active/inactive" line. At most one probe runs at a time, so a stuck endpoint cannot pile
  up coroutines.
- **Port**: the `cefPort` setting (panel field or `settings/beammcp.json`) changes the CDP port live.

See [cef-cdp.md](cef-cdp.md) for setup and troubleshooting.

## Status panel and settings

`panel.lua` draws an ImGui window called **BeamMCP** from `onUpdate`. It shows the listen address, tool count,
uptime, request count, last method, and CDP status. It also holds the settings controls. It appears in the main
and pause menus, hides during gameplay unless **Keep visible in gameplay** is ticked, and hides behind the big map
and photo mode. All strings are computed before `im.Begin` and all settings writes happen after `im.End`, so an
error cannot leave the ImGui window stack unbalanced; the whole draw call is also wrapped in `pcall`.

Settings persist in one JSON document, `settings/beammcp.json` in the BeamNG user folder, through `store.lua`.
Every `set` writes the whole document back.

| Key | Default | Panel control | Takes effect |
|-----|---------|---------------|--------------|
| `port` | `23512` | port field (1024 to 65535) | next extension load |
| `bindHost` | `"127.0.0.1"` | bind field (IPv4 dotted quad) | next extension load |
| `requireAuth` | `false` | "Require auth (token)" | immediately |
| `authToken` | generated when auth is first enabled | "Copy token", "Regenerate token" | immediately |
| `cefPort` | `8080` | cef port field | immediately |
| `simControl` | `false` | "Allow sim-time control" | immediately (the `set_sim_speed` gate) |
| `reloadToast` | `true` | "Toast on reload recovery" | immediately |
| `pinned` | `false` | "Keep visible in gameplay" | immediately |

"Next extension load" means a GE Lua reload or a game restart: a listening socket cannot be re-bound in place.

## Lua-reload protection and recovery

A GE Lua reload destroys the VM and rebuilds it. BeamNG carries state across with a persistence blob
(`onSerialize` / `onDeserialized`). Some engine state is not in that blob, and if importing the blob fails, almost
nothing comes back: the camera freezes, the HUD goes blank, street lights stop switching, and many extensions are
gone. The server detects these cases and repairs what it safely can.

**Before the reload** (`beammcp.lua` `onSerialize` calling `reload/autoheal.lua`): a small snapshot is written to
its **own file**, `settings/beammcp_reload_snapshot.json`, so it survives even a failed blob import. It records the
current level, the `levelLoaded` flag, the HUD game state (`core_gamestate`), the active global camera and camera
mode, the player vehicle id, CEF/ImGui UI visibility, time of day, and the list of loaded extensions. It
deliberately holds no per-vehicle or per-object data. Only a random `reloadId` goes into the engine blob.

**After the reload**:

1. `onExtensionLoaded` reads the snapshot file; `onDeserialized` receives the blob's `reloadId`, if the blob made
   it through.
2. `reload/detect.lua` classifies the reload:
   - `cold`: no snapshot file (a normal start); nothing to do.
   - `normal`: the blob came back carrying the file's `reloadId`.
   - `total`: a fresh snapshot for this level exists, but no blob id arrived, so the blob import failed.
   - `stale`: the snapshot is older than 300 s, is for a different level, or the ids do not match. Reported, never
     acted on.
3. `reload/gate.lua` waits until the world is ready: a level is loaded and not loading, at least 10 frames have
   passed, and there is a player vehicle (or 3 s have passed). It gives up after 10 s of real time.
4. `reload/runner.lua` runs the guards once, in order: `levelflag`, `camera`, `gamestate`, `nightlights`,
   `ui_visibility`, `extensions`. Each guard checks, repairs if needed, then re-checks. Only a clean re-check counts
   as `repaired`. Every guard is `pcall`-isolated, so one failure does not stop the rest.
   - The camera guard never reloads or resets the vehicle, since that would reset its damage. When the vehicle's
     camera data is lost, it moves the engine's fallback free camera next to the car and reports a mitigation
     asking the player to press Ctrl+R. It only overrides an active global camera (such as a free camera) when the
     snapshot shows none was active before the reload, so a free camera the player chose is kept.
   - The extensions guard reports extensions that were loaded before and are missing now. Only after a `total`
     failure does it load them again, in one batch, and replay the level-start hooks on just those modules.
5. The snapshot file is deleted, the report is logged, and a toast appears if something was repaired or the blob
   failed (unless "Toast on reload recovery" is off). Some mitigations are re-checked for up to 8 s afterwards,
   because the engine applies some fallbacks a moment later.

The result shows in `get_game_state.lastReloadRecovery`. `recover_game_state` runs the same guards on demand
(dry-run by default, `apply=true` to repair). Without a snapshot, it covers `levelLoaded`, camera, HUD game state,
and night lights.

One constraint for contributors: BeamNG's package serializer calls `onSerialize` / `onDeserialized` on **any**
module in `package.loaded` that exports those names, not only on extensions. Only `beammcp.lua` may export them.
Plain `require`d modules must not, or the hooks fire twice and overwrite each other's state.

## Other supporting pieces

- **Log capture** (`logcapture.lua`): wraps the global `log()` function and keeps the last 500 entries in a ring
  buffer, still passing every call to the original logger. `console_logs` reads this ring and, if asked,
  `beamng.log`. The wrapper is removed on unload so reloads do not stack wrappers.
- **Runtime identity** (`lua/common/beammcp/identity.lua`, `runtime_info`): modules record fingerprints of their
  loaded function bytecode, and the build writes a manifest to `scripts/beammcp/build.json`. `runtime_info`
  reports both. This shows which code is actually loaded; the manifest alone is only a claim.
- **Multiplayer detection** (`tools/lib/mp.lua`): a best-effort check for an active BeamMP session, used by tools
  that would desync multiplayer (see [security.md](security.md#other-gates)).

## Known limitations

- **No SSE and no server-to-client messages.** No progress notifications, no `tools/list_changed`, no sampling.
  Long operations either complete within one call (the await seam) or return immediately and are polled
  (`load_level` and `get_game_state.levelTransition`).
- **JSON-RPC batches are rejected** with `-32600 Invalid Request`. The MCP 2025-06-18 revision removed batching,
  so conforming clients do not send them.
- **Error responses to malformed input omit `id`** instead of sending `"id": null` as JSON-RPC 2.0 prefers. Lua
  tables cannot hold a nil-valued key, and BeamNG's encoder has no null sentinel inside objects. Valid requests
  always carry an id, which is echoed.
- **No session management or version negotiation.** The server always reports protocol version `2025-06-18`.
- **HTTP is minimal.** One request per connection, no keep-alive, no chunked request bodies (send
  `Content-Length`), IPv4 only, no TLS. The header cap counts lines; the length of a single header line is limited
  only by the 10 s read timeout.
- **Synchronous tools run on the main thread.** `lua_eval` and most read tools execute inside the frame. Output
  budgets bound the response, not execution: an infinite loop in `lua_eval` hangs the game. `lua_eval` returns
  only the chunk's first return value.
- **The server only answers while the GE frame runs.** During a level-loading screen, or if the game process is
  frozen (for example by OS display sleep), requests wait or time out even though the port stays open.
- **`cef_eval` needs `-cefdev`**, which is an extra launch option and opens Chromium's debugging port.
