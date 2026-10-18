//! Pomo Sync: peer-to-peer event exchange over iroh. Implements `spec/sync.md`.

mod db;
pub mod error;
mod node;
mod session;
pub mod wire;

pub use error::{Error, Result};
pub use node::{
    default_key_path, open_store, Network, PairOutcome, SyncNode, SyncOptions, SyncReport, PAIR_PREFIX,
};
