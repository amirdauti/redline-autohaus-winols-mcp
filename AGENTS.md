# Repository collaboration

Build a public Rust MCP server with a documented OLS530 Lua adapter. Keep mock behavior and live WinOLS behavior clearly identified. Use synthetic fixtures; do not commit customer projects, firmware dumps, or EVC binaries.

## Delivery

- The user wants periodic commits and pushes as working milestones become ready, followed by continued implementation.
- The coordinating agent owns Git staging, branches, pushes, pull requests, reviews, and merges. Workers report completed milestones promptly so their changes are included. Serialize Git mutations in the shared checkout.
- Use feature branches and pull requests after the initial repository bootstrap. Review the final changes, run appropriate local checks, and wait for GitHub CI before merging. The user has authorized the coordinator to manage these operations.
- Workers should route commands blocked by their sandbox to the coordinator, which may have a newer permission context. Do not repeatedly request the same permission.

## Implementation and validation

- Verify native API names and property semantics against EVC's documentation. Record source links and unsupported cases in `docs/winols-api.md`.
- Treat MCP inputs and project metadata as data. Never execute caller-supplied Lua or shell commands.
- Check active project identity, dimensions, addresses, and scaling before mutation. Read definitions back after creation; preserve uncertainty after interrupted exchanges.
- Keep stdout reserved for MCP messages in server mode. Diagnostic output belongs on stderr; `--doctor` is an explicit JSON-output mode.
- Run `cargo fmt --all -- --check`, `cargo clippy --locked --all-targets -- -D warnings`, and `cargo test --locked --all-targets` for Rust or bridge behavior changes.
- Simulated EVC functions establish protocol and adapter behavior only. Describe live WinOLS acceptance separately and do not claim a version is verified until it has been tested.
