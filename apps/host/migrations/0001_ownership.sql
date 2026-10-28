CREATE TABLE caboose_people (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 80),
  user_id uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT caboose_people_tenant_user_key UNIQUE (tenant_id, user_id),
  CONSTRAINT caboose_people_id_tenant_key UNIQUE (id, tenant_id)
);
--> statement-breakpoint
CREATE TABLE caboose_computers (
  id text PRIMARY KEY,
  slot integer NOT NULL UNIQUE CHECK (slot BETWEEN 0 AND 63),
  created_at timestamptz,
  tenant_id uuid REFERENCES tenants(id) ON DELETE RESTRICT,
  person_id uuid,
  legacy_person text,
  assignment_pending boolean NOT NULL,
  CONSTRAINT caboose_computers_person_tenant_fk FOREIGN KEY (person_id, tenant_id)
    REFERENCES caboose_people(id, tenant_id) ON DELETE RESTRICT,
  CONSTRAINT caboose_computers_assignment_check CHECK (
    (assignment_pending AND person_id IS NULL) OR
    (NOT assignment_pending AND person_id IS NOT NULL AND tenant_id IS NOT NULL)
  ),
  CONSTRAINT caboose_computers_identity_check CHECK (
    (id = 'owner' AND slot = 0) OR (id ~ '^c-[0-9a-f]{10}$' AND slot > 0)
  )
);
--> statement-breakpoint
INSERT INTO caboose_people (tenant_id, user_id, name)
SELECT m.tenant_id, m.user_id, u.name FROM tenant_users m
JOIN users u ON u.id = m.user_id JOIN tenants t ON t.id = m.tenant_id
WHERE m.status = 'active'
ON CONFLICT (tenant_id, user_id) DO NOTHING;
