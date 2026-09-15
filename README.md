# WinOLS MCP

A Rust [Model Context Protocol](https://modelcontextprotocol.io/) server that lets Codex and other MCP clients inspect and create map definitions in WinOLS through a Lua bridge.

**Status: initial implementation.** The mock backend supports development without WinOLS. The live bridge needs acceptance testing inside a licensed WinOLS installation; no WinOLS version is currently certified by this project.

```text
Codex / MCP client -- stdio --> winols-mcp -- local files --> Lua bridge in WinOLS
                                    |
                                    +-- in-memory mock backend
```

## Capabilities

| Tool | Purpose |
| --- | --- |
| `winols_status` | Check the selected backend and connection. |
| `winols_get_project` | Read the active project's identity, binary size, and map count. |
| `winols_list_maps` | List definitions with `offset` and `limit` pagination. |
| `winols_get_map` | Read a definition by its `id`. |
| `winols_validate_map` | Check a proposed `definition` against the current project. |
| `winols_create_map` | Create a definition using `expected_project_id` and `definition`. |

Definitions describe contiguous maps with integer storage, byte order, dimensions, scaling, units, and optional X/Y axes. Addresses are zero-based **byte offsets** within the project binary. Scaling uses `physical = raw * factor + offset`; X length follows columns and Y length follows rows.

Creation changes map metadata in the active WinOLS project. The server does not save the project, identify maps automatically, change firmware bytes, or flash an ECU. Validate proposed addresses and scaling against your own source data before creating definitions.

## Prerequisites

For the live backend, each user needs Windows, their own licensed WinOLS installation, and EVC's separately purchased **OLS530 Lua plugin**. EVC provides Lua automation for the current project and for scripts that run continuously. This repository does not include EVC software or licenses. See [EVC's Lua product page](https://www.evc.de/en/product/ols/lua.asp) and [OLS530 requirements](https://www.evc.de/en/product/ols/plugins_detail.asp?cksName=OLS530).

The mock backend runs without WinOLS on Windows and Linux. Its project and map definitions exist only in memory and reset when the server exits.

## Build and try the mock backend

Install [Rust through rustup](https://rustup.rs/). The repository selects its Rust version in `rust-toolchain.toml`. Building on Windows also requires the MSVC C++ build tools and Windows SDK.

```powershell
git clone https://github.com/amirdauti/redline-autohaus-winols-mcp.git
cd redline-autohaus-winols-mcp
cargo build --release --locked
.\target\release\winols-mcp.exe --backend mock --doctor
```

`--doctor` prints diagnostic JSON and exits. Without that flag the program serves MCP over stdio and waits for an MCP client. Logs go to stderr. On Linux the executable is `./target/release/winols-mcp`.

The repository includes a manual workflow to build a Windows x64 ZIP containing the executable, Lua bridge, examples, and documentation. Downloadable binaries are available only after a maintainer builds and distributes that bundle; building from source works independently of releases.

## Connect Codex

Register the mock server using an **absolute path** to your compiled executable:

```powershell
codex mcp add winols-mock -- "C:\path\to\winols-mcp.exe" --backend mock
codex mcp list
```

Alternatively, merge [examples/codex-mock.toml](examples/codex-mock.toml) into your Codex `config.toml`, adjusting the executable path. These examples use Codex's documented stdio configuration. See the [official OpenAI documentation for MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli).

Start a Codex session with the server configured and try:

> Check winols_status, show the current project, and list its maps.

Then follow the [synthetic creation example](examples/README.md) to validate, create, and read back a map. No real ECU definitions are included.

## Connect WinOLS

1. Build the Windows executable and place the supplied `bridge` folder in a stable location.
2. Follow the [Lua bridge setup](bridge/README.md), including its mailbox directory configuration. Start the script inside WinOLS with the intended project open.
3. Use the same absolute mailbox path to check the connection:

   ```powershell
   & "C:\path\to\winols-mcp.exe" --backend winols --bridge-dir "C:\winols-mcp-mailbox" --doctor
   ```

4. Register the live server in Codex:

   ```powershell
   codex mcp add winols -- "C:\path\to\winols-mcp.exe" --backend winols --bridge-dir "C:\winols-mcp-mailbox"
   ```

An equivalent config is in [examples/codex-winols.toml](examples/codex-winols.toml). The default backend is `winols`, which requires `--bridge-dir`; mock mode must be selected explicitly. `--timeout-ms` controls the bridge response timeout and defaults to `10000`.

Keep the mailbox in a local directory writable only by your user, with one server and one bridge using it. The bridge processes requests with the permissions of WinOLS. Project metadata returned through MCP becomes available to your MCP client.

### Creating a definition

1. Call `winols_get_project` and retain its current `id`.
2. Pass your definition to `winols_validate_map`.
3. Call `winols_create_map` with that definition and the retained `expected_project_id`.
4. Use the returned map ID with `winols_get_map`, then inspect the definition in WinOLS before saving the project yourself.

The project ID check helps detect a project switch between inspection and creation. Stop if the active project changes, then read its identity again. If a creation times out or returns an invalid or mismatched readback, the operation may already have completed in WinOLS. The MCP server stops using that bridge connection, including for reads. Inspect the project directly in WinOLS, stop both the MCP server and Lua bridge, and follow [mailbox recovery](docs/bridge-protocol.md) before restarting and listing maps or retrying creation.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| The executable waits silently | It is serving stdio. Use an MCP client, or add `--doctor` for a one-shot check. |
| Bridge timeout | Verify the Lua script is running and both sides use the same local mailbox directory. |
| Project unavailable or changed | Open the intended project and call `winols_get_project` again. |
| Definition rejected | Check byte offsets, map/axis bounds, dimensions, storage type, and nonzero finite scaling. |
| Mailbox busy or stale | Inspect the last operation directly in WinOLS, stop both sides, and follow [mailbox recovery](docs/bridge-protocol.md). |

## Development and license

See [CONTRIBUTING.md](CONTRIBUTING.md) for checks, synthetic fixtures, and release bundles. Tests cover the portable server, domain validation, and simulated bridge behavior; live acceptance requires WinOLS and OLS530.

Distributed under the [MIT license](LICENSE). WinOLS is a product of EVC electronic GmbH. This is an independent project and is not affiliated with EVC or OpenAI.
