//! Run the actual bridge under vendored Lua 5.3 with synthetic native functions.

use std::path::PathBuf;

#[test]
fn lua_bridge_specifications() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let specs_dir = root.join("tests/lua");
    let mut specs: Vec<_> = std::fs::read_dir(&specs_dir)
        .expect("Lua specifications directory")
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            path.file_name()
                .unwrap()
                .to_string_lossy()
                .ends_with("_spec.lua")
        })
        .collect();
    specs.sort();
    assert!(!specs.is_empty(), "no Lua specifications found");
    for spec in specs {
        let lua = mlua::Lua::new();
        let temp = tempfile::tempdir().unwrap();
        let globals = lua.globals();
        let package: mlua::Table = globals.get("package").unwrap();
        let path = format!(
            "{}/bridge/?.lua;{}/tests/lua/?.lua",
            root.display(),
            root.display()
        )
        .replace('\\', "/");
        package.set("path", path).unwrap();
        globals
            .set(
                "TEST_TEMP_DIR",
                temp.path().to_string_lossy().replace('\\', "/"),
            )
            .unwrap();
        globals
            .set(
                "TEST_BRIDGE_DIR",
                root.join("bridge").to_string_lossy().replace('\\', "/"),
            )
            .unwrap();
        let source = std::fs::read(&spec).unwrap();
        lua.load(&source)
            .set_name(spec.to_string_lossy())
            .exec()
            .unwrap_or_else(|error| panic!("{} failed: {error}", spec.display()));
    }
}
