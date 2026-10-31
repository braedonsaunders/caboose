export const clusterSchema = `CREATE TABLE IF NOT EXISTS caboose_cluster_hosts (
 id text PRIMARY KEY, resource text NOT NULL UNIQUE, compatibility text NOT NULL,
 endpoint text NOT NULL, revoked boolean NOT NULL DEFAULT false,
 fence_receipt jsonb, created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE IF NOT EXISTS caboose_cluster_computers (
 id text PRIMARY KEY, generation bigint NOT NULL DEFAULT 0,
 host_id text REFERENCES caboose_cluster_hosts(id),
 expires_at timestamptz, checkpoint jsonb,
 compatibility text NOT NULL
);
`
