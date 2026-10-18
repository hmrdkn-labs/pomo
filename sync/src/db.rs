//! Trust state (`devices` table) and the seq-conflict probe, over a second connection to the
//! store's database file. Core has no API for either.

use crate::error::Result;
use pomo_core::Event;
use rusqlite::{params, Connection};
use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Trust {
    Paired,
    Unpaired,
    Revoked,
}

pub struct Db {
    conn: Mutex<Connection>,
}

impl Db {
    pub fn open(path: &Path) -> Result<Db> {
        let conn = Connection::open(path)?;
        conn.busy_timeout(Duration::from_secs(5))?;
        Ok(Db { conn: Mutex::new(conn) })
    }

    pub fn trust(&self, device_id: &str) -> Result<Trust> {
        let conn = self.conn.lock().unwrap();
        let row: Option<(i64, i64)> = conn
            .query_row("SELECT paired, revoked FROM devices WHERE device_id = ?1", [device_id], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .map(Some)
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                e => Err(e),
            })?;
        Ok(match row {
            Some((_, 1)) => Trust::Revoked,
            Some((1, _)) => Trust::Paired,
            _ => Trust::Unpaired,
        })
    }

    /// Marks the device paired (and clears a revocation: pairing is an explicit human act).
    pub fn set_paired(&self, device_id: &str, name: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO devices (device_id, name, paired, revoked) VALUES (?1, ?2, 1, 0)
             ON CONFLICT (device_id) DO UPDATE SET name = ?2, paired = 1, revoked = 0",
            params![device_id, name],
        )?;
        Ok(())
    }

    pub fn revoke(&self, device_id: &str) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO devices (device_id, paired, revoked) VALUES (?1, 0, 1)
             ON CONFLICT (device_id) DO UPDATE SET revoked = 1",
            [device_id],
        )?;
        Ok(())
    }

    /// First event whose `(device_id, seq)` is stored under a different id.
    pub fn seq_conflict(&self, events: &[Event]) -> Result<Option<String>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached("SELECT id FROM events WHERE device_id = ?1 AND seq = ?2")?;
        for e in events {
            let stored: Option<String> = match stmt.query_row(params![e.device_id, e.seq as i64], |r| r.get(0)) {
                Ok(id) => Some(id),
                Err(rusqlite::Error::QueryReturnedNoRows) => None,
                Err(err) => return Err(err.into()),
            };
            if let Some(id) = stored {
                if id != e.id {
                    return Ok(Some(format!(
                        "({}, {}) is stored as {id}, peer sent {}",
                        e.device_id, e.seq, e.id
                    )));
                }
            }
        }
        Ok(None)
    }
}
