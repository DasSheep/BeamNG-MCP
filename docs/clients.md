# Connecting MCP clients

BeamNG-MCP runs inside the game and listens for MCP requests while BeamNG.drive is running. Any
client that speaks the MCP **Streamable HTTP** transport can connect to it directly. Clients whose
connector runs in the vendor's cloud (ChatGPT) need an HTTPS tunnel and auth.

- [Endpoint and transport](#endpoint-and-transport)
- [Claude Code](#claude-code)
- [OpenAI Codex CLI](#openai-codex-cli)
- [Cursor, Claude Desktop and other clients](#cursor-claude-desktop-and-other-clients)
- [ChatGPT developer mode](#chatgpt-developer-mode)
- [Several game instances or LAN access](#several-game-instances-or-lan-access)
- [Smoke test](#smoke-test)
- [Troubleshooting](#troubleshooting)

## Endpoint and transport

| | |
|---|---|
| URL | `http://127.0.0.1:23512/mcp` |
| Transport | MCP Streamable HTTP, `POST /mcp` only |
| Responses | Plain `application/json`, one JSON-RPC response per request. No SSE stream: `GET /mcp` returns `405`, which the spec allows for JSON-only servers |
| Sessions | Stateless. No `Mcp-Session-Id` is issued |
| Protocol version | `2025-06-18` |
| Batches | Not supported; a JSON-RPC batch array gets error `-32600` |
| Auth | Off by default. When on: `Authorization: Bearer <token>` on every request |

Notes:

- The port is set in the in-game **BeamMCP** panel (or `port` in `settings/beammcp.json`) and takes
  effect on the next game start. Replace `23512` everywhere below if you changed it.
- Use `127.0.0.1`, not `localhost`. The listener is IPv4 only, and some clients resolve `localhost`
  to the IPv6 address `::1` first, which fails.
- Clients that only support the older HTTP+SSE transport (a separate `/sse` endpoint) cannot
  connect.
- The server only answers while the game is running and its frame loop is ticking. Start the game
  before your client, or reconnect the client after the game is up.

### When auth is off (the default)

The server accepts requests only from the local machine, and it rejects (`403`) any request whose
`Origin` or `Host` header names something other than `127.0.0.1` or `localhost`. That blocks web
pages and DNS-rebinding tricks. Command-line and desktop clients that send no `Origin` header are
unaffected.

### When auth is on

Every `POST /mcp` must carry `Authorization: Bearer <token>`, otherwise the server answers `401`. The
`Origin`/`Host` checks are skipped, because the token is the boundary. This is what lets tunnels and
LAN clients work. To turn it on:

1. In the **BeamMCP** panel, tick **Require auth (token)**. A token is generated the first time.
2. Click **Copy token** to put the full token on the clipboard. The panel only shows its first eight
   characters. The token is also stored as `authToken` in `settings/beammcp.json`.
3. Add the header to your client (examples below).

Auth applies immediately, without a restart, so a client that is already connected starts getting
`401` until you add the header. **Regenerate token** (with a confirmation click) invalidates the old
token; update every client afterwards.

The server does not implement an OAuth sign-in flow. If a client offers OAuth or "authenticate in
browser" for this server, skip that and configure the static header instead.

See [security.md](security.md) for the full threat model.

## Claude Code

Without auth:

```sh
claude mcp add beammcp --transport http http://127.0.0.1:23512/mcp
```

With auth:

```sh
claude mcp add beammcp --transport http http://127.0.0.1:23512/mcp --header "Authorization: Bearer <token>"
```

By default `claude mcp add` stores the server for the current project only. Add `--scope user` to
make it available in every project. To change an existing entry, run `claude mcp remove beammcp`
and add it again, or edit the server's block in `~/.claude.json` directly:

```json
"beammcp": {
  "type": "http",
  "url": "http://127.0.0.1:23512/mcp",
  "headers": { "Authorization": "Bearer <token>" }
}
```

Check the connection with `/mcp` inside a session, or `claude mcp list` from a shell.

## OpenAI Codex CLI

Codex reads MCP servers from `~/.codex/config.toml` (on Windows,
`%USERPROFILE%\.codex\config.toml`). Without auth:

```toml
[mcp_servers.beammcp]
url = "http://127.0.0.1:23512/mcp"
```

With auth, keep the token in an environment variable and let Codex add the bearer header:

```toml
[mcp_servers.beammcp]
url = "http://127.0.0.1:23512/mcp"
bearer_token_env_var = "BEAMMCP_TOKEN"
```

Set `BEAMMCP_TOKEN` to the token (without the `Bearer ` prefix) in the environment Codex starts
from. `codex mcp add beammcp --url http://127.0.0.1:23512/mcp` creates the unauthenticated entry
from the command line.

## Cursor, Claude Desktop and other clients

Most clients that support Streamable HTTP take a URL and an optional map of headers.

**Cursor** (`~/.cursor/mcp.json`, or `.cursor/mcp.json` in a project):

```json
{
  "mcpServers": {
    "beammcp": {
      "url": "http://127.0.0.1:23512/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

Leave out `headers` when auth is off.

**Claude Desktop** configures local servers as stdio commands. The usual way to reach an HTTP server
from it is the `mcp-remote` bridge (needs Node.js), which also sends no `Origin` header, so the
loopback checks pass. In `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "beammcp": {
      "command": "npx",
      "args": ["-y", "mcp-remote", "http://127.0.0.1:23512/mcp"]
    }
  }
}
```

With auth on, pass the header to the bridge (see the `mcp-remote` documentation for its `--header`
option) and keep the token out of the file where you can.

**Anything else:** point the client at `http://127.0.0.1:23512/mcp` with transport "HTTP" or
"Streamable HTTP", and add `Authorization: Bearer <token>` as a custom header if auth is on. Check
your client's documentation for the exact key names. If the client runs in a browser or Electron
renderer and sends a non-loopback `Origin`, requests are rejected with `403` while auth is off;
turning auth on removes that check.

## ChatGPT developer mode

ChatGPT's MCP connectors are called from OpenAI's servers, not from your PC, so they cannot reach
`127.0.0.1`. You need an HTTPS path from OpenAI to the game, and **auth must be on**: the tools
include arbitrary Lua and JavaScript execution, so an unauthenticated tunnel gives whoever finds it
code execution on your machine.

One more constraint shapes the setup: ChatGPT's connector authentication options are OAuth or no
authentication. It cannot send a static bearer token itself. The `Authorization` header therefore
has to be added by something you run locally, between the tunnel and the game.

### Preconditions

1. Start BeamNG.drive with the mod installed and confirm the BeamMCP panel shows the server
   running on `127.0.0.1:23512`.
2. Turn on **Require auth (token)** and copy the token.
3. Keep the display awake. Display sleep can freeze the game process, and the server only answers
   while the game's update loop runs.
4. Run the [smoke test](#smoke-test) with the token to confirm the server answers locally.

### Option A: OpenAI Secure MCP Tunnel (recommended)

Secure MCP Tunnel runs OpenAI's `tunnel-client` on your machine. It opens an outbound connection to
OpenAI, pulls queued MCP requests, and forwards them to a local URL. No inbound port is opened and
nothing is published on the internet.

1. In the OpenAI Platform tunnel settings, create a tunnel (or pick an existing one) associated with
   your ChatGPT workspace, and get a runtime key for it.
2. Install `tunnel-client` and create a profile whose MCP server URL is
   `http://127.0.0.1:23512/mcp`. Use `tunnel-client help quickstart` and
   `tunnel-client doctor --profile <name> --explain` to check it.
3. Configure the profile to add `Authorization: Bearer <token>` to the requests it forwards to the
   MCP server, and to discovery requests. Read the token from an environment variable rather than
   writing it into the profile file. See the `tunnel-client` documentation for the header options in
   your version.
4. Run `tunnel-client run --profile <name>` and leave it running while you use ChatGPT.
5. In ChatGPT, enable developer mode, add a custom MCP server (app/plugin), and choose **Tunnel** as
   the connection type with the tunnel from step 1.
6. Set the connector's authentication to **No authentication**. The BeamNG-MCP token travels only
   on the local hop from `tunnel-client` to the game; the tunnel runtime key authenticates
   `tunnel-client` to OpenAI and does not belong in the ChatGPT form either.

If BeamNG-MCP logs `401`s while the tunnel is up, the header is not reaching the local request.
Check the profile's header configuration, not the ChatGPT form. If your `tunnel-client` version
refuses a plain `http://127.0.0.1` upstream, put a local HTTPS reverse proxy in front of the game.

`tunnel-client` may run its own local health endpoint; if it uses port `8080`, it collides with
BeamNG's `-cefdev` DevTools port (see [cef-cdp.md](cef-cdp.md)). Move one of them if you need both.

### Option B: a public HTTPS tunnel

Tools such as ngrok or Cloudflare Tunnel can give the game a temporary public HTTPS URL, for example
`ngrok http 23512` or `cloudflared tunnel --url http://127.0.0.1:23512`, and ChatGPT would then use
`https://<tunnel-host>/mcp`.

On its own this does not work, and should not:

- With auth on, ChatGPT cannot send the token, so every request gets `401`.
- With auth off, the server rejects the tunnel's `Host` header with `403`. Working around that
  would put an unauthenticated code-execution endpoint on the public internet.

To use a public tunnel safely you need both a local reverse proxy that adds the
`Authorization: Bearer <token>` header before forwarding to `127.0.0.1:23512`, and access control
at the tunnel edge (for example an identity-aware access policy on the tunnel) so that the public
URL is not open to anyone who learns it. Keep such a tunnel temporary and stop it when you are done.
Option A is simpler and safer.

### Creating the connector

Suggested values:

```text
Name: BeamNG.drive MCP
Description: Reads and controls a local BeamNG.drive session: live telemetry, screenshots,
  vehicle setup, UI/CEF inspection and mod verification. Use only when the user asks to
  inspect or control their BeamNG session.
```

After creation, ChatGPT lists the tools the server advertises. Start a new chat, enable the
connector from the developer-mode tools menu, and try a read-only request such as "Use BeamNG.drive
MCP to list the current vehicles." After updating the mod, refresh the connector in ChatGPT's
settings so it picks up changed tools.

ChatGPT's menu names change from time to time. OpenAI's current instructions:

- Developer mode: <https://developers.openai.com/api/docs/guides/developer-mode>
- Connecting an MCP server to ChatGPT: <https://developers.openai.com/apps-sdk/deploy/connect-chatgpt>
- Secure MCP Tunnel: <https://developers.openai.com/api/docs/guides/secure-mcp-tunnels>

`set_sim_speed` refuses to run in a BeamMP (multiplayer) session, and the opt-in panel toggle
**Allow sim-time control** gates it anyway; leave that toggle off while connected to multiplayer.

## Several game instances or LAN access

By default the server binds `127.0.0.1` and is reachable only from the same machine. To drive one or
more game instances from a client on another machine:

1. On each game machine, open the BeamMCP panel and set:
   - **bind** to `0.0.0.0` (all interfaces) or that machine's LAN IP, then **Apply**,
   - **port** if you want something other than `23512`,
   - **Require auth (token)** on, and copy that machine's token.
2. Restart the game. Bind and port changes apply on the next start.
3. Allow the port through that machine's firewall for your LAN only.
4. Add each instance to your client as a separate server, each with its own address and token:

```sh
claude mcp add beammcp-pc1 --transport http http://192.168.1.20:23512/mcp --header "Authorization: Bearer <token-pc1>"
claude mcp add beammcp-pc2 --transport http http://192.168.1.21:23512/mcp --header "Authorization: Bearer <token-pc2>"
```

A non-loopback bind is **fail-closed**: if auth is off, the server ignores the bind setting, listens
on `127.0.0.1` instead, logs a warning, and the panel shows a hint. The endpoint can never reach the
network without a token.

Traffic on the LAN is plain HTTP, so the token is visible to anyone who can sniff that network. Use
this on networks you trust. Only IPv4 addresses are accepted for the bind setting.

## Smoke test

`tools/list` works without an `initialize` handshake, so a single request shows whether the server
is up and whether your auth header is right.

Git Bash, Linux or macOS:

```sh
curl -s http://127.0.0.1:23512/mcp \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $BEAMMCP_TOKEN" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

Windows PowerShell:

```powershell
$headers = @{ Authorization = "Bearer $env:BEAMMCP_TOKEN" }   # omit -Headers when auth is off
$body = '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
$r = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:23512/mcp" `
  -ContentType "application/json" -Headers $headers -Body $body
$r.result.tools.name
```

(In Windows PowerShell, `curl` is an alias for `Invoke-WebRequest`; call `curl.exe` if you want the
real curl.)

A healthy server returns a JSON-RPC result with a `tools` array. Add `-i` to the curl command to see
the HTTP status when something fails.

## Troubleshooting

| Symptom | Likely cause and fix |
|---------|----------------------|
| Connection refused | The game isn't running, the mod isn't enabled, or the port differs. Check the BeamMCP panel in the main menu for `running` and the `host:port`. If you used `localhost`, switch to `127.0.0.1`. |
| Connects, then times out or hangs | The game process is frozen, most often because the display went to sleep. Keep the display awake during agent sessions. |
| `401 Unauthorized` | Auth is on and the header is missing or wrong. Re-copy the token from the panel (it may have been regenerated) and check the exact form `Authorization: Bearer <token>`. For tunnels, the header must be added on the local hop. |
| `403 Forbidden` | Auth is off and the request carried a non-loopback `Origin` or `Host`: a browser-based client, a tunnel, or a LAN address. Turn auth on (required for those cases anyway). |
| `404` or `405` | Wrong path or method. The endpoint is exactly `/mcp`, `POST` only. A client that needs a `GET` SSE stream or a separate `/sse` endpoint is not compatible. |
| Client starts an OAuth or browser sign-in | It received a `401` and fell back to OAuth discovery. The server has no OAuth flow; configure the static bearer header instead. |
| LAN client can't connect | Auth is off (the bind silently fell back to loopback), the game wasn't restarted after changing bind, or a firewall blocks the port. |
| New or changed tools don't appear | Clients cache the tool list for the session. Reconnect the server (`/mcp` in Claude Code, restart Codex, refresh the ChatGPT connector) after updating or reloading the mod. |
| Port change didn't take effect | Port and bind changes apply on the next game start. The panel shows the pending value until then. |
