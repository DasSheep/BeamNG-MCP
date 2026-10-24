# BeamMP server target

The BeamMP target is a server resource with a bundled Go helper. It runs without a connected game
and needs no Lua C modules, Node installation or system service on the server. The existing BeamNG
target remains available for game physics, rendering, screenshots and UI work.

## Build and install

Build with Go 1.23+ and a POSIX shell. Builds use the Go standard library only:

```sh
sh scripts/build-beammp.sh dist/beammp linux amd64
# Other build targets: linux arm64, windows amd64, windows arm64.
```

Copy `dist/beammp/linux-amd64/BeamMCP` to the server's `Resources/Server/BeamMCP`. Copy
`config.example.json` to `config.json` and set `enabled` to `true`. Set `allowEval` to `true` only
for trusted development access. `listen` defaults to `127.0.0.1:23513`; only numeric loopback
addresses are accepted. On Linux, retain executable permission on `lib/beammcp-helper`.

The first start creates a cryptographically random bearer token in `BeamMCP/token` with owner-only
permissions. Protect the resource directory and its configuration with the server account's filesystem
permissions. The helper inherits that account's privileges. Do not put this resource or its token in
`Resources/Client` or an archive served to players. Runtime sessions and tokens are excluded from Git.

For each plugin to inspect, copy `beammp/examples/z_beammcp.lua` into that plugin's top-level directory
and replace `Example` with its resource name. Each bridge can additionally set `allowEval=false`.
Names must contain 1 to 64 ASCII letters, digits, underscores or hyphens.

Start or restart the server. New files and resources are not discovered by BeamMP's existing hot-reload
monitor. For an initial install without restarting, enter the stock server console's default `lua`
state, run `dofile('Resources/Server/BeamMCP/main.lua')`, and detach with `:exit`. Then enter each
target's state with `lua PluginName`, execute its bridge file with `dofile`, and detach. This initially
hosts BeamMCP in the Console state; the next normal server restart loads its dedicated BeamMCP state.
Do not inject commands into an occupied or unattended console prompt.

## Connect

For a server on the same machine, use Streamable HTTP at `http://127.0.0.1:23513/mcp` with
`Authorization: Bearer <contents of token>`. Authentication applies to every request and browser
origins are rejected. The MCP protocol version is `2025-06-18`, with JSON responses and no SSE.

For a remote Docker server, configure an MCP client with the following **stdio command**. SSH uses
the operator's existing key and the adapter reads the token inside the container; the token is never
placed on the command line or printed:

```sh
ssh -T -o BatchMode=yes root@HOST docker exec -i -w /beamngmp CONTAINER Resources/Server/BeamMCP/lib/beammcp-helper stdio Resources/Server/BeamMCP
```

Use the server's actual working directory and container name. No additional published Docker port
is needed. For non-Docker hosts, execute the helper's `stdio <resource-path>` command through SSH
from the BeamMP working directory.

## Tools

| Tool | Behavior |
|---|---|
| `list_plugins` | Registered, heartbeating bridges and their generations |
| `runtime_info` | Target Lua/server versions, loaded modules and build provenance claim |
| `get_server_state` | Server settings and player count |
| `list_players` | Connected players; omits account identifiers and IP addresses |
| `list_vehicles` | Player/vehicle IDs, model, latest client-reported pose and optional config |
| `lua_eval` | Trusted evaluation inside the selected plugin, when enabled |
| `inspect_lua`, `get_lua_source` | Bounded raw inspection and function-source lookup |
| `read_lua`, `observe_lua` | Named path reads and samples across successive plugin ticks |
| `console_logs` | Target plugin's captured `print` output after the bridge attached |
| `recent_events` | Observed player/vehicle lifecycle events; no chat capture |

Inspection, reading, observation and evaluation require an explicit `plugin`. Server-wide reads
default to `BeamMCP`. Results default to 4096 encoded bytes (`maxBytes`: 1024 to 16384). Collection
reads take `limit` (1 to 100); log/event reads take a cursor scoped to their returned generation.
Print capture does not include earlier logs, other plugin states, native logs or `Util.Log*` calls.

```json
{"name":"read_lua","arguments":{"plugin":"Example","fields":[{"name":"pending","path":["DebugState","pending"]}]}}
```

Paths start at the target's globals. They cannot access closure-local variables automatically.
Expose a debug table or deliberate accessors from the plugin when those are needed. Inspection and
observation never call accessors; invoke deliberate accessors through evaluation.

`observe_lua` takes `duration` (0.05 to 10 seconds), `interval` (0.05 to 2 seconds), optional
`samples`, and an optional condition `{ "field": "pending", "op": "eq", "value": 0 }`.
Operators are `eq`, `ne`, `gt`, `ge`, `lt`, `le`, `changed`, `exists` and `missing`. Observations
report sample counts, changes and numeric ranges. They fail if the target reloads during observation.

## Execution and lifecycle

The helper owns HTTP and queues at most eight simultaneous tool calls. Each bridge claims at most
one file request per 50 ms best-effort timer tick. Network requests never block the Lua timer.
Requests carry random IDs, a plugin generation and a deadline. Unclaimed requests are removed on
cancellation. After a request has been claimed, timeouts report `execution=unknown`: a mutation may
have executed, so never retry automatically. A timeout does not interrupt already running Lua code.

Evaluation has full server-plugin privileges and is not sandboxed. Output budgets do not stop an
infinite loop, a long native call or code that changes the debug bridge itself. Use bounded code.
There is no evaluation handler registered with BeamMP events; clients cannot submit eval payloads
through custom server events. Treat local filesystem access as privileged access.

An `onInit` callback refreshes the target generation after BeamMP reloads a plugin. Bridge reattachment
replaces its own timer and print wrapper. The resource stops its helper on reload/shutdown; a helper
also exits after 15 seconds without the resource heartbeat. Superseded generations and late replies
are reaped inside its session. A dead helper stops the resource after its heartbeat expires; inspect
the session's `helper.log` while it exists and reload `main.lua` to recover.

To uninstall, call `BeamMCPShutdown()` in its hosting state and `BeamMCPBridge.shutdown()` in each
target state before removing the resource and bridge files. File deletion alone does not unload a
running Lua module. Configurations, the token and the deployed resource persist across restarts.

## Verification

Run the existing LuaJIT suite with `powershell -File scripts/run-tests.ps1`. The BeamMP runtime
tests also run under native Lua 5.3:

```sh
lua5.3 test/runner.lua test/beammp_runtime_test.lua
cd beammp/helper
go test -race ./...
go vet ./...
```

With `lua5.3` on PATH, Go tests exercise actual file queues and two isolated Lua plugin processes,
including target isolation, source lookup and reload generations. This harness models BeamMP APIs;
it does not establish live BeamMP acceptance. Verify the packaged resource on the intended server
and distinguish that from game-client or Windows acceptance.
