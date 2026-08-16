CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  created_at TEXT NOT NULL,
  cloud_user_id TEXT
);

CREATE TABLE IF NOT EXISTS user_sessions (
  user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  last_active_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS context_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL REFERENCES users(id),
  timestamp TEXT NOT NULL,
  app_bundle_id TEXT,
  app_name TEXT,
  window_title TEXT,
  focused_element_role TEXT,
  focused_element_label TEXT,
  visible_text TEXT,
  raw_json TEXT,
  capture_method TEXT DEFAULT 'ax',
  capture_tier INTEGER DEFAULT 1,
  page_url TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_bundle_ts
  ON context_events(app_bundle_id, timestamp);
CREATE INDEX IF NOT EXISTS idx_events_user_ts
  ON context_events(user_id, timestamp);

CREATE TABLE IF NOT EXISTS text_atoms (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id INTEGER NOT NULL REFERENCES context_events(id) ON DELETE CASCADE,
  role TEXT NOT NULL,
  label TEXT,
  text TEXT NOT NULL,
  element_path TEXT NOT NULL,
  element_hash TEXT
);
CREATE INDEX IF NOT EXISTS idx_atoms_event ON text_atoms(event_id);

CREATE VIRTUAL TABLE IF NOT EXISTS atoms_fts USING fts5(
  text,
  label UNINDEXED,
  role UNINDEXED,
  content='text_atoms',
  content_rowid='id',
  tokenize='unicode61 remove_diacritics 2'
);
CREATE TRIGGER IF NOT EXISTS text_atoms_ai AFTER INSERT ON text_atoms BEGIN
  INSERT INTO atoms_fts(rowid, text, label, role) VALUES (new.id, new.text, new.label, new.role);
END;
CREATE TRIGGER IF NOT EXISTS text_atoms_ad AFTER DELETE ON text_atoms BEGIN
  INSERT INTO atoms_fts(atoms_fts, rowid, text, label, role) VALUES('delete', old.id, old.text, old.label, old.role);
END;
CREATE TRIGGER IF NOT EXISTS text_atoms_au AFTER UPDATE ON text_atoms BEGIN
  INSERT INTO atoms_fts(atoms_fts, rowid, text, label, role) VALUES('delete', old.id, old.text, old.label, old.role);
  INSERT INTO atoms_fts(rowid, text, label, role) VALUES (new.id, new.text, new.label, new.role);
END;

CREATE VIRTUAL TABLE IF NOT EXISTS vec_atoms USING vec0(
  embedding float[384] distance_metric=cosine
);

CREATE TABLE IF NOT EXISTS task_log (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id          TEXT NOT NULL REFERENCES users(id),
  timestamp        TEXT NOT NULL,
  title            TEXT,
  original_prompt  TEXT,
  approved_prompt  TEXT,
  agent_type       TEXT,
  status           TEXT DEFAULT 'detected',
  exit_code        INTEGER,
  result_path      TEXT,
  result_preview   TEXT
);
CREATE INDEX IF NOT EXISTS idx_task_log_user_ts ON task_log(user_id, timestamp);

CREATE TABLE IF NOT EXISTS fs_events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL REFERENCES users(id),
  timestamp TEXT NOT NULL,
  path TEXT NOT NULL,
  event_type TEXT NOT NULL,
  mtime REAL,
  linked_event_id INTEGER REFERENCES context_events(id) ON DELETE SET NULL,
  capture_tier INTEGER DEFAULT 3
);
CREATE INDEX IF NOT EXISTS idx_fs_events_ts ON fs_events(timestamp);
CREATE INDEX IF NOT EXISTS idx_fs_events_linked ON fs_events(linked_event_id);
CREATE INDEX IF NOT EXISTS idx_fs_events_user_ts ON fs_events(user_id, timestamp);

CREATE TABLE IF NOT EXISTS capture_audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL REFERENCES users(id),
  timestamp TEXT NOT NULL,
  capture_method TEXT NOT NULL,
  capture_tier INTEGER NOT NULL,
  atom_count INTEGER NOT NULL,
  app_bundle_id TEXT
);
CREATE INDEX IF NOT EXISTS idx_capture_audit_ts ON capture_audit(timestamp);
CREATE INDEX IF NOT EXISTS idx_capture_audit_user_ts ON capture_audit(user_id, timestamp);

CREATE TABLE IF NOT EXISTS llm_calls (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT NOT NULL,
  call_site TEXT NOT NULL,
  provider TEXT NOT NULL,
  model TEXT,
  prompt_chars INTEGER NOT NULL,
  response_chars INTEGER,
  latency_ms INTEGER,
  ok INTEGER NOT NULL,
  error TEXT
);
CREATE INDEX IF NOT EXISTS idx_llm_calls_ts ON llm_calls(timestamp);

CREATE TABLE IF NOT EXISTS sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at TEXT NOT NULL,
  ended_at TEXT NOT NULL,
  primary_bundle_id TEXT,
  primary_app_name TEXT,
  event_count INTEGER NOT NULL,
  atom_count INTEGER NOT NULL,
  switch_count INTEGER NOT NULL,
  title TEXT,
  summary TEXT
);
CREATE INDEX IF NOT EXISTS idx_sessions_started ON sessions(started_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_started_unique ON sessions(started_at);

CREATE TABLE IF NOT EXISTS session_events (
  session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  event_id INTEGER NOT NULL REFERENCES context_events(id) ON DELETE CASCADE,
  PRIMARY KEY (session_id, event_id)
);

CREATE TABLE IF NOT EXISTS entities (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,            -- 'person' | 'project' | 'file' | 'url' | 'org'
  name TEXT NOT NULL,
  normalized TEXT NOT NULL,
  first_seen TEXT NOT NULL,
  last_seen TEXT NOT NULL,
  mention_count INTEGER NOT NULL DEFAULT 0,
  UNIQUE(kind, normalized)
);
CREATE TABLE IF NOT EXISTS entity_mentions (
  entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
  atom_id INTEGER NOT NULL REFERENCES text_atoms(id) ON DELETE CASCADE,
  event_id INTEGER NOT NULL REFERENCES context_events(id) ON DELETE CASCADE,
  PRIMARY KEY (entity_id, atom_id)
);
CREATE INDEX IF NOT EXISTS idx_entity_mentions_event ON entity_mentions(event_id);

CREATE TABLE IF NOT EXISTS mcp_calls (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL REFERENCES users(id),
  tool_name TEXT NOT NULL,
  timestamp TEXT NOT NULL,
  result_count INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_mcp_calls_ts ON mcp_calls(timestamp);
