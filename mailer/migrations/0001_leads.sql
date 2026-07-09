CREATE TABLE leads (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  store_name TEXT NOT NULL,
  town TEXT,
  contact_email TEXT NOT NULL,
  contact_name TEXT,
  source_note TEXT,          -- how/where this lead was found, for later review
  status TEXT NOT NULL DEFAULT 'pending',  -- pending | sent | failed | skipped
  created_ms INTEGER NOT NULL,
  sent_ms INTEGER,
  error TEXT
);

CREATE INDEX idx_leads_status ON leads(status, created_ms);
CREATE UNIQUE INDEX idx_leads_email ON leads(contact_email);
