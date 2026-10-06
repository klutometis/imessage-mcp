# imessage-mcp

A native Swift stdio MCP server for iMessage on macOS.

Forked from [imessage-gemini](https://github.com/klutometis/imessage-gemini)'s
MessageSender / DatabaseMonitor / MessageDecoder; drops the Vapor/SendBlue
HTTP shim and Gemini integration in favor of a focused stdio MCP
interface using the official [Swift MCP SDK][swift-sdk].

[swift-sdk]: https://github.com/modelcontextprotocol/swift-sdk

## Status (2026-05-18)

All four verbs live:

- ✅ `send_imessage(recipient, message, dry_run?)` — AppleScript via Messages.app,
  to a phone/email *or a group chat* (its `identifier` from
  `list_imessage_chats`, its `any;+;…` guid, or its display name), and
  **confirmed from chat.db**: the result is a JSON receipt (`sent` /
  `delivered` / `pending`, plus the chat and its participants), and it is an
  error if Messages wrote no outgoing row or marked it Not Delivered.

  Why confirmation: until 2026-10-06 every recipient was addressed as a
  `participant`. A group identifier became a buddy that does not exist,
  `send` silently did nothing, osascript exited 0, and the tool said "Sent".
  osascript's exit status says nothing about delivery; only the row Messages
  writes does. Groups never set `is_delivered`, so `sent` is as far as a group
  receipt goes.

  Testing over ssh: sshd has Full Disk Access on the Macly mini but not
  Automation → Messages, so any osascript from an ssh shell hangs on a TCC
  prompt nobody can answer. The grants belong to the uv `python3.11` that
  runs wss-bridge, so run tests as a launchd job under that interpreter
  (`launchctl submit -l <label> -- <python3.11> script.py`), which is how the
  group `dry_run` was verified.
- ✅ `search_imessages(text?, sender?, chat?, since?, until?, has_attachment?, from_me?, limit?)` — SQL over `chat.db`, returns full text inline, small images base64-inlined
- ✅ `list_imessage_chats(limit?)` — recent conversations with last-message preview
- ✅ `get_imessage_attachment(message_rowid, attachment_index?, max_inline_bytes?)` — explicit bytes fetch

### Known limitations

- `search_imessages(text=...)` matches against the `message.text` SQL
  column only. Modern macOS often leaves `text` null and stores the body
  in `message.attributedBody` (a TypedStream blob); those messages
  display correctly in results (we decode via Madrid) but won't be
  found by text substring. Workaround for "fully searchable" mode TBD
  (post-process all-recent-N, or maintain an FTS5 mirror).
- Voice memo attachments often have null `mime_type` in chat.db; only
  the UTI (`com.apple.coreaudio-format`) is populated. Inlining policy
  uses `mime.hasPrefix("image/")`, so audio is correctly skipped, but
  the LLM sees no `mimeType` field for it.
- Inline image cap: 1MB (per attachment). Larger images: caller fetches
  explicitly via `get_imessage_attachment` (cap there is 5MB default,
  caller-configurable).
- No `mark_read` verb — implicit on read (the SQL queries are read-only;
  Messages.app updates `is_read` when the user opens the conversation
  in the GUI). TODO if needed: AppleScript marker.

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
