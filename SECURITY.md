# Security policy

## Supported versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | Yes       |
| older   | No        |

Fixes are made on the latest 0.1.x release.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report it privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**
(or go to <https://github.com/DasSheep/BeamNG-MCP/security/advisories/new>). Only the maintainer can see the report.

Please include:

- the BeamNG-MCP version, BeamNG.drive version, and OS;
- your settings: bind address, whether **Require auth** is on, and whether a tunnel or `-cefdev` is involved;
- steps to reproduce, such as the exact HTTP requests (`curl` commands are ideal);
- what you expected and what happened;
- the impact as you see it.

This is a hobby project, maintained on a best-effort basis by one person, so there are no guaranteed response or
fix times. You will get an acknowledgement once the maintainer has seen the report. Disclosure will be coordinated
with you, and you will be credited in the advisory unless you'd rather not be named.

## Scope

BeamNG-MCP exposes tools that **execute arbitrary code by design**: `lua_eval`, `vehicle_lua_eval`, and
`cef_eval`. A client that is allowed to connect being able to run code in the game is the intended behavior, and is
not a vulnerability. The same applies to the other tools changing game state.

In scope, for example:

- getting requests accepted without a valid token while **Require auth** is on;
- getting the server to listen on a non-loopback address while auth is off;
- getting past the `Origin` / `Host` checks from a web browser with auth off (cross-site requests, DNS rebinding;
  pages served from `localhost` itself are trusted by design);
- leaking the auth token to someone who cannot already connect;
- crashing or hanging the game, or exhausting memory, with requests that are rejected before authentication;
- `cef_eval` connecting to a CEF page that isn't BeamNG's (for example a Steam page sharing the debug port).

Out of scope:

- anything that requires already being able to call the tools (any eval tool can do it anyway);
- escaping BeamNG's own Lua sandbox (please report that to BeamNG);
- the CEF debugging port that `-cefdev` opens, which belongs to the game;
- problems that require an unauthenticated server on a network you exposed it to yourself, for example through a
  tunnel with auth off.

The security model and hardening guidance are in [docs/security.md](docs/security.md).
