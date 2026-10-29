# Administrator account security

Administrator accounts belong to the people who manage tenants in the web console.
Members use their paired phones and do not need accounts. Public signup and magic-link
sign-in are disabled. The owner token retains its separate host-operator boundary;
account security requires an administrator session cookie and does not accept bearer tokens.

Account security provides password changes, authenticator enrollment, recovery codes and
signed-in sessions. Changing a password requires the current password and signs out other
sessions. Authenticator enrollment requires the password and a valid six-digit code before
MFA becomes active. Enrollment preserves other existing sessions; use Sign out other
sessions to revoke them. Recovery codes are displayed when created or replaced; each works once,
and replacing them invalidates the old set. Better Auth, through AppKit, owns hashing,
encryption, enrollment, challenges and recovery-code consumption.

Sign-in stops at the authenticator challenge until verification succeeds. An invitation for
an existing account requires that completed sign-in before granting tenant membership.
A new account is created only by host setup or an invitation. Password reset preserves MFA
and revokes existing sessions; it does not replace lost authenticator recovery codes.

Session listings contain IDs, browser, address and timestamps, never bearer tokens.
Revocation checks ownership using the signed-in account. Session cookie caching is disabled,
so revoked sessions cannot authorize subsequent requests. Open administrator sockets are
revalidated before a successful account-security or membership-removal response returns;
expired sessions are checked every 30 seconds. A failed authorization read closes the
connection. Each revalidation sweep has a five-second deadline; an unavailable database
closes affected connections rather than stalling revocation. Owner-token and phone sockets keep their separate authorization behavior.

## Recovery email transport

Recovery uses the host's configured AppKit email transport. These are host deployment
settings for global administrator identities, not tenant billing or feature settings:

| Variable | Meaning |
| --- | --- |
| `CABOOSE_EMAIL_PROVIDER` | `smtp`, `resend`, `sendgrid`, `mailgun` or `postmark` |
| `CABOOSE_EMAIL_FROM` | Verified sender address |
| `CABOOSE_EMAIL_SECRET` | Provider key or SMTP password; omit for an unauthenticated relay |
| `CABOOSE_SMTP_HOST` | SMTP hostname |
| `CABOOSE_SMTP_PORT` | SMTP port; defaults to 465 with implicit TLS, otherwise 587 |
| `CABOOSE_SMTP_SECURE` | `true` for implicit TLS; otherwise STARTTLS is required |
| `CABOOSE_SMTP_USERNAME` | SMTP username; supply together with the password |
| `CABOOSE_MAILGUN_DOMAIN` | Mailgun sending domain |
| `CABOOSE_MAILGUN_REGION` | `us` (default) or `eu` |

Set the host's public URL to the HTTPS console origin administrators can reach. Recovery
links and their return destination use that configured origin, never the request's Host
header or a supplied return URL. Keep provider credentials in protected deployment secrets;
the console and host-status responses do not expose them. SMTP delivery follows AppKit's
public-host egress policy; private LAN relays are not accepted by this transport.

When email is unconfigured, the sign-in screen omits recovery and recovery requests return
503. Invalid transport configuration fails startup. Delivery failures fail the request with
a generic error rather than claiming an email was sent. Successful requests use the same
response for known and unknown accounts. Recovery tokens are single-use and expire after
one hour. The recovery page removes the token from its URL after reading it.

## Verification

Host identity tests exercise the real embedded database and AppKit runtime, including the
existing-account invitation MFA boundary and session metadata/revocation. The socket-fence
tests exercise expiry, authorization failure, racing revocation and timer cleanup. Email
adapter tests verify real-transport configuration and failure propagation. Run:

```sh
pnpm --filter caboose-host exec vitest run src/identity --maxWorkers=1 --no-file-parallelism
pnpm --filter caboose-web typecheck
```

AppKit's hosted PostgreSQL integration verifies canonical schema migration with an existing
account, MFA enrollment/challenge, encrypted storage, one-use recovery codes, password reset
and immediate persisted-session revocation.
