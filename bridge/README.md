# WinOLS Lua bridge

This is the live adapter for the Rust MCP server. It reads bounded ranges of original/current bytes and creates map **definitions** in the current WinOLS project: names, addresses, dimensions, storage types, scaling, and optional ROM axes. It does not save the project or change firmware bytes.

The adapter follows EVC's documented APIs and is tested with simulated EVC functions. On WinOLS 5.93.01 with OLS530 3.006, two 2D definitions passed creation, get/list readback, and original/current byte comparisons against independent source buffers. The checked byte ranges remained unchanged. **Full live acceptance has not been completed.** CSV export settings and native property formatting must be checked on the actual installation before production use. These observations do not validate any tuning semantics or units; see [the verification scope](../docs/winols-api.md#what-is-verified).

## Requirements

- Windows with licensed **WinOLS 5.93 or later in the WinOLS 5 series**, plus the separately licensed **OLS530 Lua** plugin. A demo installation is insufficient.
- A saved project containing one element that starts at byte zero, with its original SHA-256 available in project properties. Multi-element projects are rejected.
- Permission to read map structure in that project. Protected projects can deny the native getters.
- A private, local mailbox directory used by one MCP server and one Lua bridge. Use the same Windows account; keep the directory out of shared/synced locations.

See [API sources and boundaries](../docs/winols-api.md) for supported layouts and version requirements.

## Configure and start

1. Copy the complete `bridge` directory to a permanent location, for example `C:\winols-mcp\bridge`.
2. Create an empty mailbox directory, for example `C:\winols-mcp-mailbox`.
3. In WinOLS, open a saved synthetic test project. Export the map list using **Project → Export CSV/JSON map list**. Configure the export to include **all maps and all columns**, using CSV. Inspect the resulting text file and identify its column containing map start addresses relative to the project start. The adapter accepts decimal integers and explicitly `$`-prefixed hexadecimal addresses; the latter were observed in the native export. EVC does not publish the column-header schema in the manual; this release deliberately requires the header from your installation.
4. Edit the four local settings at the top of `winols_bridge.lua`:

   ```lua
   local SCRIPT_DIRECTORY = [[C:\winols-mcp\bridge]]
   local BRIDGE_DIRECTORY = [[C:\winols-mcp-mailbox]]
   local CSV_ADDRESS_COLUMN = "YOUR EXACT EXPORTED ADDRESS COLUMN TITLE"
   local CSV_DELIMITER = ";" -- use "," or "\t" if that is what your export contains
   ```

   Copy the header text inside CSV quoting, preserving its spelling and case. The adapter rejects missing, duplicate, ambiguous, or malformed address columns. Unprefixed addresses are decimal; `$` explicitly selects hexadecimal. Its native export must include all defined maps; compare the MCP map count with WinOLS's defined maps before enabling creation. The count does not include every hexdump window or potential map. These export settings are installation-specific, so repeat that comparison after changing them.

5. Drag `winols_bridge.lua` onto the **target project window** in WinOLS. EVC documents this as a way to start Lua with that project's context. The script checks its configuration and enters a polling loop.
6. Start the Rust server using the same mailbox directory:

   ```powershell
   winols-mcp.exe --backend winols --bridge-dir C:\winols-mcp-mailbox
   ```

   Use the MCP client's normal configuration to launch that command. Run read-only tools first and compare the current project and map list with WinOLS.

The bridge exports only map metadata into the fixed mailbox file `inventory.csv`, extracts its addresses, then reads each definition using native getters. It removes the successful temporary export. Unsupported exported layouts return errors; they are not silently omitted.

## Reading bytes and identifying candidates

`winols_read_bytes` accepts `expected_project_id`, a zero-based byte `address`, and a `count` from 1 through 4096. It rejects a range outside the supported single element, which must begin at byte zero and have current element offset zero. Its result contains `project_id`, `address`, `window_id` as a decimal string, `version_name`, and `original_bytes`/`current_bytes` arrays. Both arrays contain exactly the requested number of bytes.

EVC native Boolean inputs use numeric `TRUE`/`FALSE` constants (1/0). On WinOLS 5.93.01 with OLS530 3.006, `projectGetAt` returned the correct original/current sources with these constants at a known changed byte for counts 1, 2, and 4. Passing Lua `true`/`false` instead selected current data in both cases. The adapter uses the numeric constants; see [the API observation](../docs/winols-api.md#native-boolean-arguments).

The bridge checks project identity and the observed window/version name before and after the native reads. A window handle is session-local, and version names need not be unique. This guard detects observed context changes; it does not provide a unique version identity or lock the revision. Byte responses pass through the private mailbox to the MCP client.

EVC's inspected Lua manual does not document an API to enumerate or convert potential maps. Its help documents inspecting candidates in the WinOLS UI and converting a candidate to a normal map by double-clicking its tag. Candidate shapes and raw bytes alone do not validate tuning semantics: retain raw scaling and an unclassified description until the purpose, axes, units, and conversion are established.

## Stop, inspect, and save

The Lua script remains active until a `stop` file appears in the mailbox directory:

```powershell
New-Item -ItemType File -Path C:\winols-mcp-mailbox\stop
```

EVC documents that normal WinOLS actions cannot run during `Sleep`. Stop the adapter before using WinOLS interactively. Once the loop has ended, inspect the new definitions and save the project manually if appropriate. Stop the MCP client as well, remove the `stop` file, then restart the Lua bridge and client for the next session. Project IDs include a bridge-session identifier; always obtain a fresh project ID before creation.

## Creation and recovery

The bridge rechecks project identity, address bounds, axes, dimensions, types, duplicate names/addresses, and request expiry before creating a map. It assigns a temporary unique name and `IdName`, configures metadata, reads it back, assigns the requested final name, and verifies again. The generated `IdName` remains attached to the created map. Native scalar values must round-trip exactly; limited native decimal precision may cause the operation to be rejected.

If configuration fails, the adapter attempts to remove only the uniquely named temporary map. If it cannot verify rollback, it halts with `mutation_uncertain`. No claim of successful rollback is made when the target is unidentified or the project has changed.

Do not retry a timed-out creation: the result may already exist. Stop both processes, inspect WinOLS, then follow [mailbox recovery](../docs/bridge-protocol.md). Keep pending files until the result is understood. The Lua adapter refuses to start with pending request/response files and does not replay them. Successful mailbox transitions are atomic renames, but filesystem writes are not a guarantee against abrupt machine power loss.

Inspect the complete map/window list during uncertain-create recovery, including unconfigured `Hexdump` entries. A native failure after `projectAddMap()` but before naming left such entries, which the CSV inventory omitted. Matching exported map counts cannot establish their absence. Resolve only the identified partial windows through their individual UI rows; a shared name or address can also identify the main hexdump. Clearing mailbox files does not remove these windows.

`stop`, `client.lock`, and `inventory.csv` are not executable input. Only trusted Lua module files in `SCRIPT_DIRECTORY` are loaded. Request content is parsed by the bundled JSON codec and never passed to `load`, `loadstring`, `dofile`, a shell, or a script importer.

## Live acceptance checklist

Use a synthetic binary and a disposable project that contains known maps. Record the WinOLS version, OLS530 version, Windows version, export delimiter/address header, and date. Do not use customer firmware for this procedure.

- Compare the complete defined-map count with `winols_get_project` and paginate `winols_list_maps`. Confirm the inventory includes existing maps that were not created by the bridge. Inspect the window list separately for unconfigured entries omitted by CSV export. Check decimal and `$`-prefixed hexadecimal export addresses against the native getters.
- Read known maps of every supported integer type and signedness. Compare dimensions, project-relative addresses, axes, scaling, and units with the WinOLS properties dialog.
- Read known synthetic byte ranges using `winols_read_bytes`, including one byte, the 4096-byte limit, and a range ending at the last byte. Compare both arrays against independently known original/version data, including a byte that differs between them. Check invalid counts, an out-of-bounds range, and a stale project ID. Confirm returned window/version context and rejection of an observed context change. This checklist does not claim those native checks have passed.
- Create a small map using `examples/synthetic-map.json`, with its ranges within the disposable binary. Stop the adapter and inspect every field. Test optional/absent axes, fractional scaling, and a separate non-ASCII name/unit case.
- Verify rejected out-of-bounds definitions, duplicate names/addresses, and mismatched project IDs produce no additional map. Test metadata readback precision against native getter output.
- On a disposable project, exercise a native setter rejection or permission-denied case. Confirm that the error reports verified rollback or an uncertain outcome accurately. Do not assume simulated failure tests establish native rollback behavior.
- Stop via the `stop` file, confirm the UI is usable again, save manually, reopen, and verify that accepted definitions persisted while firmware bytes remained identical to the original synthetic binary.
- Test timeout recovery on a disposable project. Confirm both processes stop, no pending request is replayed after restart, and the final map inventory reflects the manually inspected result.

Report the actual results with the environment details before marking that build combination as live-verified.
