# Local bridge protocol, version 1

The Rust process speaks MCP over stdin/stdout. Its WinOLS backend exchanges JSON data with our Lua script through a shared local directory. The directory is a trusted boundary: use a private directory writable only by your Windows account. No generated Lua or arbitrary commands are accepted as tool inputs.

One Rust process owns `client.lock` using an operating-system file lock for its entire lifetime. The file can remain after exit; existence alone does not mean the lock is held. Use one Lua bridge per directory. Run the executable and WinOLS as the same Windows user.

## Exchange

1. Rust validates inputs, writes `request.tmp`, closes it, and renames it to `request.json`.
2. Lua claims the request by renaming it to `processing.json` and decodes JSON as data.
3. Lua checks protocol version, request expiry, operation, and parameters. Creation also checks the current project identity and definition bounds.
4. Lua writes the complete response to `response.tmp`, closes it, removes `processing.json`, then renames `response.tmp` to `response.json`.
5. Rust limits the response to 1 MiB, checks its version, ID, and envelope, then consumes `response.json`.

Rust serializes backend calls and never automatically retries an operation. A successful create result contains the definition read back from WinOLS. It does not save the project.

Request:

```json
{
  "protocol_version": 1,
  "id": "unique-request-uuid",
  "operation": "get_project",
  "params": {},
  "expires_at": 1800000000
}
```

`expires_at` is an absolute Unix timestamp in seconds. Expired requests must not begin a mutation. Expiry does not cancel an operation that has already started.

Success:

```json
{
  "protocol_version": 1,
  "id": "unique-request-uuid",
  "ok": true,
  "result": {"id": "project-identity", "name": "Example", "size_bytes": 1048576, "map_count": 0}
}
```

Failure:

```json
{
  "protocol_version": 1,
  "id": "unique-request-uuid",
  "ok": false,
  "error": {"code": "project_changed", "message": "The active project changed."}
}
```

Include either `result` or `error`, never both. This protocol is internal to this release; MCP clients use the tools documented in the main README.

| Operation | Parameters | Result |
| --- | --- | --- |
| `get_status` | `{}` | Backend connection/capability information. |
| `get_project` | `{}` | `{id, name, size_bytes, map_count}`. |
| `list_maps` | `{offset, limit}` | `{maps: [{id, definition}], total}`; limit 1–100. |
| `get_map` | `{id}` | `{id, definition}`. |
| `create_map` | `{expected_project_id, definition}` | `{id, definition}` read back after creation. |

The definition schema is in [src/domain.rs](../src/domain.rs) and [examples/synthetic-map.json](../examples/synthetic-map.json). Rust performs `winols_validate_map` locally against the size returned by `get_project`.

## Interrupted exchange recovery

A timeout or cancellation can leave the outcome unknown: WinOLS may have created the map even though Rust did not receive a response. The Rust process then refuses further bridge calls, and a fresh process refuses to start if pending exchange files exist. A malformed or mismatched response also stops reuse. No request is replayed automatically.

To recover:

1. Stop the MCP server and the Lua bridge. Confirm the bridge has stopped before touching the mailbox.
2. Inspect the project directly in WinOLS. If the last operation was creation, check its name, address, axes, and scaling to determine whether it completed. Correct any partial definition before proceeding.
3. Preserve pending request/response files if needed for diagnosis. Once the operation's outcome is understood and both processes are stopped, remove only `request.tmp`, `request.json`, `processing.json`, `response.tmp`, and `response.json` from this mailbox.
4. Start the bridge and server again, read the project and map list, and continue from the observed state.

Do not delete another process's active mailbox or retry creation based only on a timeout. Stopping processes and clearing these files abandons the old exchange; it does not roll back changes already made in WinOLS.

## Testing boundary

Automated tests exercise protocol handoff, locks, bounds, cancellation, and the Lua adapter with simulated EVC functions. Those tests cannot establish behavior of a particular licensed WinOLS/OLS530 installation. Follow the live acceptance checklist in [bridge/README.md](../bridge/README.md) before using that installation for normal work.
