//! Run the actual bridge under vendored Lua 5.3 with synthetic native functions.

use serde_json::json;
use std::path::PathBuf;
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
    time::Duration,
};
use winols_mcp::{backend::Backend, domain::MapDefinition, mailbox::Mailbox};

fn lua_runtime(directory: &std::path::Path) -> mlua::Lua {
    let lua = mlua::Lua::new();
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let package: mlua::Table = lua.globals().get("package").unwrap();
    package
        .set(
            "path",
            format!(
                "{}/bridge/?.lua;{}/tests/lua/?.lua",
                root.display(),
                root.display()
            )
            .replace('\\', "/"),
        )
        .unwrap();
    lua.globals()
        .set(
            "TEST_TEMP_DIR",
            directory.to_string_lossy().replace('\\', "/"),
        )
        .unwrap();
    lua
}

struct LuaWorker {
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<Result<(), String>>>,
}

impl Drop for LuaWorker {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(worker) = self.thread.take() {
            let _ = worker.join();
        }
    }
}

#[tokio::test]
async fn rust_backend_round_trips_through_the_actual_lua_file_bridge() {
    let directory = tempfile::tempdir().unwrap();
    let mailbox = Mailbox::open(directory.path(), Duration::from_secs(3)).unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let worker_stop = stop.clone();
    let worker_directory = directory.path().to_path_buf();
    let (ready, started) = mpsc::channel();
    let worker = thread::spawn(move || -> Result<(), String> {
        let lua = lua_runtime(&worker_directory);
        let setup = lua
            .load(
                r#"
            fixture = require('native_fixture').new()
            local adapter = require('core').new(fixture.api, {
                inventory=fixture.inventory, session_id='rust-lua-integration'
            })
            connection = require('mailbox').new(TEST_TEMP_DIR, adapter)
            function bridge_step() return connection:step() end
        "#,
            )
            .exec()
            .map_err(|e| e.to_string());
        ready.send(setup.clone()).unwrap();
        setup?;
        let step: mlua::Function = lua
            .globals()
            .get("bridge_step")
            .map_err(|e| e.to_string())?;
        while !worker_stop.load(Ordering::SeqCst) {
            step.call::<bool>(()).map_err(|e| e.to_string())?;
            thread::sleep(Duration::from_millis(5));
        }
        Ok(())
    });
    let mut guard = LuaWorker {
        stop,
        thread: Some(worker),
    };
    started
        .recv_timeout(Duration::from_secs(3))
        .unwrap()
        .unwrap();
    let mut backend = Backend::Winols(mailbox);
    assert_eq!(backend.status().await.unwrap()["backend"], "winols");
    let project = backend.project().await.unwrap();
    assert_eq!(project.map_count, 0);
    let definition: MapDefinition = serde_json::from_value(json!({
        "name":"Synthetic transport test", "address":4096,"columns":4,"rows":2,
        "data_type":"i16_be","factor":0.03125,"offset":-40,"unit":"C",
        "x_axis":{"address":1024,"data_type":"u16_le","factor":10,"unit":"rpm"},
        "y_axis":{"address":2048,"data_type":"u8"}
    }))
    .unwrap();
    assert_eq!(
        backend.validate_map(&definition).await.unwrap()["valid"],
        true
    );
    let created = backend
        .create_map(&project.id, definition.clone())
        .await
        .unwrap();
    let readback = backend
        .get_map(created["id"].as_str().unwrap())
        .await
        .unwrap();
    assert_eq!(created, readback);
    assert_eq!(
        serde_json::from_value::<MapDefinition>(readback["definition"].clone()).unwrap(),
        definition
    );
    assert_eq!(backend.list_maps(0, 10).await.unwrap()["total"], 1);
    assert!(
        backend
            .create_map(&project.id, definition)
            .await
            .unwrap_err()
            .contains("duplicate")
    );
    assert_eq!(backend.project().await.unwrap().map_count, 1);
    guard.stop.store(true, Ordering::SeqCst);
    guard.thread.take().unwrap().join().unwrap().unwrap();
}

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
