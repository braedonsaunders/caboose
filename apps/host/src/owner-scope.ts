/** Route only the exact standard owner invocation through the guest scope wrapper. */
export async function ownerScopeCommand(
  command: string,
  args: string[],
  isAvailable: () => Promise<boolean>,
): Promise<{ command: string; args: string[] }> {
  if (command !== '/usr/sbin/runuser' || args[0] !== '-u' || args[1] !== 'caboose' || args[2] !== '--') return { command, args }
  if (!await isAvailable()) return { command, args }
  return { command: '/usr/local/libexec/caboose-owner-run', args: args.slice(3) }
}
