# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Restore owner-only permissions on existing BeamMP tokens when container startup resets file modes.

### Added

- BeamMP server target with a bundled helper, authenticated loopback HTTP and an SSH stdio adapter.
- Optional per-plugin file-queue bridges for bounded Lua inspection/evaluation, observation,
  server/player/vehicle reads, print logs and lifecycle events. No client eval event is registered.
- Reload generation checks, queued-request cancellation, heartbeat shutdown and resource packaging.
- Native Lua 5.3 bridge integration and Go transport/lifecycle tests.

## [0.1.0] - 2026-10-24

Initial public release.

### Added

- Pure-Lua MCP server that runs inside BeamNG.drive's GE Lua VM as a mod, auto-loaded by
  `scripts/beammcp/modScript.lua` and kept alive across level changes and Lua reloads.
- MCP Streamable HTTP transport (JSON responses, protocol `2025-06-18`) on
  `http://127.0.0.1:23512/mcp`, built on BeamNG's bundled `copas` and `luasocket` and pumped from
  `onUpdate` without blocking the simulation.
- 39 tools:
  - Eval: `lua_eval` (GE VM), `vehicle_lua_eval` (vehicle VM), `cef_eval` (CEF JavaScript over the
    DevTools protocol, requires `-cefdev`).
  - Lua discovery and observation: `inspect_lua`, `get_lua_source`, `read_lua`, `observe_lua`,
    `runtime_info`.
  - Game and session: `get_game_state`, `console_logs` (filters and per-caller cursors),
    `list_levels`, `load_level`, `set_ui_state`, `set_sim_speed` (opt-in, refused in BeamMP).
  - Vehicles: `list_vehicles`, `get_vehicle_state`, `get_vehicle_powertrain`, `get_vehicle_tuning`,
    `get_vehicle_config`, `list_spawnable_models`, `list_vehicle_configs`, `get_vehicle_parts`,
    `spawn_vehicle`, `switch_vehicle`, `reset_vehicle`, `teleport_vehicle`, `set_config`.
  - Damage: `get_damage_data`, `trigger_damage`, `get_part_condition`, `list_damage_groups`,
    `damage_vehicle`.
  - Recipes: `list_manipulations`.
  - Visual and UI: `screenshot`, `screenshot_native` (presented frame via Steam, includes ImGui
    overlays), `get_ui_visibility`, `set_ui_visibility`, `reload_cef`.
  - Reload recovery: `recover_game_state`.
- Single-call async tools: screenshots and vehicle-VM evaluation return their result in one call.
- Compact-by-default read tools with `detail`, filter and `limit` arguments; `maxBytes` output
  budgets (default 4096 bytes) on eval, log and observation tools.
- Automatic recovery after a GE Lua reload (camera, HUD game state, night lights, UI layers),
  reported in `get_game_state.lastReloadRecovery`.
- In-game ImGui status panel with live server status and settings (port, bind address, CEF port,
  sim-time control, reload toast, auth).
- Opt-in bearer-token authentication with token copy and regenerate in the panel; loopback
  `Origin`/`Host` validation when auth is off.
- Optional LAN binding, only honoured when auth is enabled.
- Configurable CEF DevTools port (`cefPort`) for setups where another app already uses `:8080`.
- Request hardening: header and body size limits, an idle socket timeout, and auth checked before
  the request body is read.
- Off-engine LuaJIT test suite (`scripts/run-tests.ps1`).
- `scripts/link-mod.ps1` for a development junction install or a release zip build.

[0.1.0]: https://github.com/DasSheep/BeamNG-MCP/releases/tag/v0.1.0
