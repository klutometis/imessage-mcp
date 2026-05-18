# imessage-mcp

A native Swift stdio MCP server for iMessage on macOS.

Forked from [imessage-gemini](https://github.com/klutometis/imessage-gemini)'s
MessageSender / DatabaseMonitor / MessageDecoder; drops the Vapor/SendBlue
HTTP shim and Gemini integration in favor of a focused stdio MCP
interface using the official [Swift MCP SDK][swift-sdk].

[swift-sdk]: https://github.com/modelcontextprotocol/swift-sdk

## Status (2026-05-18)

- ✅ `send_imessage(recipient, message)` — works end-to-end.
- ⏳ `search_imessages`, `list_imessage_chats`, `get_imessage_attachment` —
  designed (see `~/prg/mcp-gateway/plans/mcp-over-wss.md`), not yet
  implemented. `DatabaseReader` skeleton is in place.

## Why Swift (instead of Node / Python)

- **Madrid TypedStream decoder** is the only library that correctly
  reads `message.attributedBody` (the rich-text format Messages.app
  uses for edits, replies, formatting, tapbacks). Node and Python
  MCPs use `substr after "NSString"` which mangles unicode.
- **Reuses hardened code from `imessage-gemini`** — modern AppleScript
  syntax, retry, rate limiting, attachment send.
- **Native `actor` model** in Swift 6 — `MessageSender` is an actor;
  rate-limit state is thread-safe by language guarantee.
- **`swift build` ships an arm64 binary in seconds, no Xcode required.**

## Build & run

```bash
swift build --product imessage-mcp
.build/debug/imessage-mcp  # speaks JSON-RPC on stdin/stdout
```

Test stdio directly:

```bash
(
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
  sleep 0.3
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  sleep 0.2
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  sleep 1
) | .build/debug/imessage-mcp
```

## Deploy via wss-bridge

Designed to be wrapped by [wss-bridge](https://github.com/klutometis/wss-bridge)
for remote access through an MCP gateway:

```bash
wss-bridge \
  --wss-url wss://mcp.example.com/devices/mac \
  --token "$WSS_BRIDGE_TOKEN" \
  --cmd /path/to/.build/release/imessage-mcp
```

## Permissions

The process running `imessage-mcp` needs:

- **Full Disk Access** (to read `~/Library/Messages/chat.db`).
- **Automation → Messages** (to send via AppleScript).

Both are granted via macOS System Settings → Privacy & Security.

## License

TBD. Forked from imessage-gemini (also TBD); MIT-compatible.

## Bell moments

The first end-to-end send through this server: `2026-05-18 02:43 PDT`.
See `~/prg/mcp-gateway/notes/imessage-mcp-swift-first-light-2026-05-18.md`.
