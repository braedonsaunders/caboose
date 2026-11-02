import type { CabooseClient, PairingCode, PhoneSignIn, Reach } from './api.js'

export interface SetupPairing { code: PairingCode; known: Set<string>; reach: Reach | null }

/**
 * The owner's phone signs in to the host, not to a computer. Existing host phones are captured
 * before minting: a fast scan must never become part of the baseline.
 */
export async function beginSetupPairing(client: Pick<CabooseClient, 'hostPhones' | 'startHostPairing' | 'reach'>): Promise<SetupPairing> {
  const known = new Set((await client.hostPhones()).phones.map(phone => phone.id))
  const [code, reach] = await Promise.all([client.startHostPairing(), client.reach().catch(() => null)])
  return { code, known, reach }
}

export function joinedPhone(pairing: SetupPairing, phones: PhoneSignIn[]): PhoneSignIn | undefined {
  return phones.find(phone => !pairing.known.has(phone.id))
}
