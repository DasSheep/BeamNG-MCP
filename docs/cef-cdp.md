# CEF and the Chrome DevTools Protocol

BeamNG.drive's menus, HUD apps and vehicle gauge screens are web pages rendered by an embedded
Chromium (CEF). When the game is launched with `-cefdev`, CEF exposes a Chrome DevTools Protocol
(CDP) endpoint. BeamNG-MCP can use it in two ways:

- **`cef_eval`**, built into the server: run JavaScript in a BeamNG page and get the value back.
- **An external CDP client** such as `chrome-devtools-mcp`, attached to the same endpoint, for
  interactive automation (selectors, clicks, CEF-layer screenshots, console and network).

Both need `-cefdev`. Without it there is no DevTools endpoint and `cef_eval` returns an error asking
whether the game was launched with `-cefdev`. The rest of the server works normally either way.

## Launching with `-cefdev`

`-cefdev` is a launch argument, not an in-game setting.

- **Steam:** right-click BeamNG.drive in the library, **Properties > General > Launch Options**,
  add `-cefdev`, then start the game normally.
- **Direct launch:** start the game executable with the flag, for example
  `BeamNG.drive.x64.exe -cefdev` from the game's `Bin64` folder.

The endpoint is `http://localhost:8080`. Check it from a shell:

```sh
curl -s http://localhost:8080/json/version   # browser and protocol version
curl -s http://localhost:8080/json           # list of targets (pages)
```

The BeamMCP panel shows the endpoint state, re-checked every few seconds:
`CEF DevTools :8080  active (N targets)` or `CEF DevTools :8080  inactive - launch -cefdev`. Only
BeamNG pages are counted. `runtime_info` with `probe: true` runs a fresh discovery and reports the
same information to an agent.

The DevTools endpoint has no authentication of its own: any process on the machine can attach to it
and run JavaScript in the game UI. BeamNG-MCP's bearer auth does not cover it. Don't forward port
8080 off the machine, and leave `-cefdev` out of your normal launch options if you don't need it.

## Targets: BeamNG pages only

Each CEF page is a CDP target. The set changes with game state: vehicle gauge screens appear and
disappear as vehicles spawn and despawn. Typical BeamNG targets:

| Title | URL |
|-------|-----|
| `BeamNG Main UI` | `local://local/ui/entrypoints/main/index.html#/...` |
| `<id>-@<model>_gauges_display` | `local://local/vehicles/<model>/gauges_screen/gauges_screen.html` |

BeamNG pages are always served from the `local://` scheme. The server considers only targets of
type `page` whose URL starts with `local://`. Anything else on the endpoint (for example Steam's own
web helper, see below) is never counted, listed, or evaluated, even if its title happens to match.

## `cef_eval`

`cef_eval` discovers the targets, picks one, opens a WebSocket to it and runs `Runtime.evaluate`.
The CDP client is written in Lua and runs on the server's own event loop, so no extra process is
involved.

| Argument | Meaning |
|----------|---------|
| `code` (required) | JavaScript expression to evaluate |
| `target` | Case-insensitive substring of a BeamNG page's URL or title. Default: the Main UI page (`main/index.html`) |
| `maxBytes` | Encoded result budget, 1,024 to 16,384, default 4,096. `truncated: true` marks omitted data |

Behaviour:

- The result is returned by value as `{"value": ...}`, so return JSON-serializable data (strings,
  numbers, plain objects, arrays). An expression that evaluates to `undefined` returns no value.
- Promises are awaited, so `fetch(...)`-style async expressions work.
- JavaScript exceptions are returned as tool errors with the exception text.
- If no BeamNG page matches `target`, the error lists the titles of the available BeamNG pages.
- Each call is bounded: five seconds for the whole exchange, 1 MiB per CDP message, and a frame
  limit. See [runtime-observation.md](runtime-observation.md) for the exact limits.

Examples:

```json
{"code": "location.href"}
{"code": "({title: document.title, nodes: document.querySelectorAll('*').length})"}
{"code": "document.title", "target": "gauges"}
```

`cef_eval` is a full code-execution tool: it can change UI state, local storage and anything else
the page's JavaScript can reach. Related tools that don't need `-cefdev`: `reload_cef` reloads the
CEF UI layer, and `get_ui_visibility` / `set_ui_visibility` hide or show the CEF and ImGui layers.

## Attaching an external CDP client (opt-in)

For richer interactive work, an off-the-shelf CDP client can attach to the same endpoint alongside
BeamNG-MCP. [`chrome-devtools-mcp`](https://www.npmjs.com/package/chrome-devtools-mcp) is an MCP
server that wraps CDP and needs Node.js:

```sh
claude mcp add chrome-devtools-mcp -- npx -y chrome-devtools-mcp@latest --browserUrl http://localhost:8080
```

or in a project `.mcp.json`:

```json
{
  "mcpServers": {
    "chrome-devtools-mcp": {
      "command": "npx",
      "args": ["-y", "chrome-devtools-mcp@latest", "--browserUrl", "http://localhost:8080"]
    }
  }
}
```

Start a new client session after adding it; its tools are fixed when the session starts. Its useful
tools against BeamNG include `list_pages`, `select_page` (attach to an already-open page; `pageId` is
the number from `list_pages` and must be passed as a JSON number), `evaluate_script`,
`take_screenshot` and `list_console_messages`. `list_pages` shows every target on the endpoint,
including non-BeamNG ones, so pick a `local://` page.

Keep it opt-in rather than in a default config. It starts an extra Node process every session and
shows up as a failed server whenever the game was launched without `-cefdev`.

`chrome-devtools-mcp` screenshots capture only the CEF layer (UI and gauges over a transparent
background), not the 3D scene. For the rendered world use BeamNG-MCP's `screenshot`; see
[screenshots.md](screenshots.md).

### Probe script

`scripts/cdp/mcp_probe.py` checks the whole external path end to end. With the game running under
`-cefdev`:

```sh
python scripts/cdp/mcp_probe.py
```

It uses only the Python standard library, starts `chrome-devtools-mcp` via `npx`, performs the MCP
handshake and lists its tools, finds and selects the Main UI page, reads a few DOM facts with
`evaluate_script`, saves a CEF screenshot to `scripts/cdp/cef_shot.png`, and lists console messages,
printing every response. The child process's stderr goes to `scripts/cdp/probe.stderr.log`. The
endpoint is fixed at `http://localhost:8080` (`CDP_URL` at the top of the script).

## Port 8080 collisions with Steam

Steam's built-in web helper is also Chromium, and when its remote debugging is enabled it listens on
`:8080` too. This is common on Linux and Steam Deck, where tools such as Decky Loader can enable it
(Decky's "Allow Remote CEF Debugging" option; on Linux a `.cef-enable-remote-debugging` file in the
Steam folder does the same). Whichever process takes the port first keeps it, and the game does not
retry later.

Symptoms:

- The panel shows the endpoint active, but `cef_eval` fails with a message that the endpoint has
  some targets but "none are BeamNG (local://)".
- `curl http://localhost:8080/json` lists Steam pages (`steamloopback.host`, `about:blank`, `data:`)
  instead of `local://` ones.

Because of the `local://` filter, the server never evaluates code in a Steam page. To get `cef_eval`
working:

1. **Free port 8080 for the game:** disable Steam's CEF remote debugging, restart Steam, then start
   BeamNG with `-cefdev`. The order matters.
2. **Or point the server at a different port:** if BeamNG's DevTools endpoint is reachable on
   another port, set **cef port** in the BeamMCP panel (or `cefPort` in `settings/beammcp.json`) to
   that port. Accepted range is 1024 to 65535, and the change applies immediately.

`-cefdev` has no documented port argument, and the game uses 8080 by default, so option 1 is
usually the practical fix. `cefPort` only changes where BeamNG-MCP looks; it does not move the
game's endpoint. The probe script and the `chrome-devtools-mcp` examples above also assume 8080;
adjust their URLs if you use a different port.

## Troubleshooting

**The endpoint stops answering mid-session.** If both the DevTools endpoint and the MCP server go
silent while the game window is still open, the display has probably gone to sleep. Windows display
sleep can freeze the whole BeamNG process: the ports stay bound but nothing replies. Keep the
display awake during agent sessions.

**`cef_eval` says the endpoint is not reachable.** The game wasn't started with `-cefdev`, another
process holds the port, or `cefPort` points at the wrong port.

**`cef_eval` can't find a page.** Vehicle gauge pages exist only while that vehicle is spawned. Run
`cef_eval` with `{"code": "document.title"}` and a deliberately wrong `target` to get the list of
available BeamNG pages.
