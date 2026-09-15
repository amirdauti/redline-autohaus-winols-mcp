# WinOLS API mapping

The live bridge targets WinOLS 5.93+ in the WinOLS 5 series and the OLS530 plugin. The public repository contains original bridge code, not EVC binaries, licenses, manuals, or customer data. Each user supplies their own licensed installation.

## Primary sources

- [EVC: Lua for WinOLS](https://www.evc.de/en/product/ols/lua.asp): OLS530 licensing, on-demand/current-project execution, and continuous script processing.
- [EVC Lua manual](https://www.evc.de/ftp/winols/LuaManualEn.pdf), inspected September 15, 2026: sections below refer to that downloaded revision. EVC updates the PDF in place, so section numbering can change.
- [EVC WinOLS help](https://www.evc.de/ftp/winols/WinOLS%20HelpEn.pdf), inspected September 15, 2026: export semantics, map properties, and the `set_map_property` property reference.
- [EVC Lua examples](https://www.evc.de/ftp/winols/LuaSamples.zip): `08 - Create a map/create_map.lua` confirms numeric enum constants and the `TRUE` last-created-map setter argument.
- [EVC release history](https://www.evc.de/en/download/down_winols_whatsnew_raw.asp): WinOLS 5.93 adds `projectGetElementRanges` used for bounds validation.

## Protocol operations and native calls

| MCP bridge operation | Documented native API | Use |
| --- | --- | --- |
| `get_status` | `GetVersion(eWinOLSMajor/eWinOLSMinor)` (§2.2.26) | Reports runtime version; does not establish live acceptance. |
| `get_project` | `projectGetProperty(ePrjFilename)` and `projectGetProperty(ePrjPropChecksumSHA256)` (§2.4.1) | Identifies the saved project using its filename and the original hash observed with default `iOrgVer=0`; see the hash-selector caveat below. |
| Project bounds | `projectGetElementRanges(FALSE, FALSE)` (§2.4.21) and `projectGetElementOffset()` (§2.4.18) | Parses the documented `ELEMENTNAME:FROM-TO` decimal, inclusive format. Only one element beginning at zero and current offset zero are accepted. |
| `read_bytes` | `projectGetAt(address,eByte,count,TRUE/FALSE)` (§2.4.27), `windowGetActive()` (§2.6.1), `versionGetProperty(eVerPropName)` (§2.5.1) | Reads original/current byte arrays and checks the observed project/window/version-name context before and after. |
| `list_maps`, `get_map` | `projectExportMaps(filename)` (§2.4.6), then `windowGetMapProperties(property,address,skip)` (§2.6.3) | Exports metadata to a fixed CSV filename for defined-map address inventory, then reads native properties. Unconfigured hexdump windows can be omitted. |
| `create_map` | `projectFindMap("Name",name,-1)` (§2.4.35), `projectAddMap()` (§2.4.36), `windowSetMapProperties(property,value,TRUE)` (§2.6.4) | Checks duplicate/temporary names; creates and configures the last map created by Lua. |
| Failed-create rollback | `projectDelMap(generated_name)` (§2.4.37) | Uses an exact generated name containing no wildcards. Never exposes general deletion as an MCP operation. |
| Polling | `Sleep(100, request_path)` (§2.2.27) | Waits without busy polling. File arrivals wake the script. |

The manual inconsistently spells the export function `projectExportMaps` in its heading and `projectExportmaps` in its syntax, and its example mistakenly calls `projectExport`. The adapter resolves either documented case of the map-export function and never substitutes the binary/project exporter. The correct global for a specific WinOLS build remains part of live acceptance.

## Byte reads and version context

`read_bytes` takes `expected_project_id`, `address`, and `count` (1–4096). It returns `project_id`, `address`, `window_id` as a decimal string, `version_name`, and equally sized `original_bytes`/`current_bytes` arrays. Native `projectGetAt` addresses are relative to the current element, so the existing single-element, byte-zero restrictions also apply to reads. `count > 1` returns an array; the one-value result is normalized to an array. The native error sentinel `eEmptyvalue` (documented as `-99999`) is rejected, and each result must be an integer from 0 through 255. No native maximum read count is documented; 4096 is the MCP limit.

The bridge uses `windowGetActive()` and `versionGetProperty(eVerPropName)` to guard the observed context, alongside project identity. The manual documents no active version index or UUID getter. Window handles expire with the session and version names may be duplicated, so these checks do not establish a unique version identity or a revision lock.

`versionGetProperty` also documents `eVerPropComment`, `eVerPropCreatedOn`, `eVerPropChangedOn`, `eVerPropChecksum`, `eVerPropCVN`, `eVerPropOutput`, `eVerPropTorque`, `eVerPropState`, and `eVerPropCredits`. `GetProjectVersions` reads the saved project's version list; it does not identify which listed version is currently active.

### Native Boolean arguments

Pass EVC's numeric `TRUE`/`FALSE` constants (1/0) for native Boolean inputs. The manual's `projectSave` example explicitly requires `TRUE` instead of Lua `true`, and the official map-creation example uses `TRUE` for `windowSetMapProperties`' last-created-map argument.

On WinOLS 5.93.01 with OLS530 3.006, probes at a known changed byte with counts 1, 2, and 4 confirmed that `projectGetAt(...,TRUE)` returns original data and `projectGetAt(...,FALSE)` returns current data. Lua `true` and `false` both returned current data. Earlier inconclusive or incorrect original-read results came from the adapter's input representation, not a demonstrated failure of the native source selector. Native Boolean arguments must use the numeric constants even though bridge JSON and internal Lua logic use ordinary Booleans.

A creation trace also showed `projectAddMap()` succeeding before the name setter with Lua `true` failed. With numeric `TRUE`, two maps' creation and native property readback, including their axes, succeeded. Subsequent get/list reads also passed after support for `$`-prefixed CSV addresses was added. Full acceptance, including persistence and rollback cases, remains outstanding.

### Hash-selector ambiguity

The inspected Lua manual's wording for `projectGetProperty` suggests passing `1` for original checksums. In a native probe with a modified version active, default `iOrgVer=0` matched the independently exported original binary SHA-256, while `iOrgVer=1` matched the modified version's SHA-256. This is an installation observation, not a general Boolean current/original contract or completed live acceptance. Do not infer the active version from this selector or assume how hashes refresh for unsaved changes. The byte-read operation uses `projectGetAt`'s separate `bOrg` parameter with numeric EVC constants, not this hash selector.

## Definition properties

The Lua manual states that `windowGetMapProperties` and `windowSetMapProperties` use the property names of WinOLS Script's `set_map_property`. The help's “Scripts” chapter and official Lua creation example document these names.

| Portable field | Native properties |
| --- | --- |
| Name | `Name` |
| Generated identity | `IdName` |
| Columns / rows | `Spalten`, `Zeilen` |
| Map address | `Feldwerte.StartAddr` |
| Integer width / byte order | `DataOrg`: `eByte`, `eLoHi`, `eHiLo`, `eLoHiLoHi`, `eHiLoHiLo` |
| Signedness | `bVorzeichen`, separately from byte order |
| Map scaling / unit | `Feldwerte.Faktor`, `Feldwerte.Offset`, `Feldwerte.Einheit` |
| Axis address | `StuetzX.DataAddr`, `StuetzY.DataAddr` |
| Axis type / signedness | `StuetzX.DataOrg`, `StuetzY.DataOrg`, corresponding `.bVorzeichen` |
| Axis scaling / unit | Corresponding `.Faktor`, `.Offset`, `.Einheit` |
| Axis source | Corresponding `.DataSrc`: `eRom` for contiguous binary axes, `eDataSrcNone` when absent |

Physical values use `raw * factor + offset`. The adapter sets skipped bytes, line skipped bytes, reciprocal flags, and pre-offsets to zero. For present axes, header bytes and reversed order are also zero. These conditions are checked on readback and when reading existing maps.

The bridge rejects floating-point, bitfield, noncontiguous, reversed/inverted, reciprocal, accumulated/subtracted, and user-defined text/value-axis layouts. A map with an unsupported layout causes a clear error on the requested page rather than being represented incorrectly. Map dimensions are limited to 4096 per axis and 1,048,576 total cells; map inventory is limited to 10,000 entries. The getters require the project's “Transfer map structure” permission.

## Inventory and address limitations

EVC help §4.12.6 describes CSV addresses as decimal offsets relative to the project start, corresponding to the “All elements” view. The inspected native export instead used explicitly `$`-prefixed hexadecimal addresses while native getters returned decimal values. The adapter accepts strict decimal integers or `$`-prefixed hexadecimal and compares their normalized numeric values; it does not guess a radix for unprefixed values. For example, `256` and `$100` denote the same byte offset.

The manual does not publish a stable CSV column-header schema. Therefore the user must configure the exact header and delimiter from an inspected export and ensure **all maps and columns** are enabled. Missing/ambiguous address columns, malformed CSV, unsupported address syntax, out-of-bounds offsets, and disagreement between normalized CSV and getter addresses are rejected.

The adapter makes no undocumented wildcard assumption about `projectFindMap`: its search is used only for exact requested names and generated temporary names. It also avoids interpreting the human-readable ECU software-size property as byte length. Single-element projects make the getter/setter address coordinate unambiguous; multi-element layouts remain unsupported until verified.

The user must compare reported map count with WinOLS's defined-map count before enabling creation. A configured CSV export that silently omits defined maps cannot provide a complete duplicate-address check. There is no documented export-options API in the inspected manual, so this prerequisite cannot be automatically enforced by this release.

CSV export is not an inventory of every project window. In a native failed-create trace, `projectAddMap()` left unconfigured `Hexdump` entries when the first naming setter failed, and CSV omitted those entries. Name searches can match both these partial windows and the main hexdump at the same address. After an uncertain creation, inspect the full UI map/window list and resolve only identified partial entries before mailbox cleanup or retry. Neither a matching CSV count nor an address-zero name match proves a unique cleanup target.

The inspected Lua manual contains no dedicated potential-map enumeration or conversion API. EVC help §2.2 documents the UI workflow: inspect a candidate in the hexdump, navigate with `F`/`Shift+F`, and double-click its tag to convert it into a normal map. `projectFindMap` searches by name or ID; it is not documented as a potential-map inventory. Raw shapes and values cannot establish a tuning function. Keep candidate definitions unclassified and raw until their semantics, axes, units, and scaling have been validated.

## What is verified

Automated tests use synthetic projects and simulated EVC functions to check input validation, enum/property mapping, readback, rollback behavior, request expiry/replay, and mailbox handoff. They do not execute WinOLS.

Limited live verification on **WinOLS 5.93.01 with OLS530 3.006** established:

- Two 2D map metadata creations with unsigned 16-bit little-endian storage and raw linear axes passed property readback, including axes.
- `get_map` and `list_maps` returned those definitions after parsing the native `$`-prefixed CSV addresses.
- Original and current byte reads matched independent source buffers. The checked byte ranges remained unchanged across metadata creation.

These checks do not establish the semantic function or physical units of either candidate map. They do not complete the synthetic acceptance checklist, including persistence, supported-layout coverage, and native rollback cases.

Before a WinOLS version is marked supported by live acceptance, run [the synthetic acceptance procedure](../bridge/README.md#live-acceptance-checklist). Until that is done, this adapter remains experimental.
