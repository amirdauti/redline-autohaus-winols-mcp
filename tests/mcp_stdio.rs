//! Exercise the published executable through the same JSON-RPC stdio interface
//! used by an MCP client. Every stdout line must be a protocol response.

use std::{process::Stdio, time::Duration};

use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines},
    process::{Child, ChildStdin, ChildStdout, Command},
    time::timeout,
};

const RESPONSE_TIMEOUT: Duration = Duration::from_secs(15);

struct Client {
    child: Child,
    input: Option<ChildStdin>,
    output: Lines<BufReader<ChildStdout>>,
    next_id: u64,
}

impl Client {
    async fn start() -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_winols-mcp"))
            .args(["--backend", "mock"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .kill_on_drop(true)
            .spawn()
            .expect("start the MCP executable");
        let input = child.stdin.take().expect("piped stdin");
        let output = BufReader::new(child.stdout.take().expect("piped stdout")).lines();
        let mut client = Self {
            child,
            input: Some(input),
            output,
            next_id: 1,
        };
        let initialized = client
            .rpc(
                "initialize",
                json!({
                    "protocolVersion": "2025-11-25",
                    "capabilities": {},
                    "clientInfo": {"name": "stdio-integration-test", "version": "1.0.0"}
                }),
            )
            .await;
        assert!(initialized.get("error").is_none(), "{initialized}");
        assert_eq!(initialized["result"]["protocolVersion"], "2025-11-25");
        assert_eq!(initialized["result"]["serverInfo"]["name"], "winols-mcp");
        assert_eq!(
            initialized["result"]["serverInfo"]["version"],
            env!("CARGO_PKG_VERSION")
        );
        assert!(initialized["result"]["capabilities"]["tools"].is_object());
        client
            .send(json!({"jsonrpc": "2.0", "method": "notifications/initialized"}))
            .await;
        client
    }

    async fn send(&mut self, message: Value) {
        let mut bytes = serde_json::to_vec(&message).unwrap();
        bytes.push(b'\n');
        timeout(RESPONSE_TIMEOUT, async {
            let input = self.input.as_mut().expect("stdin still open");
            input.write_all(&bytes).await.unwrap();
            input.flush().await.unwrap();
        })
        .await
        .expect("MCP stdin write timed out");
    }

    async fn rpc(&mut self, method: &str, params: Value) -> Value {
        let id = self.next_id;
        self.next_id += 1;
        self.send(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}))
            .await;
        let line = timeout(RESPONSE_TIMEOUT, self.output.next_line())
            .await
            .expect("MCP response timed out")
            .expect("read MCP stdout")
            .expect("MCP server closed stdout before responding");
        let response: Value = serde_json::from_str(&line)
            .unwrap_or_else(|error| panic!("non-protocol stdout: {line:?}: {error}"));
        assert_eq!(response["jsonrpc"], "2.0", "{response}");
        assert_eq!(response["id"], id, "unexpected stdout message: {response}");
        response
    }

    async fn call_raw(&mut self, name: &str, arguments: Value) -> Value {
        self.rpc("tools/call", json!({"name": name, "arguments": arguments}))
            .await
    }

    async fn call(&mut self, name: &str, arguments: Value) -> Value {
        let response = self.call_raw(name, arguments).await;
        assert!(response.get("error").is_none(), "{name}: {response}");
        assert_ne!(response["result"]["isError"], true, "{name}: {response}");
        let result = &response["result"];
        let structured = result["structuredContent"].clone();
        assert!(structured.is_object(), "{name}: {response}");
        // Clients without structured-content support must receive the same data.
        let text = result["content"][0]["text"]
            .as_str()
            .expect("text fallback");
        assert_eq!(serde_json::from_str::<Value>(text).unwrap(), structured);
        structured
    }

    async fn tool_error(&mut self, name: &str, arguments: Value, expected: &str) {
        let response = self.call_raw(name, arguments).await;
        assert!(response.get("error").is_none(), "{name}: {response}");
        assert_eq!(response["result"]["isError"], true, "{name}: {response}");
        let message = response["result"]["structuredContent"]["error"]
            .as_str()
            .expect("structured tool error message");
        assert!(
            message.contains(expected),
            "expected {expected:?}: {message}"
        );
    }

    async fn close(mut self) {
        // Closing stdin is how a stdio MCP client disconnects.
        drop(self.input.take());
        let status = timeout(RESPONSE_TIMEOUT, self.child.wait())
            .await
            .expect("MCP server did not exit after stdin closed")
            .expect("wait for MCP server");
        assert!(status.success(), "MCP server exited with {status}");
        let leftover = timeout(RESPONSE_TIMEOUT, self.output.next_line())
            .await
            .expect("stdout did not close")
            .expect("read remaining stdout");
        assert!(
            leftover.is_none(),
            "unexpected trailing stdout: {leftover:?}"
        );
    }
}

fn minimal_definition() -> Value {
    json!({
        "name": "Synthetic ignition table",
        "address": 4096,
        "columns": 4,
        "rows": 2,
        "data_type": "i16_be"
    })
}

#[tokio::test]
async fn executable_negotiates_mcp_and_advertises_seven_tools_with_schemas_and_annotations() {
    let mut client = Client::start().await;
    let listed = client.rpc("tools/list", json!({})).await;
    assert!(listed.get("error").is_none(), "{listed}");
    let tools = listed["result"]["tools"].as_array().expect("tools array");
    let mut names: Vec<_> = tools
        .iter()
        .map(|tool| tool["name"].as_str().unwrap())
        .collect();
    names.sort_unstable();
    assert_eq!(
        names,
        [
            "winols_create_map",
            "winols_get_map",
            "winols_get_project",
            "winols_list_maps",
            "winols_read_bytes",
            "winols_status",
            "winols_validate_map"
        ]
    );
    for tool in tools {
        assert_eq!(tool["inputSchema"]["type"], "object", "{tool}");
        assert_eq!(tool["annotations"]["openWorldHint"], false, "{tool}");
        if tool["name"] == "winols_create_map" {
            assert_eq!(tool["annotations"]["readOnlyHint"], false);
            assert_eq!(tool["annotations"]["destructiveHint"], false);
            assert_eq!(tool["annotations"]["idempotentHint"], false);
            assert_eq!(tool["inputSchema"]["additionalProperties"], false);
            let required = tool["inputSchema"]["required"].as_array().unwrap();
            assert!(required.contains(&json!("expected_project_id")));
            assert!(required.contains(&json!("definition")));
        } else {
            assert_eq!(tool["annotations"]["readOnlyHint"], true, "{tool}");
        }
        if tool["name"] == "winols_read_bytes" {
            assert_eq!(tool["inputSchema"]["additionalProperties"], false);
            let required = tool["inputSchema"]["required"].as_array().unwrap();
            for field in ["expected_project_id", "address", "count"] {
                assert!(required.contains(&json!(field)));
            }
            assert_eq!(
                tool["inputSchema"]["properties"]["count"]["minimum"].as_f64(),
                Some(1.0)
            );
            assert_eq!(
                tool["inputSchema"]["properties"]["count"]["maximum"].as_f64(),
                Some(4096.0)
            );
        }
    }
    let status = client.call("winols_status", json!({})).await;
    assert_eq!(status["backend"], "mock");
    assert_eq!(status["connected"], true);
    assert_eq!(status["persistent"], false);
    client.close().await;
}

#[tokio::test]
async fn byte_reads_report_both_versions_and_reject_bad_ranges_without_changes() {
    let mut client = Client::start().await;
    let project = client.call("winols_get_project", json!({})).await;
    let read = client
        .call(
            "winols_read_bytes",
            json!({"expected_project_id": project["id"], "address": 254, "count": 4}),
        )
        .await;
    assert_eq!(read["project_id"], project["id"]);
    assert_eq!(read["address"], 254);
    assert_eq!(read["window_id"], "1");
    assert_eq!(read["version_name"], "Synthetic selected version (mock)");
    assert_eq!(read["original_bytes"], json!([254, 255, 0, 1]));
    assert_eq!(read["current_bytes"], json!([126, 127, 128, 129]));
    let size = project["size_bytes"].as_u64().unwrap();
    let last = client
        .call(
            "winols_read_bytes",
            json!({"expected_project_id": project["id"], "address": size - 1, "count": 1}),
        )
        .await;
    assert_eq!(last["original_bytes"], json!([255]));
    assert_eq!(last["current_bytes"], json!([127]));
    let largest = client
        .call(
            "winols_read_bytes",
            json!({"expected_project_id": project["id"], "address": 0, "count": 4096}),
        )
        .await;
    assert_eq!(largest["original_bytes"].as_array().unwrap().len(), 4096);
    assert_eq!(largest["current_bytes"].as_array().unwrap().len(), 4096);

    for (address, count, expected) in [
        (0, 0, "count must be between"),
        (0, 4097, "count must be between"),
        (size, 1, "exceeds project size"),
        (size - 1, 2, "exceeds project size"),
        (u64::MAX, 1, "overflow"),
    ] {
        client
            .tool_error(
                "winols_read_bytes",
                json!({"expected_project_id": project["id"], "address": address, "count": count}),
                expected,
            )
            .await;
    }
    client
        .tool_error(
            "winols_read_bytes",
            json!({"expected_project_id": "stale-project", "address": 0, "count": 1}),
            "active project changed",
        )
        .await;
    for arguments in [
        json!({"expected_project_id": project["id"], "address": 0, "count": 1, "write": true}),
        json!({"expected_project_id": project["id"], "address": 0}),
        json!({"expected_project_id": project["id"], "address": -1, "count": 1}),
    ] {
        let response = client.call_raw("winols_read_bytes", arguments).await;
        assert_eq!(response["result"]["isError"], true, "{response}");
    }
    assert_eq!(client.call("winols_get_project", json!({})).await, project);
    assert_eq!(
        client
            .call(
                "winols_read_bytes",
                json!({"expected_project_id": project["id"], "address": 254, "count": 4}),
            )
            .await,
        read
    );
    client.close().await;
}

#[tokio::test]
async fn definitions_with_axes_and_defaults_survive_validation_creation_and_readback() {
    let mut client = Client::start().await;
    let project = client.call("winols_get_project", json!({})).await;
    assert_eq!(project["id"], "mock-project");
    assert_eq!(project["size_bytes"], 1024 * 1024);
    assert_eq!(project["map_count"], 0);
    let mut definition = minimal_definition();
    definition["factor"] = json!(0.25);
    definition["offset"] = json!(-40.0);
    definition["unit"] = json!("degrees");
    definition["x_axis"] = json!({"address": 8192, "data_type": "u16_le", "unit": "rpm"});
    definition["y_axis"] = json!({
        "address": 8200, "data_type": "u8", "factor": 0.5, "offset": 10.0
    });

    let validated = client
        .call("winols_validate_map", json!({"definition": definition}))
        .await;
    assert_eq!(validated["valid"], true);
    assert_eq!(validated["project_id"], project["id"]);
    assert_eq!(validated["definition"]["x_axis"]["factor"], 1.0);
    assert_eq!(validated["definition"]["x_axis"]["offset"], 0.0);
    assert_eq!(validated["definition"]["y_axis"]["unit"], "");
    assert_eq!(
        client.call("winols_get_project", json!({})).await["map_count"],
        0
    );

    let created = client
        .call(
            "winols_create_map",
            json!({
                "expected_project_id": project["id"], "definition": definition
            }),
        )
        .await;
    assert_eq!(created["id"], "mock-map-1");
    assert_eq!(created["definition"], validated["definition"]);
    assert_eq!(
        client
            .call("winols_get_map", json!({"id": created["id"]}))
            .await,
        created
    );
    let listed = client.call("winols_list_maps", json!({})).await;
    assert_eq!(listed["total"], 1);
    assert_eq!(listed["maps"], json!([created]));
    let later_page = client
        .call("winols_list_maps", json!({"offset": 1, "limit": 1}))
        .await;
    assert_eq!(later_page["total"], 1);
    assert_eq!(later_page["maps"], json!([]));
    assert_eq!(
        client.call("winols_get_project", json!({})).await["map_count"],
        1
    );
    client.close().await;
}

#[tokio::test]
async fn invalid_requests_return_errors_and_never_create_extra_maps() {
    let mut client = Client::start().await;
    let definition = minimal_definition();
    let created = client
        .call(
            "winols_create_map",
            json!({
                "expected_project_id": "mock-project", "definition": definition
            }),
        )
        .await;
    assert_eq!(created["definition"]["factor"], 1.0);
    assert_eq!(created["definition"]["offset"], 0.0);
    assert_eq!(created["definition"]["unit"], "");
    assert_eq!(created["definition"]["x_axis"], Value::Null);
    assert_eq!(created["definition"]["y_axis"], Value::Null);

    let mut outside_binary = definition.clone();
    outside_binary["address"] = json!(1024 * 1024 - 1);
    client
        .tool_error(
            "winols_validate_map",
            json!({"definition": outside_binary}),
            "exceeds project size",
        )
        .await;
    client
        .tool_error(
            "winols_create_map",
            json!({
                "expected_project_id": "mock-project", "definition": outside_binary
            }),
            "exceeds project size",
        )
        .await;

    let mut invalid_axis = definition.clone();
    invalid_axis["x_axis"] = json!({"address": 1024 * 1024 - 1, "data_type": "u16_be"});
    client
        .tool_error(
            "winols_create_map",
            json!({
                "expected_project_id": "mock-project", "definition": invalid_axis
            }),
            "x_axis",
        )
        .await;
    client
        .tool_error(
            "winols_create_map",
            json!({
                "expected_project_id": "stale-project", "definition": definition
            }),
            "active project changed",
        )
        .await;

    let mut duplicate_name = definition.clone();
    duplicate_name["address"] = json!(16384);
    client
        .tool_error(
            "winols_create_map",
            json!({
                "expected_project_id": "mock-project", "definition": duplicate_name
            }),
            "already exists",
        )
        .await;
    let mut duplicate_address = definition.clone();
    duplicate_address["name"] = json!("Another synthetic table");
    client
        .tool_error(
            "winols_create_map",
            json!({
                "expected_project_id": "mock-project", "definition": duplicate_address
            }),
            "already exists",
        )
        .await;

    for limit in [0, 101] {
        client
            .tool_error(
                "winols_list_maps",
                json!({"limit": limit}),
                "limit must be between",
            )
            .await;
    }
    client
        .tool_error(
            "winols_get_map",
            json!({"id": "missing-map"}),
            "map not found",
        )
        .await;

    let mut unknown_property = definition.clone();
    unknown_property["colums"] = json!(4);
    for arguments in [
        json!({"expected_project_id": "mock-project", "definition": unknown_property}),
        json!({"expected_project_id": "mock-project", "definition": definition, "save": true}),
    ] {
        let response = client.call_raw("winols_create_map", arguments).await;
        assert!(response.get("error").is_none(), "{response}");
        assert_eq!(response["result"]["isError"], true, "{response}");
        assert!(
            response["result"]["content"][0]["text"]
                .as_str()
                .unwrap()
                .contains("unknown field"),
            "{response}"
        );
    }

    assert_eq!(
        client.call("winols_get_project", json!({})).await["map_count"],
        1
    );
    let listed = client.call("winols_list_maps", json!({})).await;
    assert_eq!(listed["total"], 1);
    assert_eq!(listed["maps"], json!([created]));
    client.close().await;
}
