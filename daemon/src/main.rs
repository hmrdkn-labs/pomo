use std::path::PathBuf;
use std::str::FromStr;

use clap::Parser;
use pomod::{default_home, Daemon, Options, SyncMode, DEFAULT_PORT};
use tokio::signal::unix::{signal, SignalKind};

/// Pomo daemon: serves the agent API on 127.0.0.1 and syncs with paired Devices.
#[derive(Parser)]
struct Args {
    /// Port to listen on; 0 picks a free one (recorded in daemon.json).
    #[arg(long, default_value_t = DEFAULT_PORT)]
    port: u16,
    /// Data directory (default: $POMO_HOME or ~/.pomo).
    #[arg(long)]
    home: Option<PathBuf>,
    /// n0: real relays; local: no relays (tests); off: no sync node.
    #[arg(long, default_value = "n0", value_parser = SyncMode::from_str)]
    sync: SyncMode,
    /// This Device's name (default: the stored name, else the machine's hostname).
    #[arg(long)]
    name: Option<String>,
}

#[tokio::main]
async fn main() {
    let args = Args::parse();
    let home = args.home.unwrap_or_else(default_home);
    let opts = Options { port: args.port, sync: args.sync, name: args.name, ..Options::new(home.clone()) };
    let daemon = match Daemon::start(opts).await {
        Ok(d) => d,
        Err(e) => {
            eprintln!("pomod: cannot start: {e}");
            std::process::exit(1);
        }
    };
    eprintln!("pomod: listening on {} (home {}, device {})", daemon.addr, home.display(), daemon.device_id);
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
