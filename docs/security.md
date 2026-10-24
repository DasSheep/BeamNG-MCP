# Security model and hardening guide

BeamNG-MCP gives an MCP client control of a running game. Some of its tools execute arbitrary code. This page
explains what a connected client can do, who can connect under each configuration, and how to lock it down.

To report a vulnerability, see [SECURITY.md](../SECURITY.md).

## The short version

- **Anyone who can send requests to the server can run code inside BeamNG.** That is the purpose of `lua_eval`,
  `vehicle_lua_eval`, and `cef_eval`, not a bug.
- **Default:** the server listens on `127.0.0.1` only, with no authentication, and rejects browser requests that
  carry a non-loopback `Origin` or `Host`. Every program running on your computer can use it.
- **Bearer-token auth is opt-in.** Turn it on before you expose the server through a tunnel or on your network.
  Binding to a network address is refused unless auth is on.

## What a connected client can do

### Code execution is by design

| Tool | Runs | Where |
|------|------|-------|
| `lua_eval` | any Lua chunk | the game-engine (GE) Lua VM, on the main thread |
| `vehicle_lua_eval` | any Lua chunk | a vehicle's Lua VM |
| `cef_eval` | any JavaScript | a BeamNG UI page, through Chromium's DevTools protocol (needs `-cefdev`) |

The GE VM is where BeamNG-MCP itself runs. Code sent to `lua_eval` has the same access as the server and every
other mod. It can change any game state, call any engine API, read or rewrite the server's settings (including the
auth token), freeze the game with an infinite loop, or crash it. BeamNG's UI can issue GE Lua commands, so treat
`cef_eval` as equivalent to `lua_eval`.

Many other tools also change things (spawn and delete vehicles, load levels, apply damage, change parts, hide
the UI). Read tools expose game state, screenshots of the game view, and console logs. The game log
(`beamng.log`) can contain local file paths, including your OS user name.

### What BeamNG's Lua sandbox limits

BeamNG restricts what game Lua can reach on the host. Observed on BeamNG.drive 0.39:

- File access goes through the game's virtual filesystem. `io.open` and `io.popen` are redirected into it,
  `FS:mount` refuses OS directories, and absolute OS paths are rejected.
- `os.execute` does nothing, and `io.popen` cannot start a command.
- LuaJIT FFI rejects function declarations, so native functions cannot be called through `ffi.cdef`.

Within those limits, evaluated code **can**:

- read game files, and read, write, and delete files in the BeamNG user folder: settings (including
  `settings/beammcp.json` with the auth token), saves, and installed mods. A file written into the mods folder can
  run on the next game start, so a change can outlast the session;
- reach any OS directory that has been linked into the user folder with a junction or symlink (for example the
  optional Steam screenshot junction used by `screenshot_native`);
- open network connections from your machine with the bundled `luasocket` (TCP and UDP, to your LAN or the
  internet).

This sandbox belongs to BeamNG, not to BeamNG-MCP. It may change between game versions, and nothing here should be
read as a guarantee that it cannot be escaped. **Plan as if a connected client can do anything your user account
can do.**

### AI agents

An AI agent with these tools is an agent with code execution. Content the agent reads (a web page, a file, a mod's
text) can try to steer it. Use your MCP client's per-tool approval prompts for the eval tools when the agent works
with untrusted input.

## Who can connect

### Default: loopback, no auth

Out of the box the server binds `127.0.0.1:23512` and does not ask for credentials. Other machines cannot reach a
loopback socket, but **every process and every user on your computer can**. If you share the machine, or run
software you don't trust, turn auth on.

With auth off, each `POST /mcp` must also pass two header checks, which block hostile web pages:

- **`Origin`**: if present, its host must be `127.0.0.1` or `localhost`. Otherwise the server answers `403`. This
  stops a website you visit from sending requests to the server in the background.
- **`Host`**: if present, it must be `127.0.0.1` or `localhost` (any port). Otherwise `403`. This stops DNS
  rebinding, where an attacker's domain is re-pointed at `127.0.0.1` so its page looks same-origin to the browser.
  The browser still sends the attacker's domain in `Host`.

Requests with neither header (typical for command-line and desktop MCP clients) are allowed. These checks only
stop browsers. Any non-browser program can send whatever headers it likes. They also allow a page served from
`localhost` on **any** port, so a local web app you run counts as trusted.

### Bearer-token auth (opt-in)

When auth is on, every `POST /mcp` must carry `Authorization: Bearer <token>`. A missing or wrong token gets
`401` with `WWW-Authenticate: Bearer`. The check runs on the request headers before the body is read, so an
unauthenticated client cannot make the server buffer its payload.

**Turning it on**

1. Open the **BeamMCP** panel in game. It shows in the main and pause menus.
2. Tick **Require auth (token)**. If no token exists yet, one is generated: two engine-generated UUIDs with the
   dashes removed, 64 hex characters.
3. Click **Copy token**. The full token goes to the OS clipboard. The panel only ever displays the first eight
   characters.
4. Add the header to your MCP client (below).

**Changing it**

- **Regenerate token** asks for a second click (**Confirm regenerate**). The old token stops working at once.
- The token is stored in plain text as `authToken` in `settings/beammcp.json` in the BeamNG user folder (by
  default `%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\settings\beammcp.json` on Windows). Turning auth off keeps
  it; turning auth back on reuses it.
- Auth changes apply immediately, without a restart.

**Client configuration.** For Claude Code:

```
claude mcp add --transport http beammcp http://127.0.0.1:23512/mcp --header "Authorization: Bearer <token>"
```

or add a `headers` entry to the server's block in your Claude Code configuration:

```json
"headers": { "Authorization": "Bearer <token>" }
```

See [clients.md](clients.md) for other clients. The token sits in plain text in client config files too. Keep it
out of project files you commit or share (for example a checked-in `.mcp.json`).

**The 401 footgun.** Enabling auth, or regenerating the token, immediately locks out every client that doesn't
send the current token, including your own. Update the client's header right away and reconnect.

**When auth is on, the `Origin` and `Host` checks are switched off.** The token is the boundary instead. This is
deliberate: a tunnel delivers requests with its own public hostname in `Host` and `Origin`, and the loopback checks
would reject them. A malicious web page still cannot authenticate. It does not know the token, and a browser will
not attach an `Authorization` header to a cross-origin request without a CORS preflight, which the server refuses.

The comparison does not stop at the first mismatching byte, so response timing does not reveal how much of a
guessed token was correct. (It can reveal the token's length, which is fixed and public anyway.)

### Network (LAN) access

To drive the game from another machine, set the panel's **bind** field to `0.0.0.0` (all interfaces) or one of
your machine's IPv4 addresses, and restart (or reload Lua). The bind address is stored as `bindHost`.

**Network binding is fail-closed.** When the extension loads, a non-loopback bind is used only if **Require auth**
is also on. Otherwise the server binds `127.0.0.1` instead, logs a warning, and the panel shows a hint. An
unauthenticated server is never put on the network by this setting.

Before you use a network bind:

- **The connection is plain HTTP.** The token and all traffic cross the network unencrypted, so anyone who can
  watch the network can read the token. Use a network bind only on a network you trust.
- **Turning auth off does not unbind.** The bind address is applied at load time, but auth applies live. If you
  turn auth off while the server is listening on a network address, it stays on that address, without
  authentication, until the next reload. The `Host` check does not protect you here, because a non-browser
  client can send `Host: 127.0.0.1`. Set the bind back to `127.0.0.1` and reload as soon as you turn auth off, or
  close the game.
- Check your OS firewall. Opening the port to the LAN is your decision.

### Tunnels (ChatGPT and other remote connectors)

Hosted clients such as ChatGPT cannot reach `127.0.0.1`. They need a tunnel: a program on your machine that
forwards requests from the internet to the local endpoint. The tunnel connects from loopback, so **the server
cannot tell tunnelled requests from local ones**, and the loopback bind gives no protection.

**Turn auth on before you start a tunnel.** Configure the tunnel (or the hosted client) to add the
`Authorization: Bearer <token>` header to the requests it forwards to `/mcp`. Without auth, anyone who learns the
tunnel URL can run code on your machine. See [clients.md](clients.md) for working setups.

### OAuth discovery metadata

Some MCP clients look for OAuth metadata before they connect. To keep their discovery step from failing, the
server answers `GET /.well-known/oauth-protected-resource` (also with a `/mcp` suffix) and
`GET /.well-known/oauth-authorization-server` with static JSON, with or without auth. These responses contain no
secrets. The server does **not** implement OAuth: the endpoints that metadata lists are not served, and the only
credential the server accepts is the static bearer token.

### The CEF DevTools port (`-cefdev`)

`cef_eval` needs BeamNG started with `-cefdev`. That option opens Chromium's remote-debugging endpoint (port 8080
by default). It is part of the game, not BeamNG-MCP, and **BeamNG-MCP's token does not protect it**: any local
program that can reach it can control the UI directly. Launch with `-cefdev` only when you need `cef_eval`. See
[cef-cdp.md](cef-cdp.md).

## Other gates

These protect the game session. They are not security boundaries, because a client with `lua_eval` can do the same
things directly.

- **`set_sim_speed` is off by default.** It works only after **Allow sim-time control** is ticked in the panel.
- **Multiplayer refusals.** `set_sim_speed` and `load_level` refuse to run when a BeamMP session is detected,
  because changing sim time or the level desyncs the session. Detection is best-effort; if BeamMP is installed but
  its state can't be read, these tools refuse.

## Checklist

- [ ] Local use on a machine only you use: the defaults are fine.
- [ ] Shared machine or untrusted local software: turn on **Require auth**.
- [ ] Any tunnel or hosted connector: turn on **Require auth** first, and make sure the token reaches `/mcp` in the
      `Authorization` header.
- [ ] Network bind: auth on, trusted network only, firewall checked. Keep in mind the traffic is unencrypted.
- [ ] After turning auth off, set the bind back to `127.0.0.1` and reload.
- [ ] Keep the token out of shared or committed config files. Regenerate it if it leaks.
- [ ] Use `-cefdev` only when you need `cef_eval`.
- [ ] Have your MCP client ask before running the eval tools when an agent handles untrusted content.
- [ ] Close the game when you're done. The server runs whenever the mod is loaded.
