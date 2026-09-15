# Examples

- `synthetic-map.json` is a definition for synthetic test data. Its addresses and units do not describe any real ECU or vehicle.
- `codex-mock.toml` connects Codex to the in-memory demonstration backend.
- `codex-winols.toml` connects Codex to a running WinOLS Lua bridge.

The JSON file is the `definition` object accepted by `winols_validate_map` and `winols_create_map`. The latter also needs the current `expected_project_id` returned by `winols_get_project`. These files are examples, not arguments that the executable imports directly.

For a mock demonstration, ask your MCP client:

> Use winols_get_project to get the current project ID. Read examples/synthetic-map.json and validate that definition with winols_validate_map. If it is valid, create it with winols_create_map using the current project ID, then use winols_get_map to read back the returned map ID.

The MCP client must have access to the example file, or you can paste its JSON into your request. Restarting the mock server resets its maps.
