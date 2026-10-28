import {
  Alert, AlertDescription, AlertTitle, Badge, Button, DetailHeader, DetailPageLayout, PageContainer, SubtabNav,
} from '@braedonsaunders/appkit-ui'
import { Power, RotateCcw, Sunrise } from 'lucide-react'
import { formatMemoryMb, type CabooseClient } from '../api.js'
import { useComputerActions } from '../actions.js'
import { COMPUTER_TABS, navigate, routeHref, type ComputerTab } from '../navigation.js'
import { availableActions, stateLabel, stateTone } from '../state.js'
import type { ComputerHandle } from '../useComputer.js'
import type { HostHandle } from '../useHost.js'
import { RollingWordmark } from '../brand/Logo.js'
import { ComputerOverview } from './computer/ComputerOverview.js'
import { Files } from './computer/Files.js'
import { Apps } from './computer/Apps.js'
import { Phones } from './computer/Phones.js'
import { Settings } from './computer/Settings.js'

/** One computer: its state and lifecycle actions above, and a tab for each thing an owner manages. */
export function Computer({ client, computer, host, tab, token, onUnauthorized }: {
  client: CabooseClient
  computer: ComputerHandle
  host: HostHandle
  tab: ComputerTab
  token: string
  onUnauthorized: () => void
}) {
  const { status, error } = computer
  const actions = useComputerActions(client, computer)

  if (!status) {
    return (
      <PageContainer>
        {error ? (
          <Alert variant="destructive">
            <AlertTitle>The host could not be reached</AlertTitle>
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        ) : <RollingWordmark label="Loading the computer" />}
      </PageContainer>
    )
  }

  const allowed = availableActions(status)
  const active = status.activeResources
  const size = active ?? status.settings

  return (
    <DetailPageLayout
      header={
        <DetailHeader
          title={status.settings.name}
          subtitle={`${formatMemoryMb(size.memoryMb)} · ${size.vcpus} vCPUs`}
          badge={<Badge variant={stateTone(status.state)}>{stateLabel(status.state)}</Badge>}
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
                <Button variant="outline" onClick={() => void actions.restart()} disabled={!allowed.restart || actions.busy !== null}>
                  <RotateCcw className="size-4" aria-hidden />{actions.busy === 'restart' ? 'Restarting…' : 'Restart'}
                </Button>
              ) : null}
            </div>
          }
        />
      }
      alerts={
        error || status.restartRequired || status.lastError ? (
          <div className="space-y-3">
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
          </div>
        ) : undefined
      }
      subtabs={
        <SubtabNav
          ariaLabel="Computer"
          tabs={COMPUTER_TABS.map(entry => ({ key: entry.key, label: entry.label }))}
          active={tab}
          onSelect={key => navigate(routeHref({ page: 'computer', tab: key as ComputerTab }))}
        />
      }
    >
      {tab === 'overview' ? <ComputerOverview computer={computer} host={host} /> : null}
      {tab === 'files' ? <Files client={client} computer={computer} onUnauthorized={onUnauthorized} /> : null}
      {tab === 'apps' ? <Apps client={client} computer={computer} onUnauthorized={onUnauthorized} /> : null}
      {tab === 'phones' ? <Phones client={client} computer={computer} token={token} onUnauthorized={onUnauthorized} /> : null}
      {tab === 'settings' ? <Settings client={client} computer={computer} /> : null}
    </DetailPageLayout>
  )
}
