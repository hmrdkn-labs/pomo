use std::path::PathBuf;

use clap::Parser;
use pomod::{default_home, Daemon, Options, DEFAULT_PORT};
use tokio::signal::unix::{signal, SignalKind};

/// Pomo daemon: serves the agent API on 127.0.0.1.
#[derive(Parser)]
struct Args {
    /// Port to listen on; 0 picks a free one (recorded in daemon.json).
    #[arg(long, default_value_t = DEFAULT_PORT)]
    port: u16,
    /// Data directory (default: $POMO_HOME or ~/.pomo).
    #[arg(long)]
    home: Option<PathBuf>,
}

#[tokio::main]
async fn main() {
    let args = Args::parse();
    let home = args.home.unwrap_or_else(default_home);
    let daemon = match Daemon::start(Options { home: home.clone(), port: args.port }).await {
        Ok(d) => d,
        Err(e) => {
            eprintln!("pomod: cannot start: {e}");
            std::process::exit(1);
        }
    };
    eprintln!("pomod: listening on {} (home {})", daemon.addr, home.display());
    let mut term = signal(SignalKind::terminate()).expect("SIGTERM handler");
    let mut int = signal(SignalKind::interrupt()).expect("SIGINT handler");
    tokio::select! {
        _ = term.recv() => {}
        _ = int.recv() => {}
    }
    if let Err(e) = daemon.shutdown().await {
        eprintln!("pomod: shutdown error: {e}");
        std::process::exit(1);
    }
}
