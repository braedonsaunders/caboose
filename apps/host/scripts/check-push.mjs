#!/usr/bin/env node
// Run on the host with its private APNs environment and CABOOSE_IMAGE_ROOT.
import { tsImport } from 'tsx/esm/api'
import { join } from 'node:path'
const { apnsFromEnvironment, APNsSender } = await tsImport('../src/apns.ts', import.meta.url)
const { PushDevices } = await tsImport('../src/push.ts', import.meta.url)
const config = await apnsFromEnvironment(process.env)
if (!config) throw new Error('Configure the CABOOSE_APNS_* variables first')
const devices = (await PushDevices.open(join(process.env.CABOOSE_IMAGE_ROOT ?? '/var/lib/caboose', 'push-devices.json'))).list()
const index = Number(process.argv[2] ?? 0)
if (!Number.isInteger(index) || index < 0 || index >= devices.length) throw new Error(`Choose a registered device index from 0 to ${devices.length - 1}`)
const device = devices[index]
const result = await new APNsSender(config).send({ ...device, payload: { aps: { alert: { title: 'Caboose', body: 'Push notifications are connected.' }, sound: 'default' } } })
if (result.status !== 200) throw new Error(`APNs rejected the test: ${result.status} ${result.reason ?? ''}`)
console.log(`APNs accepted the test for registered device ${index} (${device.environment}); check the device for delivery.`)
