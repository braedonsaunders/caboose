ALTER TABLE caboose_computers DROP CONSTRAINT caboose_computers_slot_check;
--> statement-breakpoint
ALTER TABLE caboose_computers ADD CONSTRAINT caboose_computers_slot_check CHECK (slot BETWEEN 0 AND 32831);
