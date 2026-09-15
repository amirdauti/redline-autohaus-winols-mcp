use clap::{Parser, ValueEnum};
use rmcp::ServiceExt;
use std::{path::PathBuf, time::Duration};
use winols_mcp::{backend::Backend, mailbox::Mailbox, mock::MockBackend, server::WinolsServer};

#[derive(Clone, Copy, Debug, ValueEnum)]
enum BackendKind {
    Mock,
    Winols,
}

#[derive(Debug, Parser)]
#[command(version, about = "Local MCP server for WinOLS map definitions")]
struct Args {
    #[arg(long, value_enum, default_value = "winols")]
    backend: BackendKind,
    /// Absolute path shared with the OLS530 Lua bridge. Required for the winols backend.
    #[arg(long)]
    bridge_dir: Option<PathBuf>,
    #[arg(long, default_value_t = 10000, value_parser = clap::value_parser!(u64).range(100..=60000))]
    timeout_ms: u64,
    /// Print backend status as JSON and exit instead of serving MCP over stdio.
    #[arg(long)]
    doctor: bool,
}

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("winols-mcp: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let args = Args::parse();
    let mut backend = match args.backend {
        BackendKind::Mock => {
            if args.bridge_dir.is_some() {
                return Err("--bridge-dir applies only to --backend winols".into());
            }
            Backend::Mock(MockBackend::new())
        }
        BackendKind::Winols => {
            let directory = args.bridge_dir.ok_or(
                "--bridge-dir is required for WinOLS; use --backend mock for a synthetic project",
            )?;
            Backend::Winols(Mailbox::open(
                &directory,
                Duration::from_millis(args.timeout_ms),
            )?)
        }
    };
    if args.doctor {
        println!(
            "{}",
            serde_json::to_string_pretty(&backend.status().await?).map_err(|e| e.to_string())?
        );
        return Ok(());
    }
    let service = WinolsServer::new(backend)
        .serve(rmcp::transport::stdio())
        .await
        .map_err(|e| e.to_string())?;
    service.waiting().await.map_err(|e| e.to_string())?;
    Ok(())
}
