import * as React from 'react'
import { DashboardMetricCard, DashboardPanel } from '@braedonsaunders/appkit-dashboard/primitives'
import {
  Alert, AlertDescription, AlertTitle, Badge, Button, PageContainer, PageHeader, toast,
} from '@braedonsaunders/appkit-ui'
import { Bot, Cpu, MonitorSmartphone, Power, RotateCcw, Smartphone, Sunrise } from 'lucide-react'
import { buildIosPairingUrl, formatMemoryMb, type CabooseClient } from '../api.js'
import { useComputerActions } from '../actions.js'
import { availableActions, stateLabel, stateTone } from '../state.js'
import type { ComputerHandle } from '../useComputer.js'
import { navigate } from '../navigation.js'
import { RollingCar } from '../brand/Logo.js'

export function Overview({ client, computer, token }: { client: CabooseClient; computer: ComputerHandle; token: string }) {
  const { status, error } = computer
  const actions = useComputerActions(client, computer)
  const [showPairing, setShowPairing] = React.useState(false)

  if (!status) {
    return (
      <PageContainer>
        {error ? (
          <Alert variant="destructive">
            <AlertTitle>The host could not be reached</AlertTitle>
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        ) : <RollingCar label="Loading your computer" />}
      </PageContainer>
    )
  }

  const allowed = availableActions(status)
  const active = status.activeResources
  const agents = status.tasks.running + status.tasks.paused
  const pairing = buildIosPairingUrl(window.location.origin, token)

  return (
    <PageContainer>
      <div className="space-y-6">
        <PageHeader
          title={status.settings.name}
          description="The computer this host runs. It wakes when you open Caboose and parks, every app still open, when nothing is using it."
          actions={
            <div className="flex flex-wrap gap-2">
              {allowed.wake ? (
                <Button onClick={actions.wake} disabled={actions.busy !== null}>
                  <Sunrise className="size-4" aria-hidden />{actions.busy === 'wake' ? 'Waking…' : 'Wake'}
                </Button>
              ) : null}
              <Button variant="outline" onClick={actions.park} disabled={!allowed.park || actions.busy !== null}>
                <Power className="size-4" aria-hidden />{actions.busy === 'park' ? 'Parking…' : 'Park now'}
              </Button>
              {status.capabilities.restart ? (
                <Button variant="destructive" onClick={() => void actions.restart()} disabled={!allowed.restart || actions.busy !== null}>
                  <RotateCcw className="size-4" aria-hidden />{actions.busy === 'restart' ? 'Restarting…' : 'Restart'}
                </Button>
              ) : null}
            </div>
          }
        />

        {error ? (
          <Alert variant="warning">
            <AlertTitle>Showing the last known status</AlertTitle>
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        ) : null}
        {status.restartRequired ? (
          <Alert variant="warning">
            <AlertTitle>Restart to apply new resources</AlertTitle>
            <AlertDescription>
              {active
                ? `Running with ${formatMemoryMb(active.memoryMb)} and ${active.vcpus} vCPUs; the next restart uses ${formatMemoryMb(status.settings.memoryMb)} and ${status.settings.vcpus} vCPUs.`
                : `The next restart starts with ${formatMemoryMb(status.settings.memoryMb)} and ${status.settings.vcpus} vCPUs.`}
            </AlertDescription>
          </Alert>
        ) : null}
        {status.lastError ? (
          <Alert variant="destructive">
            <AlertTitle>Last lifecycle error</AlertTitle>
            <AlertDescription className="font-mono text-xs break-all">{status.lastError}</AlertDescription>
          </Alert>
        ) : null}

        <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <DashboardMetricCard
            label="State"
            value={<Badge variant={stateTone(status.state)}>{stateLabel(status.state)}</Badge>}
            icon={<MonitorSmartphone className="size-4" aria-hidden />}
          />
          <DashboardMetricCard
            label="Running with"
            value={active ? formatMemoryMb(active.memoryMb) : '—'}
            detail={active ? `${active.vcpus} vCPUs` : 'Known after the next cold boot'}
            icon={<Cpu className="size-4" aria-hidden />}
          />
          <DashboardMetricCard
            label="Screens connected"
            value={status.clients.display}
            detail={`${status.clients.control} control ${status.clients.control === 1 ? 'channel' : 'channels'}`}
            icon={<Smartphone className="size-4" aria-hidden />}
          />
          <DashboardMetricCard
            label="Agents working"
            value={agents}
            detail={status.tasks.paused ? `${status.tasks.paused} paused for take-over` : undefined}
            icon={<Bot className="size-4" aria-hidden />}
          />
        </div>

        <DashboardPanel title="Connect your iPhone" icon={<Smartphone className="size-4" aria-hidden />}>
          <div className="space-y-3 text-sm">
            <p className="text-muted-foreground">
              Open this link on an iPhone with Caboose installed to sign it in to this host. The link carries
              your owner token, so share it only with your own devices.
            </p>
            {showPairing ? (
              <code className="block break-all rounded-md bg-muted p-3 text-xs">{pairing}</code>
            ) : null}
            <div className="flex flex-wrap gap-2">
              <Button variant="outline" size="sm" onClick={() => setShowPairing(value => !value)}>
                {showPairing ? 'Hide link' : 'Show link'}
              </Button>
              <Button
                variant="outline"
                size="sm"
                onClick={() => {
                  navigator.clipboard.writeText(pairing).then(
                    () => toast.success('Pairing link copied.'),
                    () => toast.error('The browser did not allow copying.'))
                }}
              >
                Copy link
              </Button>
              <Button variant="ghost" size="sm" onClick={() => navigate('/settings')}>Computer settings</Button>
            </div>
          </div>
        </DashboardPanel>
      </div>
    </PageContainer>
  )
}
