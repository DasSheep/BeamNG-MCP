# BeamNG-MCP

A [Model Context Protocol](https://modelcontextprotocol.io) server that runs **inside BeamNG.drive**.
It is a pure-Lua mod that lives in the game's GE (game-engine) Lua VM and lets an AI agent such as
Claude Code read live game state, drive the world (spawn, configure, teleport and damage vehicles,
load levels, take screenshots) and evaluate Lua or JavaScript in the running game. There is no
external process, proxy or launch flag: install the mod, start the game, point your MCP client at
`http://127.0.0.1:23512/mcp`.

It is useful for in-engine testing of your own BeamNG mods, poking at live telemetry, scripted
automation, and exploring the game's Lua APIs with an agent.

A separate [BeamMP server target](docs/beammp.md) packages a resource-contained helper and optional
plugin bridges for server-side Lua inspection, evaluation, event diagnostics and player/vehicle
snapshots. It works without a connected game; game physics and visual tools remain in this target.

## Highlights

- **39 MCP tools** covering Lua/JS evaluation, Lua API discovery, bounded runtime observation,
  vehicle telemetry and control, damage, part configs, levels, UI and screenshots.
  See [docs/tools.md](docs/tools.md).
- **Runs in the game.** MCP Streamable HTTP (JSON responses, protocol `2025-06-18`) served by a small
  HTTP/1.1 server built on BeamNG's bundled `copas` + `luasocket`, pumped non-blockingly from
  `onUpdate` so it never stalls the simulation.
- **Single-call async tools.** Screenshots and vehicle-VM evaluation return their result in one MCP
  call, with no polling.
- **Compact by default.** Read tools return small payloads and take `detail` / filter / `limit`
  arguments when you need more. Eval, log and observation tools cap their output with `maxBytes`.
- **In-game status panel** (ImGui) showing server state, with settings you can change while playing.
- **Opt-in bearer-token auth**, required before the server will bind to anything other than loopback.
- **Lua-reload recovery.** After a GE Lua reload the server repairs engine state the reload loses
  (camera, HUD game state, night lights, UI layers) and reports what it did.
- **CEF access.** `cef_eval` runs JavaScript in the game's Chromium UI over the DevTools protocol
  when BeamNG is launched with `-cefdev`.

> ⚠️ **Security: this server can run arbitrary code in your game.** `lua_eval`,
> `vehicle_lua_eval` and `cef_eval` execute whatever code the client sends, with the game's full
> Lua/JS privileges. By default the server listens on `127.0.0.1` only, has no authentication, and
> rejects browser requests whose `Origin`/`Host` is not loopback. **Turn on auth before you expose
> it through a tunnel or to your LAN.** Only connect clients and agents you trust.
> See [docs/security.md](docs/security.md) and [SECURITY.md](SECURITY.md).

## Requirements

- **BeamNG.drive 0.39.x.** This is the version the server is developed and tested against. Some
  engine APIs it uses changed in 0.39 (for example, the screenshot entry point), so older versions
  are not supported.
- An MCP client that supports the Streamable HTTP transport (Claude Code, Codex, Cursor and others;
  see [docs/clients.md](docs/clients.md)).
- Optional: launch the game with `-cefdev` for `cef_eval`; launch it through Steam for
  `screenshot_native`.

The mod itself is plain Lua. The helper scripts in `scripts/` are Windows PowerShell.

## Install

### From a release

1. Download `beammcp.zip` from the [Releases page](https://github.com/DasSheep/BeamNG-MCP/releases)
   (or build it yourself, see below).
2. Put the zip, unextracted, in the `mods` folder of your BeamNG user folder. By default that is:
   ```
   %LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\
   ```
3. Start BeamNG.drive and make sure the mod is enabled in the Mod Manager.

The server starts automatically when the game loads (via `scripts/beammcp/modScript.lua`) and
survives level changes and Lua reloads. You should see the **BeamMCP** panel in the main menu.

To uninstall, delete `beammcp.zip` from `mods`. Settings live in `settings/beammcp.json` in the same
user folder.

### From source

```powershell
git clone https://github.com/DasSheep/BeamNG-MCP.git
cd BeamNG-MCP

# Build the release zip yourself -> dist\beammcp.zip, then copy it into mods\ as above
powershell -File scripts\link-mod.ps1 -Zip

# Or, for development: link the repo into the game as an unpacked mod (junctions, no admin needed)
powershell -File scripts\link-mod.ps1
# add -UserPath '<BeamNG user folder>' if yours is not the default
```

The development link makes `mods\unpacked\beammcp` point at the repo, so edits to `lua/` go live on
the next in-game Lua reload. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Connect a client

With the game running, add the server to Claude Code:

```
claude mcp add beammcp --transport http http://127.0.0.1:23512/mcp
```

Other clients (Codex, Cursor, ChatGPT developer mode and more), auth headers, and multi-machine
setups are covered in [docs/clients.md](docs/clients.md).

## Quick tour

Things you can ask an agent once it is connected:

- "What car am I driving, and how fast is it going?"
- "List the levels, load West Coast USA, and tell me when it's ready."
- "Spawn a pickup 20 m ahead of me without switching to it."
- "Show me this car's tuning options for the suspension, then lower the ride height."
- "Break the front bumper off, take a screenshot, then reset the car."
- "Watch the engine RPM for 2 seconds while I rev it and give me the min and max."
- "Find the GE Lua functions in `core_vehicle_manager` and show me the source of `getVehicleData`."
- "Show the last 20 warnings from the console log."

## Tools

39 tools in total. Full arguments, defaults and limits are in [docs/tools.md](docs/tools.md).

| Group | Tools | What they do |
|-------|-------|--------------|
| Eval | `lua_eval`, `vehicle_lua_eval`, `cef_eval` | Run Lua in the GE VM or a vehicle's VM, or JavaScript in a CEF page (needs `-cefdev`) |
| Lua discovery | `inspect_lua`, `get_lua_source` | Browse live globals/tables in GE or vehicle Lua, and read a function's source, without executing inspected code ([docs/lua-inspection.md](docs/lua-inspection.md)) |
| Runtime observation | `read_lua`, `observe_lua`, `runtime_info` | Read named Lua paths, sample them over time or wait for a condition, and report loaded-code origins ([docs/runtime-observation.md](docs/runtime-observation.md)) |
| Game and session | `get_game_state`, `console_logs`, `list_levels`, `load_level`, `set_ui_state`, `set_sim_speed` | Session snapshot, filtered logs with cursors, map catalog and loading, UI routing, slow-motion/pause (opt-in) |
| Vehicle state | `list_vehicles`, `get_vehicle_state`, `get_vehicle_powertrain`, `get_vehicle_tuning`, `get_vehicle_config` | Spawned vehicles, kinematics, drivetrain tree, tuning variables with ranges, installed parts |
| Vehicle catalog | `list_spawnable_models`, `list_vehicle_configs`, `get_vehicle_parts` | Models, factory configs, and a model's parts for building a config |
| Vehicle control | `spawn_vehicle`, `switch_vehicle`, `reset_vehicle`, `teleport_vehicle`, `set_config` | Spawn (with placement, optionally in the background), switch, reset, move a live vehicle, swap or patch its config |
| Damage | `get_damage_data`, `trigger_damage`, `get_part_condition`, `list_damage_groups`, `damage_vehicle` | Damage-tracker flags, per-part physical damage, and applying physical damage |
| Recipes | `list_manipulations` | Catalog of ready-made Lua recipes (torque, time of day, paint and more), each with caveats and a restore step |
| Visual and UI | `screenshot`, `screenshot_native`, `get_ui_visibility`, `set_ui_visibility`, `reload_cef` | Scene capture, presented-frame capture via Steam, hide/show UI layers, hot-reload the CEF UI |
| Reload recovery | `recover_game_state` | Check or repair engine state lost in a Lua reload |

Notes:

- `screenshot` captures the scene render target, so ImGui overlays are not in it. `screenshot_native`
  captures the presented frame through Steam's overlay and does include them, but needs a one-time
  setup. See [docs/screenshots.md](docs/screenshots.md).
- `set_sim_speed` is off until you enable **Allow sim-time control** in the panel. It and
  `load_level` refuse to run during a BeamMP multiplayer session.

## In-game panel

The **BeamMCP** ImGui window shows whether the server is running, its `host:port`, tool count,
uptime, request count and last activity, and whether the CEF DevTools endpoint is reachable. It
appears in the main and pause menus and hides during gameplay unless you tick **Keep visible in
gameplay**.

From the panel you can change the port, bind address and CEF port, toggle **Allow sim-time
control**, **Toast on reload recovery** and **Require auth (token)**, and use **Copy token** /
**Regenerate token** (regenerating asks for confirmation). The panel only shows a short fingerprint
of the token, never the full value.

## Configuration

Settings are stored in `settings/beammcp.json` in your BeamNG user folder. The panel is the normal
way to change them; editing the file works too (restart the game afterwards).

| Key | Default | Meaning | Applies |
|-----|---------|---------|---------|
| `port` | `23512` | HTTP port (1024-65535) | next game start |
| `bindHost` | `"127.0.0.1"` | Listen address. A non-loopback address is ignored (falls back to loopback, with a warning) unless `requireAuth` is on | next game start |
| `requireAuth` | `false` | Require `Authorization: Bearer <token>` on every request | immediately |
| `authToken` | generated | The bearer token, created when auth is first enabled | immediately |
| `cefPort` | `8080` | Port of BeamNG's `-cefdev` DevTools endpoint used by `cef_eval` | immediately |
| `simControl` | `false` | Allow `set_sim_speed` to slow or pause the simulation | immediately |
| `reloadToast` | `true` | Show an in-game toast after automatic reload recovery | immediately |
| `pinned` | `false` | Keep the panel visible during gameplay | immediately |

### Turning on auth

1. Tick **Require auth (token)** in the panel. A token is generated the first time.
2. Click **Copy token**.
3. Configure your client to send `Authorization: Bearer <token>`. For Claude Code, re-add the server
   with `--header "Authorization: Bearer <token>"`, or add a `headers` entry to its config.

Auth takes effect immediately, so your current client will get `401` responses until you add the
header. With auth on, the loopback `Origin`/`Host` checks are relaxed, since the token is the
boundary; this is what makes tunnels and LAN access work. Details: [docs/security.md](docs/security.md).

### LAN access

Set the bind address to `0.0.0.0` or a specific LAN IP, enable auth, and restart the game. This lets
one client drive several game instances on different machines; add each as its own MCP server with
its own token. See [docs/clients.md](docs/clients.md).

## Troubleshooting

**The server stops answering, but the game is still open.** Check whether the display went to sleep.
Windows display sleep can freeze the whole BeamNG process, which stops the `onUpdate` pump that
drives the server: the port stays open but nothing replies. Keep the screen awake during agent
sessions.

**`cef_eval` can't find BeamNG, or the panel shows CEF targets that aren't BeamNG's.** Steam's own
web helper can also expose DevTools on `:8080`, the same default port as BeamNG's `-cefdev` (this is
common on SteamOS). The server only talks to BeamNG's `local://` pages, so it won't touch Steam's,
but `cef_eval` needs BeamNG's endpoint. Set **cef port** in the panel (or `cefPort`) to BeamNG's
actual DevTools port, or free `:8080`. See [docs/cef-cdp.md](docs/cef-cdp.md).

**`cef_eval` says to launch with `-cefdev`.** The DevTools endpoint only exists when the game is
started with that flag.

**New or changed tools don't show up in the client.** Most clients cache the tool list; reconnect
the server (in Claude Code, `/mcp`) after updating the mod.

**Port change or LAN bind didn't take effect.** Those apply on the next game start.

**My client gets `401` or `403`.** `401` means auth is on and the token is missing or wrong. `403`
means auth is off and the request carried a non-loopback `Origin` or `Host` header (a browser page,
or a tunnel). Enable auth for tunnelled access.

## About BeamNG's built-in MCP server

Recent BeamNG.drive versions ship their own MCP server. BeamNG-MCP is independent of it and the two
can run side by side: this project uses its own port, offers bearer-token auth and LAN binding, and
focuses on a different tool set (bounded Lua inspection and observation, CEF eval, reload recovery,
compact read tools).

## Documentation

| Document | Contents |
|----------|----------|
| [docs/tools.md](docs/tools.md) | Every tool, its arguments, defaults and limits |
| [docs/clients.md](docs/clients.md) | Connecting Claude Code, Codex, Cursor, ChatGPT and others |
| [docs/architecture.md](docs/architecture.md) | How the server is put together |
| [docs/security.md](docs/security.md) | Threat model, auth, Origin/Host checks, network binding |
| [docs/cef-cdp.md](docs/cef-cdp.md) | `cef_eval`, `-cefdev`, and external DevTools clients |
| [docs/screenshots.md](docs/screenshots.md) | `screenshot` vs `screenshot_native`, Steam setup and pruning |
| [docs/lua-inspection.md](docs/lua-inspection.md) | `inspect_lua` and `get_lua_source` in depth |
| [docs/runtime-observation.md](docs/runtime-observation.md) | `read_lua`, `observe_lua`, `console_logs` cursors, `runtime_info` |
| [CHANGELOG.md](CHANGELOG.md) | Release history |

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the dev
setup, test suite and code conventions. Please report security problems privately as described in
[SECURITY.md](SECURITY.md), not in public issues.

## License

GPL-3.0. See [LICENSE](LICENSE).

## Acknowledgements

- The Lua inspection tools were inspired by E32k's MIT-licensed Lua Globals Explorer. The
  implementation here is independent.
- The HTTP server is built on the `copas` and `luasocket` libraries that ship with BeamNG.drive.
- BeamNG.drive is a product of BeamNG GmbH. This project is not affiliated with or endorsed by
  BeamNG GmbH.
