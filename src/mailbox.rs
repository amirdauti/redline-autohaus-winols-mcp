//! One outstanding request per mailbox, with exclusive ownership and atomic handoff.

use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    fs::File,
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    fs,
    io::{AsyncReadExt, AsyncWriteExt},
    time::Instant,
};

const MAX_MESSAGE_BYTES: u64 = 1_048_576;
const PENDING_FILES: [&str; 5] = [
    "request.tmp",
    "request.json",
    "processing.json",
    "response.tmp",
    "response.json",
];

#[derive(Serialize)]
struct Request<'a> {
    protocol_version: u32,
    id: &'a str,
    operation: &'a str,
    params: Value,
    expires_at: u64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Response {
    protocol_version: u32,
    id: String,
    ok: bool,
    result: Option<Value>,
    error: Option<BridgeError>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BridgeError {
    code: String,
    message: String,
}

pub struct Mailbox {
    directory: PathBuf,
    timeout: Duration,
    _lock: File,
    failed: bool,
}

impl Mailbox {
    pub fn open(directory: &Path, timeout: Duration) -> Result<Self, String> {
        if !directory.is_absolute() {
            return Err("bridge directory must be an absolute path".into());
        }
        if timeout < Duration::from_millis(100) || timeout > Duration::from_secs(60) {
            return Err("timeout must be between 100 and 60000 milliseconds".into());
        }
        std::fs::create_dir_all(directory)
            .map_err(|e| format!("cannot create bridge directory: {e}"))?;
        let directory = directory.canonicalize().map_err(|e| e.to_string())?;
        let lock = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(directory.join("client.lock"))
            .map_err(|e| format!("cannot open mailbox lock: {e}"))?;
        lock.try_lock_exclusive()
            .map_err(|_| "another MCP server already owns this bridge directory".to_string())?;
        for name in PENDING_FILES {
            if directory
                .join(name)
                .try_exists()
                .map_err(|e| e.to_string())?
            {
                return Err(format!(
                    "unfinished mailbox file {name}; follow docs/bridge-protocol.md recovery before restarting"
                ));
            }
        }
        Ok(Self {
            directory,
            timeout,
            _lock: lock,
            failed: false,
        })
    }

    /// Stop reuse when a completed exchange leaves the operation's outcome uncertain.
    pub(crate) fn invalidate(&mut self) {
        self.failed = true;
    }

    pub async fn call(&mut self, operation: &str, params: Value) -> Result<Value, String> {
        if self.failed {
            return Err("bridge connection stopped after an uncertain exchange; inspect WinOLS and recover the mailbox before restarting".into());
        }
        // Cancellation must also stop reuse: the flag remains set if this future is dropped.
        self.failed = true;
        let id = uuid::Uuid::new_v4().to_string();
        let expires_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_secs()
            + self.timeout.as_secs()
            + 1;
        let bytes = serde_json::to_vec(&Request {
            protocol_version: 1,
            id: &id,
            operation,
            params,
            expires_at,
        })
        .map_err(|e| e.to_string())?;
        if bytes.len() as u64 > MAX_MESSAGE_BYTES {
            self.failed = false;
            return Err("bridge request exceeds 1 MiB".into());
        }
        for name in PENDING_FILES {
            if fs::try_exists(self.directory.join(name))
                .await
                .map_err(|e| e.to_string())?
            {
                return Err(format!(
                    "unexpected mailbox file {name}; inspect and recover before restarting"
                ));
            }
        }
        let temporary = self.directory.join("request.tmp");
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .await
            .map_err(|e| e.to_string())?;
        file.write_all(&bytes).await.map_err(|e| e.to_string())?;
        file.flush().await.map_err(|e| e.to_string())?;
        drop(file);
        fs::rename(&temporary, self.directory.join("request.json"))
            .await
            .map_err(|e| e.to_string())?;
        let deadline = Instant::now() + self.timeout;
        let response_path = self.directory.join("response.json");
        loop {
            if fs::try_exists(&response_path)
                .await
                .map_err(|e| e.to_string())?
            {
                let mut bytes = Vec::new();
                fs::File::open(&response_path)
                    .await
                    .map_err(|e| e.to_string())?
                    .take(MAX_MESSAGE_BYTES + 1)
                    .read_to_end(&mut bytes)
                    .await
                    .map_err(|e| e.to_string())?;
                if bytes.len() as u64 > MAX_MESSAGE_BYTES {
                    return Err("bridge response exceeds 1 MiB".into());
                }
                let response: Response = serde_json::from_slice(&bytes)
                    .map_err(|e| format!("invalid bridge response: {e}"))?;
                if response.protocol_version != 1 || response.id != id {
                    return Err("bridge response ID or protocol version mismatch; mailbox requires recovery".into());
                }
                if response.ok && (response.result.is_none() || response.error.is_some())
                    || !response.ok && (response.error.is_none() || response.result.is_some())
                {
                    return Err("inconsistent bridge response envelope".into());
                }
                // The bridge removes processing.json before publishing the response.
                if fs::try_exists(self.directory.join("processing.json"))
                    .await
                    .map_err(|e| e.to_string())?
                {
                    return Err("bridge published a response before releasing its request".into());
                }
                fs::remove_file(&response_path)
                    .await
                    .map_err(|e| e.to_string())?;
                self.failed = false;
                return if response.ok {
                    Ok(response.result.unwrap())
                } else {
                    let error = response.error.unwrap();
                    Err(format!("{}: {}", error.code, error.message))
                };
            }
            if Instant::now() >= deadline {
                return Err("WinOLS bridge timed out; outcome may be unknown. Do not retry creation. Inspect WinOLS and follow docs/bridge-protocol.md recovery".into());
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn exclusive_lock_and_stale_requests_prevent_ambiguous_startup() {
        let dir = tempfile::tempdir().unwrap();
        let first = Mailbox::open(dir.path(), Duration::from_secs(1)).unwrap();
        assert!(Mailbox::open(dir.path(), Duration::from_secs(1)).is_err());
        drop(first);
        std::fs::write(dir.path().join("processing.json"), "{}").unwrap();
        assert!(
            Mailbox::open(dir.path(), Duration::from_secs(1))
                .err()
                .expect("expected stale mailbox rejection")
                .contains("unfinished")
        );
    }

    #[tokio::test]
    async fn atomic_exchange_matches_response_to_request() {
        let dir = tempfile::tempdir().unwrap();
        let mut mailbox = Mailbox::open(dir.path(), Duration::from_secs(2)).unwrap();
        let bridge_dir = dir.path().to_path_buf();
        let bridge = tokio::spawn(async move {
            let path = bridge_dir.join("request.json");
            while !path.exists() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            fs::rename(&path, bridge_dir.join("processing.json"))
                .await
                .unwrap();
            let req: Value = serde_json::from_slice(
                &fs::read(bridge_dir.join("processing.json")).await.unwrap(),
            )
            .unwrap();
            assert_eq!(req["operation"], "get_project");
            let response =
                json!({"protocol_version":1,"id":req["id"],"ok":true,"result":{"id":"test"}});
            fs::write(
                bridge_dir.join("response.tmp"),
                serde_json::to_vec(&response).unwrap(),
            )
            .await
            .unwrap();
            fs::remove_file(bridge_dir.join("processing.json"))
                .await
                .unwrap();
            fs::rename(
                bridge_dir.join("response.tmp"),
                bridge_dir.join("response.json"),
            )
            .await
            .unwrap();
        });
        assert_eq!(
            mailbox.call("get_project", json!({})).await.unwrap()["id"],
            "test"
        );
        bridge.await.unwrap();
        assert!(!mailbox.failed);
    }

    #[tokio::test]
    async fn timeout_and_cancellation_prevent_reuse() {
        let dir = tempfile::tempdir().unwrap();
        let mut mailbox = Mailbox::open(dir.path(), Duration::from_millis(100)).unwrap();
        assert!(
            mailbox
                .call("create_map", json!({}))
                .await
                .unwrap_err()
                .contains("timed out")
        );
        assert!(
            mailbox
                .call("create_map", json!({}))
                .await
                .unwrap_err()
                .contains("stopped")
        );
        drop(mailbox);
        assert!(Mailbox::open(dir.path(), Duration::from_secs(1)).is_err());

        let dir = tempfile::tempdir().unwrap();
        let mut mailbox = Mailbox::open(dir.path(), Duration::from_secs(2)).unwrap();
        assert!(
            tokio::time::timeout(
                Duration::from_millis(30),
                mailbox.call("create_map", json!({}))
            )
            .await
            .is_err()
        );
        assert!(mailbox.call("get_project", json!({})).await.is_err());
    }
}
