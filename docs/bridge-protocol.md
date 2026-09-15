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
| `get_project` | `{}` | `{id, name, size_bytes, map_count}`; count covers exported definitions, not all project windows. |
| `read_bytes` | `{expected_project_id, address, count}` | `{project_id, address, window_id, version_name, original_bytes, current_bytes}`; count 1–4096. |
| `list_maps` | `{offset, limit}` | `{maps: [{id, definition}], total}`; limit 1–100. |
| `get_map` | `{id}` | `{id, definition}`. |
| `create_map` | `{expected_project_id, definition}` | `{id, definition}` read back after creation. |

The definition schema is in [src/domain.rs](../src/domain.rs) and [examples/synthetic-map.json](../examples/synthetic-map.json). Rust performs `winols_validate_map` locally against the size returned by `get_project`.

## Bounded byte reads

`read_bytes` uses a zero-based byte address and requires the current project ID. The count must be an integer from 1 through 4096, and the complete range must fit the project. The initial live adapter supports only one element beginning at byte zero, with current element offset zero.

Successful result example, using synthetic data:

```json
{
  "project_id": "project-identity",
  "address": 16,
  "window_id": "12345",
  "version_name": "Synthetic version",
  "original_bytes": [0, 1, 2],
  "current_bytes": [0, 7, 2]
}
```

Each byte array has exactly `count` integer entries in the range 0–255. `original_bytes` comes from the project's original data; `current_bytes` comes from the active version. Native read errors are rejected instead of being coerced into bytes. `window_id` is a decimal string representing the observed active window handle. `version_name` is the native version name; neither field is a stable or unique version ID.

The adapter selects original/current data with EVC's numeric `TRUE`/`FALSE` constants. Lua Boolean literals are not interchangeable with these native inputs in the tested installation; see [the API observation](winols-api.md#native-boolean-arguments).

The bridge checks project identity, window handle, and version name before and after reading, and rejects an observed context change. This guard is not a revision lock or proof of unique version identity. The response contains firmware data and is available to the MCP client through the same private mailbox as other responses.

## Interrupted exchange recovery

A timeout or cancellation can leave the outcome unknown: WinOLS may have created the map even though Rust did not receive a response. The Rust process then refuses further bridge calls, and a fresh process refuses to start if pending exchange files exist. A malformed or mismatched response also stops reuse. No request is replayed automatically.

To recover:

1. Stop the MCP server and the Lua bridge. Confirm the bridge has stopped before touching the mailbox.
2. Inspect the project directly in WinOLS. If the last operation was creation, check its name, address, axes, and scaling to determine whether it completed. Inspect the full map/window list for unnamed or default `Hexdump` entries: a native failure after adding a map can leave an unconfigured window omitted by CSV export. A matching exported map count does not prove its absence. Correct only identified partial entries before proceeding; names or addresses shared with the main hexdump are insufficient deletion targets.
3. Preserve pending request/response files if needed for diagnosis. Once the operation's outcome is understood and both processes are stopped, remove only `request.tmp`, `request.json`, `processing.json`, `response.tmp`, and `response.json` from this mailbox.
4. Start the bridge and server again, read the project and map list, and continue from the observed state.

Do not delete another process's active mailbox or retry creation based only on a timeout. Stopping processes and clearing these files abandons the old exchange; it does not roll back changes already made in WinOLS.

## Testing boundary

Automated tests exercise protocol handoff, locks, bounds, cancellation, and the Lua adapter with simulated EVC functions. Those tests cannot establish behavior of a particular licensed WinOLS/OLS530 installation. Follow the live acceptance checklist in [bridge/README.md](../bridge/README.md) before using that installation for normal work.
