# luamemo MCP server

A pure-Lua [Model Context Protocol](https://modelcontextprotocol.io/) stdio
server that bridges MCP clients (Claude Desktop, Cursor, Continue.dev,
Copilot Agent Mode, …) to a running `luamemo` HTTP API.

Once installed, your AI assistant can call eleven tools:

| Tool | Purpose |
|---|---|
| `memory_write`   | Store a memory (decision, fact, plan, snippet, …). Optional `importance` (0..10) and `decay_rate` (0..1/day) control search ranking. |
| `memory_search`  | Hybrid vector + full-text search, weighted by importance × time-decay. `ignore_decay=true` disables weighting (debug). |
| `memory_recent`  | List most recent memories in a scope. |
| `memory_get`     | Fetch a single memory by ID. |
| `memory_update`  | Update title / body / tags / metadata / importance / decay_rate. |
| `memory_delete`  | Permanently delete a memory. |
| `memory_promote` | Roll a hot session scope into a long-term scope (session-continuity). |
| `secret_list`    | List stored secrets — names and metadata only, **no values**. |
| `secret_store`   | Encrypt and store an API key or token. **Use from terminal only** — never call this from the chat window. |
| `secret_delete`  | Permanently delete a stored secret. |
| `secret_execute` | Make an HTTP request with `{secret}` substituted server-side; only the response body is returned to the agent. |

These survive chat-session crashes, IDE restarts, device switches, and the
VS Code "Invalid string length" overflow on very long sessions.

---

## Requirements

- **Lua 5.1+** or **LuaJIT** (whichever is on your `$PATH` as `lua`)
- **lua-cjson** (`luarocks install lua-cjson`)
- **curl** — preinstalled on macOS, Linux, modern Windows
- A reachable `luamemo` HTTP API (see the project root README)

> ### HTTP transport note
> The MCP server shells out to `curl` for its HTTP calls to the
> `luamemo` API. `curl` is preinstalled on macOS, Linux, and modern
> Windows. The library itself uses `luamemo.http` (LuaSocket-backed in
> plain Lua) for embedder/reranker calls, but the MCP server keeps the
> separate `curl` path to avoid requiring `luasocket` as a hard dependency
> for users who only want the MCP server.

---

## Install

```bash
git clone https://github.com/kaio326/lapis-memory.git ~/luamemo
chmod +x ~/luamemo/mcp/server.lua
luarocks install lua-cjson    # if not already installed
```

Verify:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  | MEMO_URL=http://localhost:8080/api/memory lua ~/luamemo/mcp/server.lua
```

You should get a one-line JSON response containing `serverInfo` and
`capabilities`.

---

## Configure your client

### Claude Desktop

Edit `claude_desktop_config.json`:

- macOS:  `~/Library/Application Support/Claude/claude_desktop_config.json`
- Linux:  `~/.config/Claude/claude_desktop_config.json`
- Windows: `%APPDATA%\Claude\claude_desktop_config.json`

```json
{
  "mcpServers": {
    "luamemo": {
      "command": "lua",
      "args": ["/absolute/path/to/luamemo/mcp/server.lua"],
      "env": {
        "MEMO_URL":   "https://app.example.com/api/memory",
        "MEMO_TOKEN": "your-bearer-token",
        "MEMO_SCOPE": "global"
      }
    }
  }
}
```

Restart Claude Desktop. The eleven memory and secret tools will appear in the tool list.

### Cursor

Cursor reads MCP servers from `~/.cursor/mcp.json` (same schema as Claude
Desktop). Use the identical config.

### Continue.dev

In `~/.continue/config.yaml`:

```yaml
experimental:
  modelContextProtocolServers:
    - transport:
        type: stdio
        command: lua
        args: ["/absolute/path/to/luamemo/mcp/server.lua"]
        env:
          MEMO_URL:   https://app.example.com/api/memory
          MEMO_TOKEN: your-bearer-token
          MEMO_SCOPE: global
```

### Copilot Agent Mode (VS Code)

Add to `.vscode/mcp.json` in your workspace:

```json
{
  "servers": {
    "luamemo": {
      "type": "stdio",
      "command": "lua",
      "args": ["/absolute/path/to/luamemo/mcp/server.lua"],
      "env": {
        "MEMO_URL":   "https://app.example.com/api/memory",
        "MEMO_TOKEN": "your-bearer-token",
        "MEMO_SCOPE": "repo:my-project"
      }
    }
  }
}
```

---

## Environment variables

| Variable | Required | Purpose |
|---|---|---|
| `MEMO_URL`   | yes | Base URL of the luamemo HTTP API |
| `MEMO_TOKEN` | no  | Bearer token sent as `Authorization: Bearer <token>` |
| `MEMO_SCOPE` | no  | Default scope used when a tool call omits `scope` |
| `MEMO_DEBUG` | no  | Set to `1` to log raw JSON-RPC frames to stderr |

`MEMO_SCOPE` is the simplest way to point one MCP server instance at one
project — set it to `repo:my-project` and every write/search defaults to
that bucket without the model having to remember.

---

## Per-project scopes

Run multiple MCP server instances pointing at the same `luamemo`
backend, each scoped to a different project:

```jsonc
{
  "mcpServers": {
    "memory-projectA": {
      "command": "lua",
      "args": ["/path/to/server.lua"],
      "env": { "MEMO_URL": "...", "MEMO_SCOPE": "repo:projectA" }
    },
    "memory-acme": {
      "command": "lua",
      "args": ["/path/to/server.lua"],
      "env": { "MEMO_URL": "...", "MEMO_SCOPE": "repo:acme" }
    }
  }
}
```

The model sees them as two independent tool sets.

---

## Troubleshooting

**"MEMO_URL env var is required"** — The `env` block in your client config
isn't being applied. Check the client's MCP logs (Claude Desktop has a
`Developer → MCP` panel).

**"empty response from server"** — Your `luamemo` API isn't reachable.
Test with `curl $MEMO_URL/recent` first.

**"invalid JSON response"** — The API returned HTML or plain text (likely
401/403/500). Run with `MEMO_DEBUG=1` and inspect stderr for the raw URL,
then hit it with `curl` directly.

**Tools don't appear in Claude Desktop** — Confirm `lua` is on the PATH
seen by Claude (it inherits the *login shell* PATH on macOS, not your
terminal's). Use an absolute path like `/usr/local/bin/lua` if needed.

---

## See also

- Project root: [`../README.md`](../README.md)
- MCP spec: <https://spec.modelcontextprotocol.io/>
