use crate::{
    domain::{MapDefinition, MapRecord, ProjectInfo},
    mailbox::Mailbox,
    mock::MockBackend,
};
use serde_json::{Value, json};

pub enum Backend {
    Mock(MockBackend),
    Winols(Mailbox),
}

impl Backend {
    pub async fn status(&mut self) -> Result<Value, String> {
        match self {
            Self::Mock(_) => Ok(
                json!({"backend":"mock", "connected":true, "protocol_version":1,
                "persistent":false,"message":"Synthetic in-memory project; no WinOLS connection"}),
            ),
            Self::Winols(bridge) => bridge.call("get_status", json!({})).await,
        }
    }

    pub async fn project(&mut self) -> Result<ProjectInfo, String> {
        match self {
            Self::Mock(mock) => Ok(mock.project()),
            Self::Winols(bridge) => {
                serde_json::from_value(bridge.call("get_project", json!({})).await?)
                    .map_err(|e| format!("invalid project response from bridge: {e}"))
            }
        }
    }

    pub async fn list_maps(&mut self, offset: u32, limit: u32) -> Result<Value, String> {
        if !(1..=100).contains(&limit) {
            return Err("limit must be between 1 and 100".into());
        }
        match self {
            Self::Mock(mock) => {
                serde_json::to_value(mock.list_maps(offset, limit)).map_err(|e| e.to_string())
            }
            Self::Winols(bridge) => {
                bridge
                    .call("list_maps", json!({"offset":offset,"limit":limit}))
                    .await
            }
        }
    }

    pub async fn get_map(&mut self, id: &str) -> Result<Value, String> {
        if id.is_empty() || id.len() > 1024 || id.chars().any(char::is_control) {
            return Err("invalid map ID".into());
        }
        match self {
            Self::Mock(mock) => serde_json::to_value(mock.get_map(id)?).map_err(|e| e.to_string()),
            Self::Winols(bridge) => bridge.call("get_map", json!({"id":id})).await,
        }
    }

    pub async fn validate_map(&mut self, definition: &MapDefinition) -> Result<Value, String> {
        let project = self.project().await?;
        definition.validate(project.size_bytes)?;
        Ok(
            json!({"valid":true,"project_id":project.id,"definition":definition,
            "message":"Layout and bounds are valid. This does not establish the map's meaning or check for duplicates."}),
        )
    }

    pub async fn create_map(
        &mut self,
        expected_project_id: &str,
        definition: MapDefinition,
    ) -> Result<Value, String> {
        let project = self.project().await?;
        if project.id != expected_project_id {
            return Err(
                "active project changed; get the project again before creating a definition".into(),
            );
        }
        definition.validate(project.size_bytes)?;
        let record = match self {
            Self::Mock(mock) => mock.create_map(expected_project_id, definition.clone())?,
            Self::Winols(bridge) => {
                let result = bridge
                    .call(
                        "create_map",
                        json!({"expected_project_id":expected_project_id,"definition":definition}),
                    )
                    .await?;
                serde_json::from_value::<MapRecord>(result).map_err(|e| {
                    bridge.invalidate();
                    format!("map may have been created, but its response is invalid: {e}; bridge connection stopped; inspect WinOLS and recover the mailbox before restarting")
                })?
            }
        };
        if record.id.is_empty() || record.id.len() > 1024 || record.id.chars().any(char::is_control)
        {
            if let Self::Winols(bridge) = self {
                bridge.invalidate();
            }
            return Err("map may have been created, but its response contains an invalid map ID; bridge connection stopped; inspect WinOLS and recover the mailbox before restarting".into());
        }
        if record.definition != definition {
            if let Self::Winols(bridge) = self {
                bridge.invalidate();
            }
            return Err("map may have been created, but readback differs from the requested definition; bridge connection stopped; inspect WinOLS and recover the mailbox before restarting".into());
        }
        serde_json::to_value(record).map_err(|e| e.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{path::Path, time::Duration};
    use tokio::fs;

    async fn respond(directory: &Path, operation: &str, result: Value) {
        let request_path = directory.join("request.json");
        tokio::time::timeout(Duration::from_secs(3), async {
            while !request_path.exists() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("server did not publish the expected request");
        let processing_path = directory.join("processing.json");
        fs::rename(&request_path, &processing_path).await.unwrap();
        let request: Value =
            serde_json::from_slice(&fs::read(&processing_path).await.unwrap()).unwrap();
        assert_eq!(request["operation"], operation);
        let response = json!({
            "protocol_version": 1,
            "id": request["id"],
            "ok": true,
            "result": result
        });
        let temporary = directory.join("response.tmp");
        fs::write(&temporary, serde_json::to_vec(&response).unwrap())
            .await
            .unwrap();
        fs::remove_file(&processing_path).await.unwrap();
        fs::rename(&temporary, directory.join("response.json"))
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn uncertain_creation_readback_stops_subsequent_bridge_calls() {
        let definition: MapDefinition = serde_json::from_value(json!({
            "name": "Synthetic map", "address": 256, "columns": 4,
            "rows": 2, "data_type": "u16_le"
        }))
        .unwrap();
        let mut different = definition.clone();
        different.address += 2;
        let cases = [
            (json!({"id": "map-1"}), "response is invalid"),
            (
                json!({"id": "", "definition": definition}),
                "invalid map ID",
            ),
            (
                json!({"id": "bad\nid", "definition": definition}),
                "invalid map ID",
            ),
            (
                json!({"id": "x".repeat(1025), "definition": definition}),
                "invalid map ID",
            ),
            (
                json!({"id": "map-1", "definition": different}),
                "readback differs",
            ),
        ];

        for (create_result, expected_error) in cases {
            let directory = tempfile::tempdir().unwrap();
            let mut backend =
                Backend::Winols(Mailbox::open(directory.path(), Duration::from_secs(3)).unwrap());
            let bridge_directory = directory.path().to_path_buf();
            let bridge = tokio::spawn(async move {
                respond(&bridge_directory, "get_project", json!({
                    "id": "project-1", "name": "Synthetic project", "size_bytes": 1024, "map_count": 0
                })).await;
                respond(&bridge_directory, "create_map", create_result).await;
            });
            let error = backend
                .create_map("project-1", definition.clone())
                .await
                .unwrap_err();
            assert!(error.contains(expected_error), "unexpected error: {error}");
            bridge.await.unwrap();

            assert!(
                backend
                    .project()
                    .await
                    .unwrap_err()
                    .contains("connection stopped")
            );
            assert!(
                backend
                    .create_map("project-1", definition.clone())
                    .await
                    .unwrap_err()
                    .contains("connection stopped")
            );
            assert!(!directory.path().join("request.json").exists());
            assert!(!directory.path().join("request.tmp").exists());
        }
    }
}
