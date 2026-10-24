# Contributing to BeamNG-MCP

Thanks for your interest. Bug reports, fixes, new tools and documentation improvements are all
welcome. This page covers the dev setup, the test suite, how the code is laid out, and the
conventions new code should follow.

By contributing you agree that your contributions are licensed under the project's
[GPL-3.0 license](LICENSE).

## Development setup

You need:

- Windows with PowerShell (the helper scripts are PowerShell; Windows PowerShell 5.1 works).
- BeamNG.drive 0.39.x for in-game testing.
- [LuaJIT](https://luajit.org) for the off-engine tests:
  ```powershell
  winget install -e --id DEVCOM.LuaJIT
  ```

Clone the repo and link it into the game:

```powershell
git clone https://github.com/DasSheep/BeamNG-MCP.git
cd BeamNG-MCP
powershell -File scripts\link-mod.ps1
# add -UserPath '<BeamNG user folder>' if yours is not %LOCALAPPDATA%\BeamNG\BeamNG.drive\current
```

`link-mod.ps1` builds `dist\beammcp\` (with `lua` as a junction to the repo's `lua\`, plus a copy of
`modScript.lua` and a `build.json` manifest) and junctions `<user folder>\mods\unpacked\beammcp` to
it. Junctions need no admin rights. Because the mod is plain Lua with no build step, the game runs
your working tree directly.

The edit loop:

1. Edit files under `lua/`.
2. Reload GE Lua in the game (`Ctrl+L`), or restart the game.
3. Reconnect your MCP client if you added, removed or changed a tool definition, since clients cache
   the tool list.

If you change `scripts/beammcp/modScript.lua`, run `link-mod.ps1` again (it copies that file rather
than linking it). If BeamNG has another copy of the mod installed, such as a `beammcp.zip` in
`mods\`, remove it so it doesn't shadow your linked copy.

Do not delete `dist\beammcp` or `mods\unpacked\beammcp` with a recursive delete: they contain
junctions into your repo. Re-run `link-mod.ps1`, which removes junctions safely.

To build the release zip (`dist\beammcp.zip`):

```powershell
powershell -File scripts\link-mod.ps1 -Zip
```

## Running the tests

```powershell
powershell -File scripts\run-tests.ps1
```

This runs every `test/*_test.lua` file through `test/runner.lua` under LuaJIT, with no game needed.
It prints one dot per test and ends with `N passed, M failed`. All tests should pass before you open
a pull request.

`test/build-manifest_test.ps1` covers the manifest script and is run separately:

```powershell
powershell -File test\build-manifest_test.ps1
```

Off-engine tests can't prove that something works in the game. For changes that touch engine
calls, also try them in BeamNG and say in the PR what you checked.

## Code layout

```
lua/
  ge/extensions/
    beammcp.lua                 extension entry point: settings, tool registration, onUpdate pump
    beammcp/
      core/                     transport-agnostic MCP core: jsonrpc, registry, methods
      http/                     HTTP/1.1 edge: server, exchange, message parsing, MCP endpoint + auth
      async/                    single-call await, copas sleep, GE -> vehicle VM bridge
      cdp/                      Chrome DevTools Protocol client and target discovery (cef_eval)
      reload/                   Lua-reload detection, snapshot and recovery guards
      tools/                    one file per tool (or small group of related tools)
      tools/lib/                shared helpers: shape (compact output), veh (vehicle id), mp (BeamMP), ...
      panel.lua, status.lua     in-game ImGui panel and live status record
      store.lua, bind.lua       settings persistence and bind-address validation
      instructions.lua          the MCP initialize instructions sent to clients
      logcapture.lua            console log ring buffer
  common/beammcp/               code shared by the GE and vehicle VMs (inspect, observe, output, identity)
scripts/
  beammcp/modScript.lua         auto-loader the game runs at startup
  link-mod.ps1                  dev junction install / release zip
  run-tests.ps1                 test entry point
  build-manifest.ps1            writes scripts/beammcp/build.json
  link-steam-screenshots.ps1    one-time setup for screenshot_native
  prune-steam-screenshots.ps1   safe cleanup of screenshot_native captures
test/
  runner.lua                    minimal test runner (test, assertEqual, assertTrue, assertNil, assertMatch)
  support/                      BeamNG global stubs and a scoped stub helper
  vendor/                       third-party test-only code (JSON)
  *_test.lua                    one test file per module
docs/                           user and design documentation
```

See [docs/architecture.md](docs/architecture.md) for how the pieces fit together.

## Conventions

### Tools

- **One tool per file** in `lua/ge/extensions/beammcp/tools/`. A small group of closely related
  tools may share a file (for example `ui_visibility.lua` has the get and set tools).
- Each file is a plain module that exports its definition as `M.def` (with `description`,
  `annotations`, `inputSchema` and `handler`) and a `M.register(registry)` that calls
  `registry:add("tool_name", M.def)`. Register new tools in `M.onExtensionLoaded` in
  `lua/ge/extensions/beammcp.lua`.
- Handlers return a result table, or `nil, "tool_name: what went wrong"` on error. Validate
  arguments up front and give actionable messages.
- Set `annotations` honestly (`readOnlyHint`, `destructiveHint`, `openWorldHint`).
- Tools that must refuse during a BeamMP session should use `tools/lib/mp.lua`.

### Keep engine calls stubbable

Put calls into BeamNG globals behind small module functions (`M.capture`, `M.doTeleport`, ...) and
keep the logic around them in pure functions. Tests replace those functions with stubs, so argument
parsing, shaping and error handling can be tested off-engine. Use `test/support/stub.lua`
(`stub.with`) to override fields for the duration of a test; tests share one process, so stubs must
not leak.

### Compact by default

Agents pay for every byte a tool returns. Read tools should:

- return a compact summary by default;
- offer `detail=true` (or `full=true`) for the expanded view;
- offer filters (`filter=`, `type=`, `category=`, ...) and a `limit` with a sensible cap, and report
  the true `total` plus a short note when output is capped (`tools/lib/shape.lua` has helpers).

Tools that return arbitrary data (eval, logs, observation) take a `maxBytes` budget: default 4096
encoded bytes, configurable from 1024 to 16384, with `truncated=true` when output was cut. Reuse the
helpers in `lua/common/beammcp/output.lua` rather than writing new ones.

### Lifecycle and reload safety

- Never export `onSerialize`, `onDeserialized` or `M.state` from a plain `require`d module. BeamNG's
  package serializer calls those hooks on every loaded module, not just extensions. Only
  `beammcp.lua` should define them.
- Don't block in `onUpdate`. Long-running work goes in a copas coroutine and yields.

### Tests and style

- Every new module gets a `test/<module>_test.lua`. Bug fixes should come with a test that fails
  without the fix.
- Match the style of the surrounding code: two-space indent, `local M = {}` modules, short header
  comment explaining what the file is for and why.
- Keep pull requests focused on one change. Update `docs/tools.md` and `CHANGELOG.md` when you add
  or change a tool.

## Reporting bugs

Open an issue on [GitHub Issues](https://github.com/DasSheep/BeamNG-MCP/issues) with:

- your BeamNG.drive version, and the BeamNG-MCP release you installed (or the commit, if you built
  from source);
- the MCP client you use;
- what you did, what you expected, and what happened;
- relevant lines from `console_logs` or `beamng.log` (entries tagged `beammcp.*`).

Feature requests are welcome as issues too.

## Reporting security issues

Please do **not** open a public issue for security problems. This server can execute arbitrary code
in the game, so vulnerabilities in auth, binding or request handling matter. Follow the private
reporting process in [SECURITY.md](SECURITY.md).
