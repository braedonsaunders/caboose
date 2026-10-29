export interface RecoveryStatus {
  available: boolean
  reason: string | null
  busy?: boolean
  capturing?: boolean
  restoring?: boolean
  captureReady: boolean
  captureReason?: string | null
  retention: { newest: number; downloadingPhoneCapturesPinned: boolean }
  lastOperation: { kind: string; state: string; startedAt: string; finishedAt?: string; error?: string } | null
  captures: Array<{ id: string; createdAt: string; diskBytes: number }>
}
