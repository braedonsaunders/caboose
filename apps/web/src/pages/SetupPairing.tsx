import * as React from 'react'
import { Alert, AlertDescription, Button } from '@braedonsaunders/appkit-ui'
import { OWNER_COMPUTER, buildPairingLink, formatPairingCode, type CabooseClient, type Reach } from '../api.js'
import { imageLabel, type ImageStatus } from '../host.js'
import { pairingAddresses, tailscaleGuidance } from '../remote-access.js'
import { errorMessage } from '../components/common.js'
import { QrCode } from '../components/QrCode.js'
import { beginSetupPairing, joinedPhone, type SetupPairing } from '../setup-pairing.js'

/** Account creation is committed before this screen; retries only replace a pairing code. */
export function SetupPairingStep({ client, onDone }: { client: CabooseClient; onDone: () => void }) {
  const [pairing, setPairing] = React.useState<SetupPairing | null>(null)
  const [reach, setReach] = React.useState<Reach | null>(null)
  const [image, setImage] = React.useState<ImageStatus | undefined>()
  const [joined, setJoined] = React.useState<string | null>(null)
  const [error, setError] = React.useState<string | null>(null)
  const [busy, setBusy] = React.useState(false)
  const [now, setNow] = React.useState(Date.now)
  const generation = React.useRef(0)

  const start = React.useCallback(async () => {
    const attempt = ++generation.current
    setBusy(true); setError(null); setPairing(null)
    try {
      const next = await beginSetupPairing(client)
      if (generation.current !== attempt) return
      setPairing(next); setReach(next.reach); setJoined(null); setNow(Date.now())
    } catch (failure) {
      if (generation.current === attempt) setError(errorMessage(failure))
    } finally { if (generation.current === attempt) setBusy(false) }
  }, [client])

  React.useEffect(() => { void start(); return () => { generation.current++ } }, [start])
  React.useEffect(() => {
    let disposed = false
    let timer: ReturnType<typeof setTimeout>
    async function poll() {
      // Serialize polls: a slow health check must not pile up more requests.
      if (document.visibilityState === 'visible') {
        setNow(Date.now())
        const attempt = generation.current
        const results = await Promise.allSettled([
          client.health(),
          pairing && !joined ? client.phones(OWNER_COMPUTER) : Promise.resolve(null),
        ])
        if (disposed || attempt !== generation.current) return
        if (results[0].status === 'fulfilled') setImage(results[0].value.image)
        const phones = results[1]
        if (phones.status === 'fulfilled' && phones.value && pairing) {
          const phone = joinedPhone(pairing, phones.value.phones)
          if (phone) { setJoined(phone.name); setError(null) }
        }
        const failure = results.find(result => result.status === 'rejected')
        if (failure?.status === 'rejected') setError(errorMessage(failure.reason))
        else setError(null)
      }
      if (!disposed) timer = setTimeout(() => void poll(), 2_000)
    }
    void poll()
    return () => { disposed = true; clearTimeout(timer) }
  }, [client, pairing, joined])

  const expired = pairing ? Date.parse(pairing.code.expiresAt) <= now : false
  const addresses = pairingAddresses(reach, window.location.origin)
  const link = pairing && addresses.length ? buildPairingLink(addresses, pairing.code.code) : null
  const guidance = reach ? tailscaleGuidance(reach.tailscale) : null

  async function enableRemote() {
    setBusy(true); setError(null)
    try { setReach(await client.setTailscale(true)) }
    catch (failure) { setError(errorMessage(failure)) }
    finally { setBusy(false) }
  }

  return <div className="space-y-5">
    <h2 className="text-lg font-semibold">Pair your iPhone</h2>
    {joined ? <Alert variant="success"><AlertDescription>{joined} is connected. Open Caboose on your iPhone to use your computer.</AlertDescription></Alert> : <>
      <p className="text-sm text-fg-muted">Open the iPhone Camera and scan the code, or enter the code in Caboose. Your phone needs the Caboose app installed.</p>
      {pairing && !expired && link ? <div className="flex flex-col items-center gap-3">
        <QrCode value={link} label="Pair your iPhone with Caboose" />
        <p className="font-mono text-xl tracking-widest">{formatPairingCode(pairing.code.code)}</p>
        <p className="text-sm text-fg-muted">Works once; expires in {Math.max(1, Math.ceil((Date.parse(pairing.code.expiresAt) - now) / 60_000))} minutes.</p>
        <Button variant="outline" onClick={() => { navigator.clipboard.writeText(link).catch(failure => setError(errorMessage(failure))) }}>Copy pairing link</Button>
      </div> : pairing && !expired ? <Alert variant="warning"><AlertDescription>This host has no address your phone can reach. Enable Tailscale HTTPS below, or configure Remote access in the console.</AlertDescription></Alert> : null}
      {expired ? <p role="status">This code has expired.</p> : null}
      {!pairing || expired ? <Button disabled={busy} variant="outline" onClick={() => void start()}>{busy ? 'Preparing…' : 'New pairing code'}</Button> : null}
    </>}
    {image ? <div className="space-y-2 text-sm" role="status">
      <p>Computer image: {imageLabel(image)}</p>
      {image.state === 'fetching' ? <progress className="w-full" aria-label="Computer image download" {...(image.totalBytes && image.totalBytes > 0 ? { max: image.totalBytes, value: Math.min(image.receivedBytes ?? 0, image.totalBytes) } : {})} /> : null}
      {image.state === 'fetching' ? <p className="text-fg-muted">You can pair while the computer image downloads.</p> : null}
    </div> : null}
    {guidance ? <div className="space-y-2 text-sm"><p className="font-medium">{guidance.title}</p><p className="text-fg-muted">{guidance.detail}</p>
      {guidance.link ? <a className="underline" href={guidance.link.href} target="_blank" rel="noreferrer">{guidance.link.label}</a> : null}
      {reach?.tailscale.installed && reach.tailscale.loggedIn && !reach.tailscale.serving ? <Button disabled={busy} variant="outline" onClick={() => void enableRemote()}>Enable Tailscale HTTPS</Button> : null}
    </div> : null}
    {error ? <Alert variant="destructive"><AlertDescription>{error}</AlertDescription></Alert> : null}
    <Button className="w-full" onClick={onDone}>Continue to console</Button>
  </div>
}
