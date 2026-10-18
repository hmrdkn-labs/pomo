-- Migration 0002: last known address of each peer Device, so a sync by device_id works after a
-- restart. Local only, never synced and not part of the event log.
-- `address` is the iroh endpoint ticket string (endpoint id plus relay and direct addresses).

CREATE TABLE peers (
  device_id  TEXT PRIMARY KEY,
  address    TEXT NOT NULL,
  updated_ms INTEGER NOT NULL
) STRICT;

UPDATE meta SET value = '2' WHERE key = 'schema_version';
