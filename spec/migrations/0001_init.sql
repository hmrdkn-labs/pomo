-- Pomo store, schema version 1. Plain SQLite; no extensions. Applied by migrations/0001_init.sql.
-- Events are canonical. Everything else can be rebuilt from them.


CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
) STRICT;
-- meta rows: schema_version = '1', device_id = this Device's id

CREATE TABLE events (
  id          TEXT    PRIMARY KEY,                 -- UUID
  device_id   TEXT    NOT NULL,
  seq         INTEGER NOT NULL CHECK (seq >= 1),
  hlc_ms      INTEGER NOT NULL,
  hlc_counter INTEGER NOT NULL CHECK (hlc_counter >= 0),
  type        TEXT    NOT NULL,
  payload     TEXT    NOT NULL CHECK (json_valid(payload)),
  source      TEXT    NOT NULL,
  command_key TEXT,
  UNIQUE (device_id, seq)
) STRICT;

-- Total order of the log.
CREATE INDEX events_order ON events (hlc_ms, hlc_counter, device_id, seq);

-- Idempotent Commands: one key per issuing Device (a Command yields at most one event).
CREATE UNIQUE INDEX events_command_key ON events (device_id, command_key)
  WHERE command_key IS NOT NULL;

-- Known Devices. `paired` is local trust state and is never synced.
CREATE TABLE devices (
  device_id TEXT PRIMARY KEY,
  name      TEXT,
  paired    INTEGER NOT NULL DEFAULT 0,
  revoked   INTEGER NOT NULL DEFAULT 0
) STRICT;

-- Projection: one row per block, rebuilt from events. Must equal the reducer's output.
CREATE TABLE blocks (
  id            TEXT PRIMARY KEY,
  kind          TEXT NOT NULL,
  label         TEXT,
  project       TEXT,
  source        TEXT NOT NULL,
  device_id     TEXT NOT NULL,
  started_ms    INTEGER NOT NULL,
  planned_ms    INTEGER NOT NULL,
  elapsed_ms    INTEGER NOT NULL,
  phase         TEXT NOT NULL,
  phase_since_ms INTEGER NOT NULL,
  outcome       TEXT,
  ended_ms      INTEGER
) STRICT;

CREATE INDEX blocks_started ON blocks (started_ms);
