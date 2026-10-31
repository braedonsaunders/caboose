import { OWNER_COMPUTER, type CabooseClient, type PairingCode, type PhoneSignIn, type Reach } from './api.js'

export interface SetupPairing { code: PairingCode; known: Set<string>; reach: Reach | null }

/** Capture existing phones before minting: a fast scan must never become part of the baseline. */
export async function beginSetupPairing(client: Pick<CabooseClient, 'phones' | 'startPairing' | 'reach'>): Promise<SetupPairing> {
  const known = new Set((await client.phones(OWNER_COMPUTER)).phones.map(phone => phone.id))
  const [code, reach] = await Promise.all([client.startPairing(OWNER_COMPUTER), client.reach().catch(() => null)])
  return { code, known, reach }
}

export function joinedPhone(pairing: SetupPairing, phones: PhoneSignIn[]): PhoneSignIn | undefined {
  return phones.find(phone => !pairing.known.has(phone.id))
}
