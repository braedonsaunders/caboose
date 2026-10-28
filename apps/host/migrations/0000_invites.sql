CREATE TABLE "caboose_invites" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"tenant_id" uuid NOT NULL,
	"email" text NOT NULL,
	"token_hash" text NOT NULL,
	"created_by" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"accepted_at" timestamp with time zone,
	"accepted_by" uuid
);
--> statement-breakpoint
ALTER TABLE "caboose_invites" ADD CONSTRAINT "caboose_invites_tenant_id_tenants_id_fk" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
CREATE UNIQUE INDEX "caboose_invites_token_key" ON "caboose_invites" USING btree ("token_hash");
--> statement-breakpoint
CREATE INDEX "caboose_invites_tenant_idx" ON "caboose_invites" USING btree ("tenant_id");
