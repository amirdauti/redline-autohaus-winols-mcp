# WinOLS API mapping

The live bridge targets WinOLS 5.93+ in the WinOLS 5 series and the OLS530 plugin. The public repository contains original bridge code, not EVC binaries, licenses, manuals, or customer data. Each user supplies their own licensed installation.

## Primary sources

- [EVC: Lua for WinOLS](https://www.evc.de/en/product/ols/lua.asp): OLS530 licensing, on-demand/current-project execution, and continuous script processing.
- [EVC Lua manual](https://www.evc.de/ftp/winols/LuaManualEn.pdf), inspected September 15, 2026: sections below refer to that downloaded revision. EVC updates the PDF in place, so section numbering can change.
- [EVC WinOLS help](https://www.evc.de/ftp/winols/WinOLS%20HelpEn.pdf), inspected September 15, 2026: export semantics, map properties, and the `set_map_property` property reference.
- [EVC Lua examples](https://www.evc.de/ftp/winols/LuaSamples.zip): `08 - Create a map/create_map.lua` confirms numeric enum constants and the `true` last-created-map setter argument.
- [EVC release history](https://www.evc.de/en/download/down_winols_whatsnew_raw.asp): WinOLS 5.93 adds `projectGetElementRanges` used for bounds validation.

## Protocol operations and native calls

| MCP bridge operation | Documented native API | Use |
| --- | --- | --- |
| `get_status` | `GetVersion(eWinOLSMajor/eWinOLSMinor)` (§2.2.26) | Reports runtime version; does not establish live acceptance. |
| `get_project` | `projectGetProperty(ePrjFilename)` and `projectGetProperty(ePrjPropChecksumSHA256)` (§2.4.1) | Identifies the saved project and original binary. Default `iOrgVer=0` reads the original. |
| Project bounds | `projectGetElementRanges(false, false)` (§2.4.21) and `projectGetElementOffset()` (§2.4.18) | Parses the documented `ELEMENTNAME:FROM-TO` decimal, inclusive format. Only one element beginning at zero and current offset zero are accepted. |
| `list_maps`, `get_map` | `projectExportMaps(filename)` (§2.4.6), then `windowGetMapProperties(property,address,skip)` (§2.6.3) | Exports metadata to a fixed CSV filename for complete address inventory, then reads native properties. |
| `create_map` | `projectFindMap("Name",name,-1)` (§2.4.35), `projectAddMap()` (§2.4.36), `windowSetMapProperties(property,value,true)` (§2.6.4) | Checks duplicate/temporary names; creates and configures the last map created by Lua. |
| Failed-create rollback | `projectDelMap(generated_name)` (§2.4.37) | Uses an exact generated name containing no wildcards. Never exposes general deletion as an MCP operation. |
| Polling | `Sleep(100, request_path)` (§2.2.27) | Waits without busy polling. File arrivals wake the script. |

The manual inconsistently spells the export function `projectExportMaps` in its heading and `projectExportmaps` in its syntax, and its example mistakenly calls `projectExport`. The adapter resolves either documented case of the map-export function and never substitutes the binary/project exporter. The correct global for a specific WinOLS build remains part of live acceptance.

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

EVC help §4.12.6 explicitly defines CSV addresses as decimal offsets relative to the project start, corresponding to the “All elements” view. The manual does not publish a stable CSV column-header schema. Therefore the user must configure the exact header and delimiter from an inspected export and ensure **all maps and columns** are enabled. Missing/ambiguous address columns, malformed CSV, nondecimal addresses, out-of-bounds offsets, and disagreement between CSV and getter addresses are rejected.

The adapter makes no undocumented wildcard assumption about `projectFindMap`: its search is used only for exact requested names and generated temporary names. It also avoids interpreting the human-readable ECU software-size property as byte length. Single-element projects make the getter/setter address coordinate unambiguous; multi-element layouts remain unsupported until verified.

The user must compare reported map count with WinOLS before enabling creation. A configured CSV export that silently omits maps cannot provide a complete duplicate-address check. There is no documented export-options API in the inspected manual, so this prerequisite cannot be automatically enforced by this release.

## What is verified

Automated tests use synthetic projects and simulated EVC functions to check input validation, enum/property mapping, readback, rollback behavior, request expiry/replay, and mailbox handoff. They do not execute WinOLS.

Before a WinOLS version is marked supported by live acceptance, run [the synthetic acceptance procedure](../bridge/README.md#live-acceptance-checklist). Until that is done, this adapter remains experimental.
