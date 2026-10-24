#!/usr/bin/env python3
"""Minimal MCP stdio client to smoke-test chrome-devtools-mcp against BeamNG CEF.

Spawns `npx -y chrome-devtools-mcp@latest --browserUrl http://localhost:8080`,
performs the MCP handshake, and drives a scripted sequence of tool calls,
dumping every response. Saves the CEF screenshot to scripts/cdp/cef_shot.png.

Stdlib only. Run while BeamNG is launched with -cefdev (port 8080 open).
"""
import base64
import json
import os
import platform
import re
import shlex
import subprocess
import time

CDP_URL = "http://localhost:8080"
HERE = os.path.dirname(os.path.abspath(__file__))
SHOT_PATH = os.path.join(HERE, "cef_shot.png")
STDERR_LOG = os.path.join(HERE, "probe.stderr.log")
PROTOCOL_VERSION = "2025-06-18"
MAIN_UI_NEEDLE = "main/index.html"


class McpStdio:
    """A tiny synchronous MCP client over a child process's stdio."""

    def __init__(self):
        cmd = "npx -y chrome-devtools-mcp@latest --browserUrl %s" % CDP_URL
        self._errf = open(STDERR_LOG, "w", encoding="utf-8")
        if platform.system() == "Windows":
            self.proc = subprocess.Popen(
                cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=self._errf, text=True, bufsize=1, shell=True,
            )
        else:
            self.proc = subprocess.Popen(
                shlex.split(cmd), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=self._errf, text=True, bufsize=1,
            )
        self._id = 0

    def _send(self, method, params=None, notification=False):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            msg["params"] = params
        if not notification:
            self._id += 1
            msg["id"] = self._id
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        return msg.get("id")

    def _read(self, want_id, timeout=120):
        deadline = time.time() + timeout
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("server closed stdout; see %s" % STDERR_LOG)
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue  # non-protocol line on stdout
            if msg.get("id") == want_id:
                return msg
        raise TimeoutError("no response for id=%s in %ss" % (want_id, timeout))

    def request(self, method, params=None, timeout=120):
        return self._read(self._send(method, params), timeout)

    def notify(self, method, params=None):
        self._send(method, params, notification=True)

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()
        self._errf.close()


def dump(label, obj):
    print("\n=== %s ===" % label)
    text = json.dumps(obj, indent=2)
    print(text if len(text) <= 4000 else text[:4000] + "\n...(truncated)")


def find_tool(tools, *needles):
    """First tool whose name contains all needles (case-insensitive)."""
    for t in tools:
        low = t.get("name", "").lower()
        if all(n in low for n in needles):
            return t["name"]
    return None


def result_text(resp):
    """Concatenate text content blocks of a tools/call result."""
    blocks = resp.get("result", {}).get("content", []) or []
    return "\n".join(c.get("text", "") for c in blocks if c.get("type") == "text")


def is_error_response(resp):
    """True if an MCP response is an error (top-level JSON-RPC error OR result.isError)."""
    if resp.get("error") is not None:
        return True
    return bool(resp.get("result", {}).get("isError"))


def save_image(resp, path):
    """Write the first image content block (base64) to path; return True if saved."""
    for c in resp.get("result", {}).get("content", []) or []:
        if c.get("type") == "image" and c.get("data"):
            with open(path, "wb") as f:
                f.write(base64.b64decode(c["data"]))
            return True
    return False


def find_page_id(pages_text, needle):
    """Return the pageId integer for the first line containing `needle`.

    list_pages format (chrome-devtools-mcp@1.3.0):
        <id>: <title> (<url>) [selected]
    Example:
        2: BeamNG Main UI (local://local/ui/entrypoints/main/index.html#/play) [selected]
    The pageId passed to select_page must be a JSON number (int), matching
    the leading integer on each list_pages line.
    Returns None if no matching line is found.
    """
    for line in pages_text.splitlines():
        if needle.lower() in line.lower():
            m = re.match(r"^(\d+):", line.strip())
            if m:
                return int(m.group(1))
    return None


def handshake(cli):
    init = cli.request("initialize", {
        "protocolVersion": PROTOCOL_VERSION,
        "capabilities": {},
        "clientInfo": {"name": "beammcp-cdp-probe", "version": "0.1"},
    })
    dump("initialize", init)
    cli.notify("notifications/initialized")
    tl = cli.request("tools/list")
    tools = tl.get("result", {}).get("tools", []) or []
    print("\n=== tools (%d) ===" % len(tools))
    for t in tools:
        req = (t.get("inputSchema", {}) or {}).get("required", [])
        props = list(((t.get("inputSchema", {}) or {}).get("properties", {}) or {}).keys())
        print(" - %-28s required=%s props=%s" % (t.get("name"), req, props))
    return tools


def main():
    cli = McpStdio()
    try:
        tools = handshake(cli)

        # --- Step 1: discover pages and select the BeamNG Main UI page ---
        list_pages_tool = find_tool(tools, "list", "page")
        select_page_tool = find_tool(tools, "select", "page")
        print("\nResolved tools: list_pages=%r  select_page=%r" % (list_pages_tool, select_page_tool))

        pages_resp = cli.request("tools/call", {"name": list_pages_tool, "arguments": {}})
        dump("list_pages", pages_resp)
        pages_text = result_text(pages_resp)
        print("\n=== list_pages text ===\n%s" % pages_text)

        page_id = find_page_id(pages_text, MAIN_UI_NEEDLE)
        if page_id is None:
            raise RuntimeError("Could not find Main UI page (needle=%r) in list_pages output" % MAIN_UI_NEEDLE)
        print("\n>>> Resolved Main UI pageId: %r" % page_id)

        sel_resp = cli.request("tools/call", {"name": select_page_tool, "arguments": {"pageId": page_id}})
        dump("select_page", sel_resp)
        is_error = is_error_response(sel_resp)
        sel_text = result_text(sel_resp)
        print("\n=== CHECKPOINT (page selection) ===")
        print("  selectedPageId : %s" % page_id)
        print("  isError        : %s" % is_error)
        print("  message        : %s" % sel_text.strip())
        if is_error:
            err_detail = sel_resp.get("error") if sel_resp.get("error") is not None else sel_text
            print("  RESULT         : FAIL — select_page returned an error: %s" % err_detail)
        else:
            print("  RESULT         : PASS — existing CEF page selected without error")

        # --- Step 2a: DOM read via evaluate_script ---
        eval_tool = find_tool(tools, "evaluate")
        if eval_tool:
            ev = cli.request("tools/call", {"name": eval_tool, "arguments": {
                "function": "() => ({ title: document.title, hash: location.hash, url: location.href, nodes: document.querySelectorAll('*').length })",
            }})
            dump("evaluate_script", ev)
            if is_error_response(ev):
                print("[WARN] evaluate_script returned an error")
        else:
            print("[WARN] evaluate_script tool not found — skipping DOM read")

        # --- Step 2b: CEF screenshot ---
        shot_tool = find_tool(tools, "screenshot")
        if shot_tool:
            shot = cli.request("tools/call", {"name": shot_tool, "arguments": {"filePath": SHOT_PATH}})
            dump("take_screenshot", shot)
            if is_error_response(shot):
                print("[WARN] take_screenshot returned an error")
            # Prefer deterministic filePath path; fall back to inline base64 if file absent/empty
            if os.path.isfile(SHOT_PATH) and os.path.getsize(SHOT_PATH) > 0:
                print("[CHECKPOINT] screenshot saved -> %s (%d bytes) [filePath write]" % (
                    SHOT_PATH, os.path.getsize(SHOT_PATH)))
            elif save_image(shot, SHOT_PATH):
                print("[CHECKPOINT] screenshot saved -> %s (%d bytes) [save_image fallback]" % (
                    SHOT_PATH, os.path.getsize(SHOT_PATH)))
            else:
                print("[CHECKPOINT] screenshot: file not produced and no inline image block found")
        else:
            print("[WARN] take_screenshot tool not found — skipping screenshot")

        # --- Step 2c: CEF console messages ---
        console_tool = find_tool(tools, "list", "console")
        if console_tool:
            cons = cli.request("tools/call", {"name": console_tool, "arguments": {}})
            dump("list_console_messages", cons)
        else:
            print("[WARN] list_console_messages tool not found — skipping console read")

        print("\n[DONE] probe sequence complete")

    finally:
        cli.close()


if __name__ == "__main__":
    main()
