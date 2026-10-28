import { index, pgTable, text, timestamp, uniqueIndex, uuid } from 'drizzle-orm/pg-core'
import { id } from '@braedonsaunders/appkit-db'
import { authAccounts, authSessions, authVerifications, auditLog, memberships, tenants, users } from '@braedonsaunders/appkit-db/schema'

/**
 * An invitation to administer a tenant, delivered as a copyable link rather than an email.
 * Only a SHA-256 of the link's token is kept; accepting it makes (or signs in) the account and
 * adds its membership.
 */
export const invites = pgTable('caboose_invites', {
  id: id(),
  tenantId: uuid('tenant_id').notNull().references(() => tenants.id, { onDelete: 'cascade' }),
  email: text('email').notNull(),
  tokenHash: text('token_hash').notNull(),
  createdBy: uuid('created_by'),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
  acceptedAt: timestamp('accepted_at', { withTimezone: true }),
  acceptedBy: uuid('accepted_by'),
}, table => [
  uniqueIndex('caboose_invites_token_key').on(table.tokenHash),
  index('caboose_invites_tenant_idx').on(table.tenantId),
])

/** A computer user; a console login is optional and grants no rights through this table. */
export const people = pgTable('caboose_people', {
  id: id(),
  tenantId: uuid('tenant_id').notNull().references(() => tenants.id, { onDelete: 'restrict' }),
  name: text('name').notNull(),
  userId: uuid('user_id').references(() => users.id, { onDelete: 'set null' }),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
}, table => [
  uniqueIndex('caboose_people_tenant_user_key').on(table.tenantId, table.userId),
  uniqueIndex('caboose_people_id_tenant_key').on(table.id, table.tenantId),
])

export const schema = { tenants, users, sessions: authSessions, accounts: authAccounts, verifications: authVerifications, memberships, auditLog, invites, people }
