# Contributing

Contributions are welcome. Start with the mock backend; it does not require WinOLS or an OLS530 license.

## Development

Install Rust with `rustup`. The repository's `rust-toolchain.toml` selects the toolchain. Windows builds also need the MSVC C++ build tools and Windows SDK.

```sh
cargo fmt --all -- --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked --all-targets
cargo run --locked -- --backend mock --doctor
```

CI runs Rust checks on Windows and Ubuntu. Ubuntu coverage validates the portable server and mock backend; it does not establish WinOLS compatibility.

## Changes and test data

- Keep public fixtures synthetic. Do not upload customer files, ECU firmware, licensed map packs, DAMOS/A2L files, serial numbers, or license credentials.
- Include a regression test when fixing validation, protocol, or mutation behavior.
- Keep stdout reserved for MCP messages. Use stderr for diagnostics while serving.
- Document the EVC API source for changes to the Lua adapter, and identify the WinOLS and OLS530 versions used for live verification.
- Keep creation restricted to map metadata. Changes that add binary writes, saves, or a larger automation interface need an explicit design discussion.
- Include `Cargo.lock` updates when changing dependencies.

For bug reports, provide the operating system, server version, backend, exact steps, and redacted diagnostics. A synthetic reproduction is more useful than a proprietary project.

## Release bundles

The **Build Windows release bundle** workflow is manually triggered. It builds an x64 executable, packages the bridge and documentation, and uploads a ZIP, SHA-256 checksum, and source commit ID as workflow artifacts. It does not create or publish a GitHub Release. Maintainers can inspect the bundle and run the live acceptance check before publishing it separately.

Contributions are distributed under the repository's [MIT license](LICENSE).
