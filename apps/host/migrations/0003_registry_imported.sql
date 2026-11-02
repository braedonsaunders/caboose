CREATE TABLE caboose_registry_state (
  id integer PRIMARY KEY CHECK (id = 1),
  imported_at timestamptz NOT NULL DEFAULT now()
);
--> statement-breakpoint
INSERT INTO caboose_registry_state (id) SELECT 1 WHERE EXISTS (SELECT 1 FROM caboose_computers);
